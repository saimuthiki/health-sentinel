import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';
import '../common/api_waking_notice.dart';
import '../common/failure_copy.dart';
import 'export_saver.dart';

/// A copy of everything, handed to the person it belongs to.
///
/// `GET /v1/privacy/export` answers with one JSON document — every table this
/// account owns, read with the caller's own token — and this screen does two
/// things with it: asks for it, and hands it to Android's own save box so the
/// owner picks where it goes. Nothing is written anywhere else. A complete
/// health record saved into the app's private storage would be a second copy
/// nobody asked for, in a folder a phone's file browser will not show.
///
/// The wait is named while it happens. The export reads every table, and the
/// health engine is on free hosting that sleeps between visits, so the first
/// one of the day can take the better part of a minute. A silent spinner over
/// that is how an app that is working perfectly gets force-quit.
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

/// What the export is doing at this moment.
enum _ExportStage {
  /// Nothing in flight. The button works.
  idle,

  /// Waiting on the backend to read every table and answer.
  fetching,

  /// The document is here and Android's save box is open over the app.
  saving,
}

/// Said when the export itself falls over and there is nothing better to say.
const String exportFallbackMessage =
    'Your export could not be fetched just now. Nothing has been lost and '
    'nothing has changed — try again in a moment.';

class _ExportScreenState extends ConsumerState<ExportScreen> {
  _ExportStage _stage = _ExportStage.idle;

  /// The last refusal, in our own words, or null.
  String? _failure;

  /// What was saved last time, so the screen can say where it went.
  SavedExport? _saved;

  /// True when the save box was closed without choosing anywhere. Not a
  /// failure, but worth saying, because otherwise nothing at all happens.
  bool _cancelled = false;

  bool get _busy => _stage != _ExportStage.idle;

  /// Fetch the whole record, then hand it to the save box.
  ///
  /// The stage is cleared in a `finally`, so no path out of here — a refusal, a
  /// timeout while the free host wakes, a file dialog that threw — can leave
  /// the button spinning with no way to press it again. Both the repository and
  /// the saver are read from the providers **before** the first await, because
  /// `ref` belongs to a widget that may be gone by the time this resumes.
  Future<void> _export() async {
    if (_busy) {
      // Already running. A second tap would fetch the record twice and open a
      // second save box on top of the first.
      return;
    }
    setState(() {
      _stage = _ExportStage.fetching;
      _failure = null;
      _saved = null;
      _cancelled = false;
    });

    final HealthRepository repository = ref.read(healthRepositoryProvider);
    final ExportSaver saver = ref.read(exportSaverProvider);

    String? failure;
    SavedExport? saved;
    bool cancelled = false;
    try {
      final Map<String, dynamic> document = await repository.exportEverything();
      if (!mounted) {
        return;
      }
      setState(() => _stage = _ExportStage.saving);
      saved = await saver.save(
        fileName: exportFileName(DateTime.now()),
        bytes: _asFileBytes(document),
      );
      cancelled = saved == null;
    } on ExportSaverException catch (error) {
      // Already written for the person: a save box that would not open, or a
      // folder that could not be written to.
      failure = error.message;
    } catch (error) {
      failure = explainFailure(error, fallback: exportFallbackMessage);
    } finally {
      final SavedExport? result = saved;
      final bool wasCancelled = cancelled;
      final String? refusal = failure;
      if (mounted) {
        setState(() {
          _stage = _ExportStage.idle;
          _failure = refusal;
          _saved = result;
          _cancelled = wasCancelled;
        });
      }
    }
  }

  /// The document as the bytes of a file.
  ///
  /// Indented rather than packed onto one line, because the person opening this
  /// is the person it is about: a health record they can read down is worth the
  /// extra bytes, and anything that can open JSON can open this either way.
  static Uint8List _asFileBytes(Map<String, dynamic> document) {
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    return Uint8List.fromList(utf8.encode(encoder.convert(document)));
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final SavedExport? saved = _saved;
    final String? failure = _failure;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to More',
          onPressed: () => context.go('/more'),
        ),
        title: const Text('Export everything'),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            HpSpacing.gutter,
            HpSpacing.lg,
            HpSpacing.gutter,
            HpSpacing.section,
          ),
          children: <Widget>[
            Text(
              'This is everything HealthPulse holds about you: your profile, '
              'every report and the values read off it, your plans, your goals, '
              'what you have told the coach, and when you agreed to what. It '
              'comes as one JSON file — a plain text file any computer can '
              'open.',
              style: HpType.reading.copyWith(color: p.inkMuted),
            ),
            const SizedBox(height: HpSpacing.lg),
            Text(
              'When you press the button, your phone will ask you where to save '
              'it. Pick a folder you can find again — Downloads is the usual '
              'one. The file is not locked or password-protected, so treat it '
              'the way you would a printed report.',
              style: HpType.reading.copyWith(color: p.inkMuted),
            ),
            const SizedBox(height: HpSpacing.section),
            const ApiWakingNotice(),
            if (_stage != _ExportStage.idle) ...<Widget>[
              _ExportNotice(
                title: _stage == _ExportStage.fetching
                    ? 'Gathering your record'
                    : 'Choose where to save it',
                detail: _stage == _ExportStage.fetching
                    ? 'The health engine is reading every table this account '
                        'owns. The first export of the day can take the better '
                        'part of a minute, because the server has to wake up '
                        'first. Nothing is being changed while this runs.'
                    : 'Your record is ready. Your phone has opened its own save '
                        'box — pick a folder, and the file is written there.',
              ),
              const SizedBox(height: HpSpacing.lg),
            ],
            if (failure != null) ...<Widget>[
              _FailureLine(message: failure),
              const SizedBox(height: HpSpacing.lg),
            ],
            if (saved != null) ...<Widget>[
              _SavedCard(saved: saved),
              const SizedBox(height: HpSpacing.lg),
            ],
            if (_cancelled) ...<Widget>[
              Text(
                'Nothing was saved — the save box was closed before a folder '
                'was chosen. Your record is untouched, and you can export it '
                'again whenever you like.',
                style: HpType.body.copyWith(color: p.inkMuted),
              ),
              const SizedBox(height: HpSpacing.lg),
            ],
            HpButton(
              label: saved == null ? 'Export everything' : 'Export it again',
              icon: Icons.file_download_outlined,
              busy: _busy,
              onPressed: _export,
            ),
          ],
        ),
      ),
    );
  }
}

/// `healthpulse-export-2026-09-10.json`.
///
/// Dated rather than numbered, because the useful question about a second copy
/// of your health record is when it was taken. If a file of that name is
/// already there, Android adds its own `(1)` and tells us the name it used.
String exportFileName(DateTime when) {
  final String month = when.month.toString().padLeft(2, '0');
  final String day = when.day.toString().padLeft(2, '0');
  return 'healthpulse-export-${when.year}-$month-$day.json';
}

/// Progress, said out loud, with a bar that has no end in sight.
///
/// There is no honest percentage to show here. The backend reads every table
/// and then answers in one go, so until it does there is nothing to count —
/// and a bar creeping to 90% on a timer would be an invented number.
class _ExportNotice extends StatelessWidget {
  const _ExportNotice({required this.title, required this.detail});

  final String title;
  final String detail;

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
            const SizedBox(height: HpSpacing.md),
            ClipRRect(
              borderRadius: HpRadii.pillRadius,
              child: LinearProgressIndicator(
                minHeight: 8,
                backgroundColor: p.surfaceSunk,
                valueColor: AlwaysStoppedAnimation<Color>(p.pine),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What was saved, and the one honest thing we can say about where.
class _SavedCard extends StatelessWidget {
  const _SavedCard({required this.saved});

  final SavedExport saved;

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
            Row(
              children: <Widget>[
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 20,
                  color: p.pineDeep,
                ),
                const SizedBox(width: HpSpacing.md),
                Expanded(
                  child: Text(
                    'Saved',
                    style: HpType.bodyStrong.copyWith(color: p.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: HpSpacing.sm),
            Text(
              saved.fileName,
              style: HpType.figureSmall.copyWith(color: p.pineDeep),
            ),
            const SizedBox(height: HpSpacing.sm),
            Text(
              'It is in the folder you picked in the save box — if you took the '
              'usual one, open your phone’s Files app and look in Downloads. '
              'Search for the file name above if you cannot see it.',
              style: HpType.body.copyWith(color: p.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A refusal, said where the thing that was refused is.
class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 18, color: p.urgentInk),
          const SizedBox(width: HpSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: HpType.label.copyWith(color: p.urgentInk),
            ),
          ),
        ],
      ),
    );
  }
}
