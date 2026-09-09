import 'package:flutter/material.dart';

import '../theme/hp_palette.dart';
import '../theme/hp_spacing.dart';
import '../theme/hp_typography.dart';

/// A labelled slot for any input.
///
/// The label sits above the control rather than floating inside it: a floating
/// label disappears the moment someone types, and this form asks people about
/// their sleep and their allergies, where losing the question mid-answer matters.
class HpField extends StatelessWidget {
  const HpField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.optional = false,
  });

  final String label;
  final String? helper;
  final bool optional;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  label,
                  style: HpType.bodyStrong.copyWith(color: p.ink),
                ),
              ),
              if (optional) ...<Widget>[
                const SizedBox(width: HpSpacing.sm),
                Text(
                  'optional',
                  style: HpType.micro.copyWith(color: p.inkFaint),
                ),
              ],
            ],
          ),
          if (helper != null) ...<Widget>[
            const SizedBox(height: HpSpacing.xs),
            Text(helper!, style: HpType.label.copyWith(color: p.inkFaint)),
          ],
          const SizedBox(height: HpSpacing.md),
          child,
        ],
      ),
    );
  }
}

/// One option in a choice group.
@immutable
class HpChoice<T> {
  const HpChoice({required this.value, required this.label, this.detail});

  final T value;
  final String label;

  /// A short clarification, shown under the label when there is room.
  final String? detail;
}

/// Single-select options as wrapping pills.
///
/// A dropdown hides the answers; on a phone, showing all five diet types at once
/// is both faster and kinder. Selection is carried by fill *and* a tick, never by
/// colour alone.
class HpChoiceGroup<T> extends StatelessWidget {
  const HpChoiceGroup({
    super.key,
    required this.choices,
    required this.selected,
    required this.onChanged,
  });

  final List<HpChoice<T>> choices;
  final T? selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: HpSpacing.sm,
      runSpacing: HpSpacing.sm,
      children: <Widget>[
        for (final HpChoice<T> choice in choices)
          _ChoicePill(
            label: choice.label,
            isSelected: choice.value == selected,
            onTap: () => onChanged(choice.value),
          ),
      ],
    );
  }
}

/// Multi-select options as wrapping pills.
class HpMultiChoiceGroup<T> extends StatelessWidget {
  const HpMultiChoiceGroup({
    super.key,
    required this.choices,
    required this.selected,
    required this.onToggled,
  });

  final List<HpChoice<T>> choices;
  final Set<T> selected;
  final ValueChanged<T> onToggled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: HpSpacing.sm,
      runSpacing: HpSpacing.sm,
      children: <Widget>[
        for (final HpChoice<T> choice in choices)
          _ChoicePill(
            label: choice.label,
            isSelected: selected.contains(choice.value),
            onTap: () => onToggled(choice.value),
          ),
      ],
    );
  }
}

class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Semantics(
      selected: isSelected,
      button: true,
      child: Material(
        color: isSelected ? p.pineSoft : p.surface,
        borderRadius: HpRadii.pillRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: HpSpacing.minTapTarget),
            padding: const EdgeInsets.symmetric(
              horizontal: HpSpacing.lg,
              vertical: HpSpacing.md,
            ),
            decoration: BoxDecoration(
              borderRadius: HpRadii.pillRadius,
              border: Border.all(
                color: isSelected ? p.pine : p.outline,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (isSelected) ...<Widget>[
                  Icon(Icons.check_rounded, size: 16, color: p.pineDeep),
                  const SizedBox(width: HpSpacing.sm),
                ],
                Text(
                  label,
                  style: HpType.label.copyWith(
                    color: isSelected ? p.pineDeep : p.ink,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Single-select options as a vertical list, for choices that need a sentence of
/// explanation - activity level, diet type - where a pill would truncate the very
/// thing that helps someone answer honestly.
class HpChoiceList<T> extends StatelessWidget {
  const HpChoiceList({
    super.key,
    required this.choices,
    required this.selected,
    required this.onChanged,
  });

  final List<HpChoice<T>> choices;
  final T? selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Column(
      children: <Widget>[
        for (final HpChoice<T> choice in choices)
          Padding(
            padding: const EdgeInsets.only(bottom: HpSpacing.sm),
            child: Semantics(
              selected: choice.value == selected,
              button: true,
              child: Material(
                color: choice.value == selected ? p.pineSoft : p.surface,
                borderRadius: HpRadii.fieldRadius,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onChanged(choice.value),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 56),
                    padding: const EdgeInsets.all(HpSpacing.lg),
                    decoration: BoxDecoration(
                      borderRadius: HpRadii.fieldRadius,
                      border: Border.all(
                        color: choice.value == selected ? p.pine : p.outline,
                        width: choice.value == selected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          choice.value == selected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 20,
                          color: choice.value == selected ? p.pine : p.outline,
                        ),
                        const SizedBox(width: HpSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                choice.label,
                                style: HpType.bodyStrong.copyWith(color: p.ink),
                              ),
                              if (choice.detail != null) ...<Widget>[
                                const SizedBox(height: HpSpacing.xxs),
                                Text(
                                  choice.detail!,
                                  style:
                                      HpType.label.copyWith(color: p.inkMuted),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A row that opens the platform time picker. Used for wake, sleep and each
/// meal time, all of which the plan and the reminders are built from.
class HpTimeRow extends StatelessWidget {
  const HpTimeRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;

  /// Formatted for display, for example "6:45 am".
  final String value;

  final ValueChanged<TimeOfDay> onChanged;

  Future<void> _pick(BuildContext context) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: label,
    );
    if (picked != null) {
      onChanged(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Semantics(
      button: true,
      label: '$label, currently $value',
      excludeSemantics: true,
      child: Material(
        color: p.surface,
        borderRadius: HpRadii.fieldRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _pick(context),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(
              horizontal: HpSpacing.lg,
              vertical: HpSpacing.md,
            ),
            decoration: BoxDecoration(
              borderRadius: HpRadii.fieldRadius,
              border: Border.all(color: p.outline),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: HpType.body.copyWith(color: p.ink),
                  ),
                ),
                Text(
                  value,
                  style: HpType.figureSmall.copyWith(color: p.pineDeep),
                ),
                const SizedBox(width: HpSpacing.sm),
                Icon(Icons.schedule_rounded, size: 18, color: p.inkFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Step 3 of 6", with a segmented rule underneath.
///
/// Numbering is used here because this genuinely is a sequence; it is not used
/// anywhere else in the app.
class HpStepIndicator extends StatelessWidget {
  const HpStepIndicator({
    super.key,
    required this.step,
    required this.total,
    required this.title,
  });

  final int step;
  final int total;
  final String title;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Semantics(
      label: 'Step $step of $total. $title',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Step $step of $total',
            style: HpType.micro.copyWith(color: p.inkFaint),
          ),
          const SizedBox(height: HpSpacing.xs),
          Text(title, style: HpType.title.copyWith(color: p.ink)),
          const SizedBox(height: HpSpacing.lg),
          Row(
            children: <Widget>[
              for (int i = 1; i <= total; i++) ...<Widget>[
                Expanded(
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: i <= step ? p.pine : p.hairline,
                      borderRadius: HpRadii.pillRadius,
                    ),
                  ),
                ),
                if (i != total) const SizedBox(width: HpSpacing.xs),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
