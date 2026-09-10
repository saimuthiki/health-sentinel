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

/// One report, value by value.
///
/// Each row shows the number, where it sits, what it means in a sentence, and
/// what the lab itself printed - so the user can always check us. Where a
/// threshold came from is shown too: a claim about someone's health that cannot
/// be traced to a source is a claim we should not be making.
class ReportDetailScreen extends ConsumerWidget {
  const ReportDetailScreen({super.key, required this.reportId});

  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<HealthReport> report =
        ref.watch(reportProvider(reportId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to reports',
          onPressed: () => context.go('/reports'),
        ),
        title: const Text('Report'),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: report.when(
                loading: () =>
                    const HpLoadingState(message: 'Opening the report'),
                error: (Object error, StackTrace stack) => HpErrorState(
                  title: 'This report could not be opened',
                  // Never answered from the cache: a report shows lab values
                  // and any red flag over them, and both have to be current.
                  body: explainFailure(
                    error,
                    fallback: 'The app could not reach the health engine.',
                  ),
                  onRetry: () => ref.invalidate(reportProvider(reportId)),
                ),
                data: (HealthReport data) => _Body(report: data),
              ),
            ),
            // Not dismissible, by product requirement.
            const HpDisclaimer(),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.report});

  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final DateTime? collected = report.collectedOn;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HpSpacing.gutter,
        HpSpacing.lg,
        HpSpacing.gutter,
        HpSpacing.section,
      ),
      children: <Widget>[
        // Before the report's own name, before a single value, and with no way
        // to put it away. An `urgent` finding from the backend is the reason
        // this screen exists on the day it appears; everything else on it can
        // wait until it has been read.
        for (final EscalationNotice notice in report.escalations) ...<Widget>[
          HpEscalationCard(
            title: notice.title,
            body: notice.body,
            steps: notice.steps,
            footnote: notice.sourceCitation,
          ),
          const SizedBox(height: HpSpacing.xxl),
        ],
        Text(
          report.labName ?? report.fileName,
          style: HpType.display.copyWith(color: p.ink),
        ),
        const SizedBox(height: HpSpacing.xs),
        Text(
          collected == null
              ? report.status.label
              : 'Collected ${HpFormat.dayWithYear(collected)}',
          style: HpType.label.copyWith(color: p.inkFaint),
        ),
        if (report.headline != null) ...<Widget>[
          const SizedBox(height: HpSpacing.xl),
          HpCard(
            tone: HpCardTone.tinted,
            child: Text(
              report.headline!,
              style: HpType.reading.copyWith(color: p.ink),
            ),
          ),
        ],
        const SizedBox(height: HpSpacing.section),
        HpSectionHeader(
          title: 'Values',
          note: '${report.results.length} measured',
        ),
        for (final LabResult result in report.results) ...<Widget>[
          _ResultCard(reportId: report.id, result: result),
          const SizedBox(height: HpSpacing.md),
        ],
      ],
    );
  }
}

/// One value, and - when we were not sure of it - the way to say so.
///
/// The card holds its own busy flag and its own refusal, because a confirmation
/// belongs to one row: a failure on the ferritin line must not put an error
/// across the haemoglobin line above it.
class _ResultCard extends ConsumerStatefulWidget {
  const _ResultCard({required this.reportId, required this.result});

  final String reportId;
  final LabResult result;

  @override
  ConsumerState<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends ConsumerState<_ResultCard> {
  /// True while the panel asking about this value is open.
  bool _open = false;

  /// True while the confirmation is with the backend. It blocks a second tap
  /// and shows the spinner, and it is cleared in a `finally` so no path out of
  /// here can leave the button spinning for ever.
  bool _confirming = false;

  /// The last refusal, in our own words, or null.
  String? _error;

  /// Send the confirmation, and let the screen change only afterwards.
  ///
  /// Nothing on this card is altered on the strength of the tap. If the write
  /// succeeds the report is fetched again and whatever comes back is what is
  /// shown; a value that says it has been confirmed when the backend never
  /// heard about it is exactly the lie this app must not tell.
  Future<void> _confirm(String rowId) async {
    if (_confirming) {
      // A second tap while the first is in flight would post the same
      // confirmation twice.
      return;
    }
    setState(() {
      _confirming = true;
      _error = null;
    });

    String? failure;
    try {
      await ref.read(healthRepositoryProvider).confirmResult(
            reportId: widget.reportId,
            resultId: rowId,
          );
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'That could not be saved just now. Nothing has changed - '
            'try again in a moment.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _confirming = false;
          _error = failure;
        });
      }
    }

    if (failure != null || !mounted) {
      return;
    }
    ref.invalidate(reportProvider(widget.reportId));
  }

  @override
  Widget build(BuildContext context) {
    final LabResult result = widget.result;
    final HpPalette p = context.hp;
    final HpSeverity severity = result.status.severity;

    return HpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  result.displayName,
                  style: HpType.bodyStrong.copyWith(color: p.ink),
                ),
              ),
              const SizedBox(width: HpSpacing.md),
              Text(
                result.valueLabel,
                style: HpType.figureSmall.copyWith(color: p.ink),
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.md),
          HpStatusChip(severity: severity, label: result.status.label),
          if (result.plainLanguage != null) ...<Widget>[
            const SizedBox(height: HpSpacing.md),
            Text(
              result.plainLanguage!,
              style: HpType.reading.copyWith(color: p.inkMuted),
            ),
          ],
          if (result.needsReview) ...<Widget>[
            const SizedBox(height: HpSpacing.md),
            _reviewSection(context, result),
          ],
          const SizedBox(height: HpSpacing.lg),
          Container(height: 1, color: p.hairline),
          const SizedBox(height: HpSpacing.md),
          if (result.printedRange != null)
            _MetaRow(
              label: 'Printed on your report',
              value: '${result.printedRange} ${result.unit}',
            ),
          if (result.measuredOn != null)
            _MetaRow(
              label: 'Measured',
              value: HpFormat.dayWithYear(result.measuredOn!),
            ),
          if (result.sourceCitation != null)
            _MetaRow(
              label: 'Range source',
              value: result.sourceCitation!,
            ),
        ],
      ),
    );
  }

  /// What we show on a row we were not confident about.
  ///
  /// Without a row id there is nothing to confirm - the backend addresses these
  /// by the id of the stored row - so the card says so plainly rather than
  /// offering a button that could not do anything.
  Widget _reviewSection(BuildContext context, LabResult result) {
    final HpPalette p = context.hp;
    final String? rowId = result.rowId;
    if (rowId == null) {
      return Text(
        'We were not sure about this line. Open this report again to check it '
        'against the printed copy.',
        style: HpType.label.copyWith(color: p.inkMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        HpButton(
          label: _open ? 'Not now' : 'Check this against your report',
          tone: HpButtonTone.secondary,
          expand: false,
          onPressed: _confirming
              ? null
              : () => setState(() {
                    _open = !_open;
                    _error = null;
                  }),
        ),
        if (_open) _confirmPanel(context, result, rowId),
      ],
    );
  }

  /// The question itself.
  ///
  /// It is a question, not a form. The endpoint behind it takes a yes and
  /// nothing else: there is no way to send a corrected value, so no text field
  /// is offered that would quietly throw one away. What is shown is what we
  /// read, and the only answer the app can carry is "that matches".
  Widget _confirmPanel(BuildContext context, LabResult result, String rowId) {
    final HpPalette p = context.hp;
    final String? error = _error;

    return Padding(
      padding: const EdgeInsets.only(top: HpSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'What we read from your report',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
          const SizedBox(height: HpSpacing.xs),
          Text(
            '${result.displayName} — ${result.valueLabel}',
            style: HpType.bodyStrong.copyWith(color: p.ink),
          ),
          const SizedBox(height: HpSpacing.md),
          Text(
            'We were not confident enough about this line to rely on it, so it '
            'is flagged rather than guessed at. Confirming records that it '
            'matches the paper in front of you. It does not change the value, '
            'and we will not fill one in for you.',
            style: HpType.label.copyWith(color: p.inkMuted),
          ),
          const SizedBox(height: HpSpacing.md),
          if (error != null) ...<Widget>[
            Semantics(
              liveRegion: true,
              container: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.error_outline_rounded,
                    size: 18,
                    color: p.urgentInk,
                  ),
                  const SizedBox(width: HpSpacing.sm),
                  Expanded(
                    child: Text(
                      error,
                      style: HpType.label.copyWith(color: p.urgentInk),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: HpSpacing.md),
          ],
          HpButton(
            label: 'Yes, that matches my report',
            expand: false,
            busy: _confirming,
            onPressed: _confirming ? null : () => _confirm(rowId),
          ),
          const SizedBox(height: HpSpacing.sm),
          Text(
            'If it does not match, leave it as it is and take the printed '
            'report to your doctor. This app will not type a lab value in for '
            'you.',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: HpType.micro.copyWith(color: p.inkFaint),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: HpType.micro.copyWith(color: p.inkMuted),
            ),
          ),
        ],
      ),
    );
  }
}
