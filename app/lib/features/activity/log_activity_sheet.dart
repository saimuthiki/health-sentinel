import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import 'activity_service.dart';

/// What the sheet hands back to the card that opened it.
///
/// Deliberately not the write itself. The sheet's job is to collect an answer;
/// the card owns the busy flag, the failure message and the refresh, exactly the
/// way `hydration_card.dart` splits the "other amount" sheet from the write.
@immutable
class ActivityEntry {
  const ActivityEntry({
    required this.activityKey,
    required this.label,
    required this.minutes,
    this.intensity,
  });

  final String activityKey;
  final String label;
  final int minutes;

  /// Sent only for "Something else". The backend refuses one on any activity
  /// that has a published intensity of its own.
  final String? intensity;
}

/// Ask what was done and for how long.
///
/// Returns null when the sheet is dismissed, which is the commonest outcome and
/// is not a failure.
Future<ActivityEntry?> showLogActivitySheet(
  BuildContext context, {
  required ActivityCatalogue catalogue,
}) {
  return showModalBottomSheet<ActivityEntry>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) =>
        LogActivitySheet(catalogue: catalogue),
  );
}

/// Two questions, one sheet: which activity, then how many minutes.
///
/// The list comes first and it is the whole point of this change. "Movement" is
/// not a thing anybody does; badminton is. Every row is a name a person would
/// use for what they actually spent an hour on, and each carries the published
/// figure its energy estimate is worked out from - shown on the second step, so
/// nobody has to take the number on trust.
///
/// Nothing here calculates a kilocalorie. The figure comes back from the server
/// with the reply, for the same reason no nutrient number is ever composed on
/// the phone.
class LogActivitySheet extends StatefulWidget {
  const LogActivitySheet({super.key, required this.catalogue});

  final ActivityCatalogue catalogue;

  @override
  State<LogActivitySheet> createState() => _LogActivitySheetState();
}

class _LogActivitySheetState extends State<LogActivitySheet> {
  /// One tap of the plus and minus buttons.
  static const int _step = 5;

  /// What the field will accept. The upper end is the backend's own limit; the
  /// lower end stops a stray "0 minutes" write.
  static const int _shortest = 5;
  static const int _longest = 600;

  /// Which row was tapped, or null while the list is still the question.
  ActivityType? _chosen;

  /// Only ever read for the one row that has no published intensity.
  String _intensity = 'moderate';

  final TextEditingController _minutes = TextEditingController(text: '30');

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  /// The number in the field, or null when it is empty or out of range.
  int? get _entered {
    final int? typed = int.tryParse(_minutes.text.trim());
    if (typed == null || typed < _shortest || typed > _longest) {
      return null;
    }
    return typed;
  }

  void _nudge(int by) {
    int next = (_entered ?? 30) + by;
    if (next < _shortest) {
      next = _shortest;
    }
    if (next > _longest) {
      next = _longest;
    }
    _minutes.text = next.toString();
    _minutes.selection =
        TextSelection.collapsed(offset: _minutes.text.length);
    setState(() {});
  }

  /// Hand the answer back. A method rather than a closure over a nullable local,
  /// so nothing has to reason about promotion inside a callback.
  void _confirm() {
    final ActivityType? chosen = _chosen;
    final int? minutes = _entered;
    if (chosen == null || minutes == null) {
      return;
    }
    Navigator.of(context).pop(
      ActivityEntry(
        activityKey: chosen.key,
        label: chosen.label,
        minutes: minutes,
        intensity: chosen.needsIntensity ? _intensity : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // The keyboard covers the bottom of the sheet the moment the minutes
      // field is tapped, and the button that finishes the job is down there.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HpSpacing.gutter,
            0,
            HpSpacing.gutter,
            HpSpacing.xxl,
          ),
          child: _chosen == null ? _buildPicker(context) : _buildMinutes(context),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ step one

  Widget _buildPicker(BuildContext context) {
    final HpPalette p = context.hp;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'What did you do?',
          style: HpType.headline.copyWith(color: p.ink),
        ),
        const SizedBox(height: HpSpacing.sm),
        Text(
          'Pick the closest one. Each has a published energy cost behind it, so '
          'naming it is what turns minutes into an estimate of energy.',
          style: HpType.body.copyWith(color: p.inkMuted),
        ),
        const SizedBox(height: HpSpacing.lg),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: widget.catalogue.activities.length,
            separatorBuilder: (BuildContext gapContext, int gapIndex) =>
                const SizedBox(height: HpSpacing.xs),
            itemBuilder: (BuildContext itemContext, int index) {
              final ActivityType activity =
                  widget.catalogue.activities[index];
              return _ActivityRow(
                activity: activity,
                onTap: () => setState(() => _chosen = activity),
              );
            },
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ step two

  Widget _buildMinutes(BuildContext context) {
    final HpPalette p = context.hp;
    final ActivityType chosen = _chosen!;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  chosen.label,
                  style: HpType.headline.copyWith(color: p.ink),
                ),
              ),
              HpTextAction(
                label: 'Change',
                onPressed: () => setState(() => _chosen = null),
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.xs),
          Text(
            chosen.example,
            style: HpType.body.copyWith(color: p.inkMuted),
          ),
          const SizedBox(height: HpSpacing.xl),

          if (chosen.needsIntensity) ...<Widget>[
            Text(
              'How hard was it?',
              style: HpType.label.copyWith(color: p.inkMuted),
            ),
            const SizedBox(height: HpSpacing.sm),
            Row(
              children: <Widget>[
                Expanded(
                  child: _EffortChoice(
                    label: 'Moderate',
                    detail: 'You could talk, but not sing',
                    selected: _intensity == 'moderate',
                    onTap: () => setState(() => _intensity = 'moderate'),
                  ),
                ),
                const SizedBox(width: HpSpacing.sm),
                Expanded(
                  child: _EffortChoice(
                    label: 'Vigorous',
                    detail: 'Too hard to hold a conversation',
                    selected: _intensity == 'vigorous',
                    onTap: () => setState(() => _intensity = 'vigorous'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: HpSpacing.xl),
          ],

          Text(
            'How long?',
            style: HpType.label.copyWith(color: p.inkMuted),
          ),
          const SizedBox(height: HpSpacing.sm),
          Row(
            children: <Widget>[
              IconButton(
                onPressed: () => _nudge(-_step),
                icon: const Icon(Icons.remove_rounded),
                tooltip: '$_step minutes less',
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('activity-minutes-field'),
                  controller: _minutes,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  style: HpType.figureSmall.copyWith(color: p.ink),
                  decoration: const InputDecoration(suffixText: 'minutes'),
                  onChanged: (String _) => setState(() {}),
                ),
              ),
              IconButton(
                onPressed: () => _nudge(_step),
                icon: const Icon(Icons.add_rounded),
                tooltip: '$_step minutes more',
              ),
            ],
          ),
          const SizedBox(height: HpSpacing.sm),
          Text(
            'Anything from $_shortest to $_longest minutes.',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),

          if (!chosen.countsTowardTarget) ...<Widget>[
            const SizedBox(height: HpSpacing.lg),
            Text(
              // Said before the write, not discovered afterwards when the bar
              // does not move.
              '${chosen.label} is gentler than the weekly minutes target counts, '
              'so this will not move that bar. It is still exercise, it is still '
              'recorded, and it still gets an energy estimate.',
              style: HpType.micro.copyWith(color: p.inkMuted),
            ),
          ],

          const SizedBox(height: HpSpacing.xl),
          HpButton(
            label: 'Add it',
            onPressed: _entered == null ? null : _confirm,
          ),
          const SizedBox(height: HpSpacing.lg),
          // The per-activity citation, on the screen where the number is about
          // to be produced rather than buried in a settings page.
          Text(
            chosen.source,
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
          const SizedBox(height: HpSpacing.sm),
          Text(
            widget.catalogue.energyBasis,
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
        ],
      ),
    );
  }
}

/// One name in the list, with what it looks like in a life underneath.
class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.activity, required this.onTap});

  final ActivityType activity;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Semantics(
      button: true,
      label: '${activity.label}. ${activity.example}',
      excludeSemantics: true,
      child: Material(
        color: p.surface,
        borderRadius: HpRadii.fieldRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints:
                const BoxConstraints(minHeight: HpSpacing.minTapTarget),
            padding: const EdgeInsets.symmetric(
              horizontal: HpSpacing.md,
              vertical: HpSpacing.sm,
            ),
            decoration: BoxDecoration(
              borderRadius: HpRadii.fieldRadius,
              border: Border.all(color: p.outline),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        activity.label,
                        style: HpType.bodyStrong.copyWith(color: p.ink),
                      ),
                      const SizedBox(height: HpSpacing.xxs),
                      Text(
                        activity.example,
                        style: HpType.micro.copyWith(color: p.inkFaint),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: HpSpacing.sm),
                Icon(Icons.chevron_right_rounded, size: 20, color: p.inkFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Moderate or vigorous, described in words anybody can check against their own
/// memory of the hour rather than in METs.
class _EffortChoice extends StatelessWidget {
  const _EffortChoice({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;

    return Semantics(
      button: true,
      selected: selected,
      label: '$label. $detail',
      excludeSemantics: true,
      child: Material(
        color: selected ? p.pineSoft : p.surface,
        borderRadius: HpRadii.fieldRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints:
                const BoxConstraints(minHeight: HpSpacing.minTapTarget),
            padding: const EdgeInsets.all(HpSpacing.md),
            decoration: BoxDecoration(
              borderRadius: HpRadii.fieldRadius,
              border: Border.all(color: selected ? p.pine : p.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: HpType.bodyStrong.copyWith(
                    color: selected ? p.pineDeep : p.ink,
                  ),
                ),
                const SizedBox(height: HpSpacing.xxs),
                Text(
                  detail,
                  style: HpType.micro.copyWith(color: p.inkFaint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
