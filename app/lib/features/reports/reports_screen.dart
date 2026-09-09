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
import 'trend_sparkline.dart';

/// Everything you have uploaded, and how each value has moved.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HpPalette p = context.hp;
    final AsyncValue<List<HealthReport>> reports = ref.watch(reportsProvider);
    final AsyncValue<List<BiomarkerTrend>> trends = ref.watch(trendsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.upload_file_outlined),
            tooltip: 'Upload a report',
            onPressed: () => _showUploadSheet(context),
          ),
          const SizedBox(width: HpSpacing.sm),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: reports.when(
                loading: () => const HpLoadingState(
                  message: 'Fetching your reports',
                ),
                error: (Object error, StackTrace stack) => HpErrorState(
                  title: 'Reports could not be loaded',
                  body: 'The app could not reach the health engine. Nothing has '
                      'been lost.',
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
                      onAction: () => _showUploadSheet(context),
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

  static void _showUploadSheet(BuildContext context) {
    showModalBottomSheet<void>(
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
                  onTap: () => Navigator.of(sheetContext).pop(),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a photo'),
                  onTap: () => Navigator.of(sheetContext).pop(),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Pick from your gallery'),
                  onTap: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({super.key, required this.report});

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
  const _TrendCard({super.key, required this.trend});

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
