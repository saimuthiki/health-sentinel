import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_severity.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../common/failure_copy.dart';
import '../common/severity_ui.dart';
import 'report_upload.dart';
import 'trend_sparkline.dart';

/// Everything you have uploaded, and how each value has moved.
///
/// This screen owns the upload, which is the single most important thing the
/// app does: without a report there is nothing to explain, nothing to plan
/// against and nothing to track. Choosing the file happens behind
/// [ReportPicker] so it can be tested; sending it happens here, out loud, so
/// nobody is left looking at a screen that has stopped saying anything.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

/// What the upload is doing at this moment.
enum _UploadStage {
  /// Nothing in flight. The upload button works and no progress is shown.
  idle,

  /// The phone's own picker is open. Nothing of ours is on screen behind it,
  /// but a second tap must not open a second picker.
  choosing,

  /// Bytes are going out. This is the only stage with a number attached to it.
  sending,

  /// Every byte has landed and the backend is reading the page.
  reading,
}

/// A refusal or a failure, in the two parts a person needs: what happened, and
/// whether there is anything to press.
class _UploadFailure {
  const _UploadFailure({
    required this.title,
    required this.message,
    this.canRetry = false,
  });

  final String title;
  final String message;

  /// True only when trying the same file again is a sensible thing to do -
  /// a dropped connection, say. A file that is too big will still be too big.
  final bool canRetry;
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _UploadStage _stage = _UploadStage.idle;

  /// Bytes handed to the socket, and how many there are in total.
  int _sent = 0;
  int _total = 0;

  _UploadFailure? _failure;

  /// The file that was chosen, kept so that "Try again" does not make somebody
  /// go and find their report a second time.
  PickedReport? _picked;

  bool get _busy => _stage != _UploadStage.idle;

  /// Offer the three ways in, and act on whichever was tapped.
  ///
  /// The sheet closes with the choice rather than doing the work itself: a
  /// picker opened from inside a sheet that is about to be dismissed is a
  /// reliable way to lose the result.
  Future<void> _showUploadSheet() async {
    final ReportSource? source = await showModalBottomSheet<ReportSource>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        final HpPalette p = sheetContext.hp;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HpSpacing.gutter,
              0,
              HpSpacing.gutter,
              HpSpacing.xxl,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Add a report',
                  style: HpType.headline.copyWith(color: p.ink),
                ),
                const SizedBox(height: HpSpacing.sm),
                Text(
                  'A PDF from the lab reads most accurately. A clear photo of '
                  'the printed page works too.',
                  style: HpType.body.copyWith(color: p.inkMuted),
                ),
                const SizedBox(height: HpSpacing.xl),
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: const Text('Choose a PDF'),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ReportSource.pdf),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ReportSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Pick from your gallery'),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(ReportSource.gallery),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (source == null || !mounted) {
      // The sheet was swiped away rather than chosen from. Nothing happens.
      return;
    }
    await _addReport(source);
  }

  /// Choose a report, check it, send it, and go to what came out of it.
  ///
  /// [source] is null when this is a retry of a file that has already been
  /// chosen: a connection that dropped halfway is not a reason to make somebody
  /// hunt through their downloads again.
  ///
  /// The busy stage is cleared in a `finally`, so nothing - a refusal, a
  /// timeout while the free host wakes up, a bug in the repository - can leave
  /// this screen stuck saying "sending" with the upload button dead. That
  /// pattern is not decoration: a missing `finally` on the consent screen once
  /// locked the owner out of his own account.
  Future<void> _addReport(ReportSource? source) async {
    if (_busy) {
      // A second tap while a picker or an upload is already running would open
      // two pickers, or send the same file twice.
      return;
    }
    setState(() {
      _stage = _UploadStage.choosing;
      _failure = null;
    });

    _UploadFailure? failure;
    HealthReport? uploaded;
    // Only a failure that happened while the bytes were going out is worth a
    // "Try again": a file that was refused for its size will be refused again,
    // and a camera that was not allowed will not be allowed by pressing harder.
    bool wasSending = false;
    try {
      PickedReport? picked = _picked;
      if (source != null) {
        picked = await ref.read(reportPickerProvider).pick(source);
        if (picked == null) {
          // Backing out of the picker is the commonest outcome here by a long
          // way, and it is not an error. Nothing is said and nothing is shown.
          return;
        }
        _picked = picked;
      }
      if (picked == null) {
        return;
      }

      final String? refusal = describeUploadRefusal(picked.bytes);
      final String? mimeType = picked.mimeType;
      if (refusal != null || mimeType == null) {
        // Refused here rather than by the backend, so nobody sits through a
        // long upload to be told at the end that the file was never going to
        // be accepted. The words are the backend's own.
        _picked = null;
        failure = _UploadFailure(
          title: 'That file cannot be used',
          message: refusal ?? unreadableFileMessage,
        );
        return;
      }

      wasSending = true;
      uploaded = await _send(picked, mimeType);
    } on ReportPickerException catch (error) {
      // Already written for the person: a permission that was not given, a
      // camera that is not there.
      failure = _UploadFailure(
        title: 'That could not be opened',
        message: error.message,
      );
    } catch (error) {
      failure = _UploadFailure(
        title: 'Your report was not sent',
        message: explainFailure(error, fallback: uploadFallbackMessage),
        canRetry: wasSending && _picked != null,
      );
    } finally {
      if (mounted) {
        setState(() {
          _stage = _UploadStage.idle;
          _failure = failure;
        });
      }
    }

    if (failure != null || uploaded == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    // The list behind this screen no longer includes everything, and the trends
    // below it were worked out without this report in them.
    ref.invalidate(reportsProvider);
    ref.invalidate(trendsProvider);
    _picked = null;
    // Straight to what came out of the page. Uploading a report and being
    // returned to the same list is the version of this that feels broken.
    GoRouter.of(context).go('/reports/${uploaded.id}');
  }

  /// Send the bytes, saying honestly which half of the wait we are in.
  Future<HealthReport> _send(PickedReport picked, String mimeType) {
    setState(() {
      _stage = _UploadStage.sending;
      _sent = 0;
      _total = picked.bytes.length;
    });
    return ref.read(healthRepositoryProvider).uploadReport(
          fileName: picked.fileName,
          mimeType: mimeType,
          bytes: picked.bytes,
          onProgress: (int sent, int total) {
            if (!mounted) {
              return;
            }
            setState(() {
              _sent = sent;
              _total = total;
              // A full bar is not a finished report. It means the bytes have
              // left the phone; the backend has not read a word of them yet.
              // Sitting on 100% until the answer arrives would be the app
              // telling a plain lie about what it is doing.
              _stage = total > 0 && sent >= total
                  ? _UploadStage.reading
                  : _UploadStage.sending;
            });
          },
        );
  }

  /// The line above the list: progress, or the last refusal. Null when neither.
  Widget? _uploadNotice() {
    final _UploadFailure? failure = _failure;
    if (failure != null) {
      return _UploadNotice(
        title: failure.title,
        detail: failure.message,
        onRetry: failure.canRetry ? () => _addReport(null) : null,
      );
    }
    switch (_stage) {
      case _UploadStage.idle:
      case _UploadStage.choosing:
        return null;
      case _UploadStage.sending:
        return _UploadNotice(
          title: 'Sending your report',
          detail: '${_megabytes(_sent)} of ${_megabytes(_total)} MB sent',
          showBar: true,
          progress:
              _total > 0 ? (_sent / _total).clamp(0.0, 1.0).toDouble() : null,
        );
      case _UploadStage.reading:
        return const _UploadNotice(
          title: 'Your report is being read',
          detail: 'Every byte has arrived. The health engine is now reading the '
              'values off the page, which is the slow part - the first upload '
              'of the day can take the better part of a minute while the '
              'server wakes up. You can leave this screen; it will keep going.',
          showBar: true,
        );
    }
  }

  static String _megabytes(int bytes) =>
      (bytes / 1000000).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AsyncValue<List<HealthReport>> reports = ref.watch(reportsProvider);
    final AsyncValue<List<BiomarkerTrend>> trends = ref.watch(trendsProvider);
    final Widget? notice = _uploadNotice();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.upload_file_outlined),
            tooltip: 'Upload a report',
            onPressed: _busy ? null : _showUploadSheet,
          ),
          const SizedBox(width: HpSpacing.sm),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            if (notice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HpSpacing.gutter,
                  HpSpacing.lg,
                  HpSpacing.gutter,
                  0,
                ),
                child: notice,
              ),
            Expanded(
              child: reports.when(
                loading: () => const HpLoadingState(
                  message: 'Fetching your reports',
                ),
                error: (Object error, StackTrace stack) => HpErrorState(
                  title: 'Reports could not be loaded',
                  body: explainFailure(
                    error,
                    fallback: 'The app could not reach the health engine. '
                        'Nothing has been lost.',
                  ),
                  onRetry: () => ref.invalidate(reportsProvider),
                ),
                data: (List<HealthReport> list) {
                  if (list.isEmpty) {
                    return HpEmptyState(
                      icon: Icons.science_outlined,
                      title: 'No reports yet',
                      body: 'Upload a lab report as a PDF or a photo and '
                          'HealthPulse will read the values, explain them in '
                          'plain language, and fold them into your plan.',
                      actionLabel: 'Upload a report',
                      onAction: _busy ? null : _showUploadSheet,
                    );
                  }
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(
                      HpSpacing.gutter,
                      HpSpacing.lg,
                      HpSpacing.gutter,
                      HpSpacing.section,
                    ),
                    children: <Widget>[
                      HpSectionHeader(
                        title: 'Uploads',
                        note: '${list.length} reports',
                      ),
                      for (final HealthReport report in list) ...<Widget>[
                        _ReportCard(report: report),
                        const SizedBox(height: HpSpacing.md),
                      ],
                      const SizedBox(height: HpSpacing.xxl),
                      const HpSectionHeader(
                        title: 'How things are moving',
                        note: 'usual range shaded',
                      ),
                      trends.when(
                        loading: () => const HpLoadingState(
                          message: 'Working out your trends',
                        ),
                        error: (Object error, StackTrace stack) => Text(
                          'Trends are unavailable right now.',
                          style: HpType.label.copyWith(color: p.inkFaint),
                        ),
                        data: (List<BiomarkerTrend> items) => Column(
                          children: <Widget>[
                            for (final BiomarkerTrend trend in items) ...<Widget>[
                              _TrendCard(trend: trend),
                              const SizedBox(height: HpSpacing.md),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            // Reports interpret health data, so the disclaimer is pinned here
            // and cannot be scrolled away or dismissed.
            const HpDisclaimer(),
          ],
        ),
      ),
    );
  }
}

/// The one place the upload speaks: what is happening, or what went wrong.
///
/// It is a live region so that a screen reader reads the change out - going
/// from "sending" to "being read" is the whole point of this widget, and a
/// change nobody is told about might as well not have happened.
class _UploadNotice extends StatelessWidget {
  const _UploadNotice({
    required this.title,
    required this.detail,
    this.showBar = false,
    this.progress,
    this.onRetry,
  });

  final String title;
  final String detail;

  final bool showBar;

  /// How far along, from 0 to 1, or null for a bar with no end in sight -
  /// which is exactly right once the bytes have gone and the wait is on the
  /// backend, because there is no longer anything to count.
  final double? progress;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Semantics(
      liveRegion: true,
      child: HpCard(
        tone: HpCardTone.tinted,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: HpType.bodyStrong.copyWith(color: p.ink)),
            const SizedBox(height: HpSpacing.xs),
            Text(detail, style: HpType.body.copyWith(color: p.inkMuted)),
            if (showBar) ...<Widget>[
              const SizedBox(height: HpSpacing.md),
              ClipRRect(
                borderRadius: HpRadii.pillRadius,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: p.surfaceSunk,
                  valueColor: AlwaysStoppedAnimation<Color>(p.pine),
                ),
              ),
            ],
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: HpSpacing.lg),
              HpButton(
                label: 'Try again',
                onPressed: onRetry,
                tone: HpButtonTone.secondary,
                expand: false,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final DateTime? collected = report.collectedOn;

    return HpCard(
      onTap: () => GoRouter.of(context).go('/reports/${report.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  report.labName ?? report.fileName,
                  style: HpType.headline.copyWith(color: p.ink),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: p.inkFaint),
            ],
          ),
          const SizedBox(height: HpSpacing.xxs),
          Text(
            collected == null
                ? report.status.label
                : 'Collected ${HpFormat.dayWithYear(collected)}',
            style: HpType.label.copyWith(color: p.inkFaint),
          ),
          if (report.headline != null) ...<Widget>[
            const SizedBox(height: HpSpacing.md),
            Text(
              report.headline!,
              style: HpType.reading.copyWith(color: p.inkMuted),
            ),
          ],
          const SizedBox(height: HpSpacing.lg),
          Wrap(
            spacing: HpSpacing.sm,
            runSpacing: HpSpacing.sm,
            children: <Widget>[
              HpStatusChip(
                severity: report.severity,
                label: _summaryLabel(report),
                dense: true,
              ),
              if (report.needsReviewCount > 0)
                HpStatusChip(
                  severity: HpSeverity.unknown,
                  label: '${report.needsReviewCount} to check',
                  dense: true,
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _summaryLabel(HealthReport report) {
    final int outside = report.outsideRangeCount;
    if (outside == 0) {
      return 'All values in range';
    }
    if (outside == 1) {
      return '1 value to discuss';
    }
    return '$outside values to discuss';
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.trend});

  final BiomarkerTrend trend;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final TrendPoint? latest =
        trend.points.isEmpty ? null : trend.points.last;

    return HpCard(
      tone: HpCardTone.flat,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  trend.displayName,
                  style: HpType.bodyStrong.copyWith(color: p.ink),
                ),
              ),
              if (latest != null)
                Text(
                  '${HpFormat.number(latest.value)} ${trend.unit}',
                  style: HpType.figureSmall.copyWith(color: p.ink),
                ),
            ],
          ),
          const SizedBox(height: HpSpacing.md),
          TrendSparkline(trend: trend),
          const SizedBox(height: HpSpacing.sm),
          Text(
            trend.refLow == null || trend.refHigh == null
                ? 'No usual range on file'
                : 'Usual range ${HpFormat.number(trend.refLow!)} to '
                    '${HpFormat.number(trend.refHigh!)} ${trend.unit}',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
        ],
      ),
    );
  }
}
