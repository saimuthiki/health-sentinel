/// The controls the health profile is made of, in one place.
///
/// Two screens ask about the profile now - the six-step wizard somebody meets
/// once, and the summary they come back to from More - and they have to ask each
/// question in the same words, with the same options, in the same order. If the
/// wizard offered ten cuisines and the summary offered nine, the profile would
/// quietly depend on which screen you happened to use, which is the sort of bug
/// nobody reports and everybody feels.
///
/// Keeping the controls here makes that impossible rather than merely unlikely:
/// there is one list of cuisines, one set of diet options, one allergy editor,
/// and both screens draw the same ones.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';

/// The food somebody might say they enjoy.
///
/// A starting point, not a boundary. The plan learns from what actually gets
/// eaten, so this list only has to be good enough to get a first plan that does
/// not feel like it was written for somebody else.
const List<String> profileCuisines = <String>[
  'South Indian',
  'North Indian',
  'Bengali',
  'Gujarati',
  'Maharashtrian',
  'Andhra and Telangana',
  'Kerala',
  'Punjabi',
  'Continental',
  'East Asian',
];

/// Conditions a doctor may already have told somebody about.
///
/// Only ever what the person reports. HealthPulse never puts a condition on this
/// list by itself - deciding somebody has a condition is a diagnosis, and this
/// app does not make those.
const List<String> profileConditions = <String>[
  'Thyroid',
  'Diabetes',
  'High blood pressure',
  'PCOS',
  'Anaemia',
  'High cholesterol',
  'Acidity or reflux',
  'Asthma',
];

/// What a row says when the profile holds nothing for it.
///
/// An empty space where an answer should be reads as an answer of "none", which
/// is not true. A profile is meant to be filled in a bit at a time, and a
/// question somebody has not got to yet is a different thing from one they
/// answered with silence. Saying so also tells them the row is worth a tap.
const String profileNotAnswered = 'Not answered yet';

/// Keys for the four free-text boxes, so a test - and a screen reader walking
/// the tree - can tell height from weight and city from PIN code. Two number
/// boxes side by side are otherwise indistinguishable from the outside.
const Key profileHeightFieldKey = ValueKey<String>('profile-height-field');
const Key profileWeightFieldKey = ValueKey<String>('profile-weight-field');
const Key profileCityFieldKey = ValueKey<String>('profile-city-field');
const Key profilePincodeFieldKey = ValueKey<String>('profile-pincode-field');
const Key profileAllergenFieldKey = ValueKey<String>('profile-allergen-field');

/// The sentence under a diet option that says what choosing it rules out.
String profileDietDetail(DietType diet) {
  switch (diet) {
    case DietType.veg:
      return 'No meat, fish or egg. Dairy is fine.';
    case DietType.nonVeg:
      return 'Anything goes.';
    case DietType.egg:
      return 'Vegetarian, plus egg.';
    case DietType.vegan:
      return 'No animal products at all, including dairy and honey.';
    case DietType.jain:
      return 'No root vegetables, no onion or garlic.';
  }
}

/// Male, female, another term, or prefer not to say.
Widget profileSexChoices({
  required Sex selected,
  required ValueChanged<Sex> onChanged,
}) {
  return HpChoiceGroup<Sex>(
    choices: <HpChoice<Sex>>[
      for (final Sex sex in Sex.values) HpChoice<Sex>(value: sex, label: sex.label),
    ],
    selected: selected,
    onChanged: onChanged,
  );
}

/// The five diets, each with the sentence that makes it answerable.
Widget profileDietChoices({
  required DietType selected,
  required ValueChanged<DietType> onChanged,
}) {
  return HpChoiceList<DietType>(
    choices: <HpChoice<DietType>>[
      for (final DietType diet in DietType.values)
        HpChoice<DietType>(
          value: diet,
          label: diet.label,
          detail: profileDietDetail(diet),
        ),
    ],
    selected: selected,
    onChanged: onChanged,
  );
}

/// How much somebody moves on an ordinary day. This sets the energy and protein
/// targets, so it is asked as four described choices rather than a slider.
Widget profileActivityChoices({
  required ActivityLevel selected,
  required ValueChanged<ActivityLevel> onChanged,
}) {
  return HpChoiceList<ActivityLevel>(
    choices: <HpChoice<ActivityLevel>>[
      for (final ActivityLevel level in ActivityLevel.values)
        HpChoice<ActivityLevel>(
          value: level,
          label: level.label,
          detail: level.detail,
        ),
    ],
    selected: selected,
    onChanged: onChanged,
  );
}

/// Pick as many kinds of food as you like.
Widget profileCuisineChoices({
  required Set<String> selected,
  required ValueChanged<String> onToggled,
}) {
  return HpMultiChoiceGroup<String>(
    choices: <HpChoice<String>>[
      for (final String cuisine in profileCuisines)
        HpChoice<String>(value: cuisine, label: cuisine),
    ],
    selected: selected,
    onToggled: onToggled,
  );
}

/// Conditions the person says a doctor has told them about.
Widget profileConditionChoices({
  required Set<String> selected,
  required ValueChanged<String> onToggled,
}) {
  return HpMultiChoiceGroup<String>(
    choices: <HpChoice<String>>[
      for (final String condition in profileConditions)
        HpChoice<String>(value: condition, label: condition),
    ],
    selected: selected,
    onToggled: onToggled,
  );
}

/// What the plan should push on first.
Widget profileGoalChoices({
  required Set<GoalType> selected,
  required ValueChanged<GoalType> onToggled,
}) {
  return HpMultiChoiceGroup<GoalType>(
    choices: <HpChoice<GoalType>>[
      for (final GoalType goal in GoalType.values)
        HpChoice<GoalType>(value: goal, label: goal.label),
    ],
    selected: selected,
    onToggled: onToggled,
  );
}

/// A number box for height or weight: digits and one decimal point, nothing else.
Widget profileNumberField({
  required Key fieldKey,
  required TextEditingController controller,
  required String hint,
  required String suffix,
}) {
  return TextFormField(
    key: fieldKey,
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
    ],
    decoration: InputDecoration(hintText: hint, suffixText: suffix),
  );
}

/// The city box. Words, capitalised, no validation - a place name is whatever
/// the person calls it.
Widget profileCityField({required TextEditingController controller}) {
  return TextFormField(
    key: profileCityFieldKey,
    controller: controller,
    textCapitalization: TextCapitalization.words,
    decoration: const InputDecoration(hintText: 'Hyderabad'),
  );
}

/// Six digits, and only six digits.
Widget profilePincodeField({required TextEditingController controller}) {
  return TextFormField(
    key: profilePincodeFieldKey,
    controller: controller,
    keyboardType: TextInputType.number,
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(6),
    ],
    decoration: const InputDecoration(hintText: '500081'),
  );
}

/// The date of birth, as a row that opens the platform date picker.
///
/// It shows the age alongside the date, because the age is the thing the answer
/// is actually for - reference ranges for blood values differ by age - and
/// seeing "32 years" appear is how somebody checks at a glance that they picked
/// the right year rather than the right-looking one.
class ProfileDobRow extends StatelessWidget {
  const ProfileDobRow({
    super.key,
    required this.dob,
    required this.ageYears,
    required this.onChanged,
  });

  final DateTime? dob;
  final int? ageYears;
  final ValueChanged<DateTime> onChanged;

  Future<void> _pick(BuildContext context) async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: dob ?? DateTime(now.year - 30, now.month, now.day),
      firstDate: DateTime(now.year - 110),
      lastDate: now,
      helpText: 'Your date of birth',
    );
    if (picked != null) {
      onChanged(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final DateTime? chosen = dob;
    final int? age = ageYears;

    return Material(
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
                  chosen == null ? 'Choose a date' : HpFormat.dayWithYear(chosen),
                  style: HpType.body.copyWith(
                    color: chosen == null ? p.inkFaint : p.ink,
                  ),
                ),
              ),
              if (age != null)
                Text(
                  '$age years',
                  style: HpType.label.copyWith(color: p.inkFaint),
                ),
              const SizedBox(width: HpSpacing.sm),
              Icon(Icons.event_outlined, size: 18, color: p.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// Allergies: the list so far, a box to add another, and how bad it is.
///
/// This is a small stateful widget rather than a handful of controls, because
/// the half-typed allergen and the severity chosen for it belong to the act of
/// adding one - not to the profile, and not to either screen. Holding them here
/// means the wizard and the summary get identical behaviour without either of
/// them owning a text controller it has to remember to dispose of.
///
/// Allergies are a hard filter on every plan, so removing one is a deliberate
/// tap on the chip's own delete control rather than anything that could happen
/// by brushing the list.
class ProfileAllergyEditor extends StatefulWidget {
  const ProfileAllergyEditor({
    super.key,
    required this.allergies,
    required this.onAdd,
    required this.onRemove,
  });

  final List<Allergy> allergies;

  /// Called with the typed allergen and the severity chosen beside it.
  final void Function(String allergen, AllergySeverity severity) onAdd;

  /// Called with [Allergy.id].
  final ValueChanged<String> onRemove;

  @override
  State<ProfileAllergyEditor> createState() => _ProfileAllergyEditorState();
}

class _ProfileAllergyEditorState extends State<ProfileAllergyEditor> {
  final TextEditingController _allergen = TextEditingController();
  AllergySeverity _severity = AllergySeverity.moderate;

  @override
  void dispose() {
    _allergen.dispose();
    super.dispose();
  }

  void _add() {
    widget.onAdd(_allergen.text, _severity);
    _allergen.clear();
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (widget.allergies.isNotEmpty) ...<Widget>[
          Wrap(
            spacing: HpSpacing.sm,
            runSpacing: HpSpacing.sm,
            children: <Widget>[
              for (final Allergy allergy in widget.allergies)
                InputChip(
                  label: Text('${allergy.allergen} · ${allergy.severity.label}'),
                  onDeleted: () => widget.onRemove(allergy.id),
                  deleteIconColor: p.inkMuted,
                ),
            ],
          ),
          const SizedBox(height: HpSpacing.md),
        ],
        TextFormField(
          key: profileAllergenFieldKey,
          controller: _allergen,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Peanuts, prawns, milk…'),
          onFieldSubmitted: (String value) => _add(),
        ),
        const SizedBox(height: HpSpacing.md),
        HpChoiceGroup<AllergySeverity>(
          choices: <HpChoice<AllergySeverity>>[
            for (final AllergySeverity severity in AllergySeverity.values)
              HpChoice<AllergySeverity>(value: severity, label: severity.label),
          ],
          selected: _severity,
          onChanged: (AllergySeverity value) =>
              setState(() => _severity = value),
        ),
        const SizedBox(height: HpSpacing.md),
        HpButton(
          label: 'Add allergy',
          tone: HpButtonTone.secondary,
          expand: false,
          icon: Icons.add_rounded,
          onPressed: _add,
        ),
      ],
    );
  }
}
