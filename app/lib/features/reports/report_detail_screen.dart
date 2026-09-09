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
                  body: 'The app could not reach the health engine.',
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
  const _Body({super.key, required this.report});

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
          _ResultCard(result: result),
          const SizedBox(height: HpSpacing.md),
        ],
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({super.key, required this.result});

  final LabResult result;

  @override
  Widget build(BuildContext context) {
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
            HpButton(
              label: 'Type what your report says',
              tone: HpButtonTone.secondary,
              expand: false,
              onPressed: () {},
            ),
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
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({super.key, required this.label, required this.value});

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
