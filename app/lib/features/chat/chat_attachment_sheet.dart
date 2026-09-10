import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../common/failure_copy.dart';

/// The most reports that can travel with one message.
///
/// Five is not a taste decision. `HttpHealthRepository.sendMessage` truncates the
/// list with `.take(5)` before it posts, and the backend refuses a longer one
/// outright, so a picker that let somebody choose six would be an interface
/// promising something the client quietly drops on the way out.
const int maxChatAttachments = 5;

/// What the picker was closed with.
///
/// Three outcomes, not two, and the third is the reason this is a type rather
/// than a list: "take me to Reports so I can upload one" has to be answered by
/// the screen *after* the sheet has finished closing. Navigating from inside the
/// sheet would mean changing the page while the sheet it sits in is still
/// animating out.
class ChatAttachmentResult {
  const ChatAttachmentResult.chosen(this.reports) : openReports = false;

  const ChatAttachmentResult.openReports()
      : reports = null,
        openReports = true;

  /// The reports to attach. Null when nothing was decided here.
  final List<HealthReport>? reports;

  /// The person wants the Reports tab, to put a new report on the system.
  final bool openReports;
}

/// Ask which already-uploaded reports should travel with the next message.
///
/// Returns what the sheet was closed with, or null when it was dismissed with a
/// swipe — in which case the caller keeps whatever was already chosen.
///
/// This picks *reports*, not files, and that is the whole shape of the feature.
/// An attachment here is a report id: the backend read the file once when it was
/// uploaded, and chat sends the id so the answer can talk about the values that
/// came out of it. Sending the file again would pay for a second reading of the
/// same page and get the same numbers back.
Future<ChatAttachmentResult?> showChatAttachmentSheet(
  BuildContext context, {
  required List<HealthReport> selected,
}) {
  return showModalBottomSheet<ChatAttachmentResult>(
    context: context,
    showDragHandle: true,
    // The list of reports can be long, and a sheet capped at half the screen
    // would make a five-report choice a scroll inside a scroll.
    isScrollControlled: true,
    builder: (BuildContext sheetContext) =>
        _AttachmentSheet(selected: selected),
  );
}

class _AttachmentSheet extends ConsumerStatefulWidget {
  const _AttachmentSheet({required this.selected});

  /// What is already attached to the message being written, so reopening the
  /// sheet shows the current choice rather than a blank one.
  final List<HealthReport> selected;

  @override
  ConsumerState<_AttachmentSheet> createState() => _AttachmentSheetState();
}

class _AttachmentSheetState extends ConsumerState<_AttachmentSheet> {
  /// The working copy. Nothing is handed back to the screen until the sheet is
  /// closed with the button, so backing out of it changes nothing.
  late List<HealthReport> _chosen;

  @override
  void initState() {
    super.initState();
    _chosen = List<HealthReport>.of(widget.selected);
  }

  bool _isChosen(HealthReport report) =>
      _chosen.any((HealthReport r) => r.id == report.id);

  void _toggle(HealthReport report) {
    setState(() {
      if (_isChosen(report)) {
        _chosen.removeWhere((HealthReport r) => r.id == report.id);
      } else {
        _chosen.add(report);
      }
    });
  }

  /// Close, and ask the screen to go to Reports — which is where a new file
  /// gets on to the system in the first place.
  void _askForReports() {
    Navigator.of(context).pop(const ChatAttachmentResult.openReports());
  }

  String _label(HealthReport report) => report.labName ?? report.fileName;

  String _detail(HealthReport report) {
    final DateTime? collected = report.collectedOn;
    if (collected == null) {
      // A report still being read has no collection date yet, so say where it
      // has got to instead of showing a blank line.
      return report.status.label;
    }
    return 'Collected ${HpFormat.dayWithYear(collected)}';
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AsyncValue<List<HealthReport>> reports = ref.watch(reportsProvider);

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
              'Attach a report',
              style: HpType.headline.copyWith(color: p.ink),
            ),
            const SizedBox(height: HpSpacing.sm),
            Text(
              'Pick a report you have already uploaded. The values read from it '
              'go with your message, so the answer can talk about your own '
              'numbers.',
              style: HpType.body.copyWith(color: p.inkMuted),
            ),
            const SizedBox(height: HpSpacing.lg),
            Flexible(
              child: reports.when(
                loading: () => _waiting(p),
                error: (Object error, StackTrace stack) =>
                    _unavailable(p, error),
                data: (List<HealthReport> list) =>
                    list.isEmpty ? _nothingYet(p) : _picker(p, list),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _waiting(HpPalette p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HpSpacing.lg),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: p.pine),
          ),
          const SizedBox(width: HpSpacing.md),
          Text(
            'Finding your reports',
            style: HpType.body.copyWith(color: p.inkMuted),
          ),
        ],
      ),
    );
  }

  /// The list could not be fetched. The sentence comes from [explainFailure],
  /// which is the only thing on any screen allowed to turn a thrown object into
  /// words: a raw exception is written for whoever wrote the code.
  Widget _unavailable(HpPalette p, Object error) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Your reports could not be listed',
          style: HpType.bodyStrong.copyWith(color: p.ink),
        ),
        const SizedBox(height: HpSpacing.sm),
        Text(
          explainFailure(
            error,
            fallback: 'The app could not reach the health engine. Your reports '
                'are safe — you can send the message without one attached.',
          ),
          style: HpType.body.copyWith(color: p.inkMuted),
        ),
        const SizedBox(height: HpSpacing.lg),
        HpButton(
          label: 'Try again',
          tone: HpButtonTone.secondary,
          expand: false,
          onPressed: () => ref.invalidate(reportsProvider),
        ),
      ],
    );
  }

  /// Nothing has ever been uploaded. Saying "no reports" on its own would leave
  /// somebody looking for a file picker that is not coming, so this says what an
  /// attachment is here and where the first one comes from.
  Widget _nothingYet(HpPalette p) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'No reports to attach yet',
          style: HpType.bodyStrong.copyWith(color: p.ink),
        ),
        const SizedBox(height: HpSpacing.sm),
        Text(
          'Attaching here means attaching a report you have already uploaded — '
          'a lab PDF or a photo of a printed page. Add one on the Reports tab '
          'and it will be waiting here the next time you ask a question.',
          style: HpType.body.copyWith(color: p.inkMuted),
        ),
        const SizedBox(height: HpSpacing.xl),
        HpButton(
          label: 'Go to Reports',
          expand: false,
          onPressed: _askForReports,
        ),
      ],
    );
  }

  Widget _picker(HpPalette p, List<HealthReport> reports) {
    final bool full = _chosen.length >= maxChatAttachments;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: <Widget>[
              for (final HealthReport report in reports)
                CheckboxListTile(
                  value: _isChosen(report),
                  // A report that is not already chosen stops being tappable at
                  // the cap, rather than being tappable and then refused.
                  onChanged: full && !_isChosen(report)
                      ? null
                      : (bool? _) => _toggle(report),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _label(report),
                    style: HpType.bodyStrong.copyWith(color: p.ink),
                  ),
                  subtitle: Text(
                    _detail(report),
                    style: HpType.label.copyWith(color: p.inkFaint),
                  ),
                ),
            ],
          ),
        ),
        if (full) ...<Widget>[
          const SizedBox(height: HpSpacing.sm),
          Text(
            'Five reports is the most that can go with one message.',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
        ],
        const SizedBox(height: HpSpacing.lg),
        HpButton(
          label: _confirmLabel,
          onPressed: () => Navigator.of(context).pop(
            ChatAttachmentResult.chosen(_chosen),
          ),
        ),
        const SizedBox(height: HpSpacing.xs),
        HpTextAction(
          label: 'Upload a new report',
          icon: Icons.arrow_forward_rounded,
          onPressed: _askForReports,
        ),
      ],
    );
  }

  String get _confirmLabel {
    final int count = _chosen.length;
    if (count == 0) {
      return 'Attach nothing';
    }
    if (count == 1) {
      return 'Attach 1 report';
    }
    return 'Attach $count reports';
  }
}
