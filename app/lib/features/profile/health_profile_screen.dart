import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../common/api_waking_notice.dart';
import '../common/failure_copy.dart';

/// Setting up the health profile, in six short steps.
///
/// This is the longest form in the app, and it is the one that decides whether
/// the plan is any good, so it is broken into steps small enough to finish while
/// standing up. Every question says why it is being asked - people answer
/// honestly when they can see what the answer is for - and everything except
/// name, diet and the day's times is skippable.
class HealthProfileScreen extends ConsumerStatefulWidget {
  const HealthProfileScreen({super.key});

  @override
  ConsumerState<HealthProfileScreen> createState() =>
      _HealthProfileScreenState();
}

class _HealthProfileScreenState extends ConsumerState<HealthProfileScreen> {
  static const int _totalSteps = 6;

  static const List<String> _cuisines = <String>[
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

  static const List<String> _conditions = <String>[
    'Thyroid',
    'Diabetes',
    'High blood pressure',
    'PCOS',
    'Anaemia',
    'High cholesterol',
    'Acidity or reflux',
    'Asthma',
  ];

  int _step = 1;
  bool _saving = false;

  /// The last refusal from the profile save, in our own words, or null.
  String? _error;

  final TextEditingController _height = TextEditingController();
  final TextEditingController _weight = TextEditingController();
  final TextEditingController _city = TextEditingController();
  final TextEditingController _pincode = TextEditingController();
  final TextEditingController _allergen = TextEditingController();
  AllergySeverity _allergenSeverity = AllergySeverity.moderate;

  @override
  void dispose() {
    _height.dispose();
    _weight.dispose();
    _city.dispose();
    _pincode.dispose();
    _allergen.dispose();
    super.dispose();
  }

  ProfileWizardController get _wizard =>
      ref.read(profileWizardProvider.notifier);

  void _next() {
    if (_saving) {
      return;
    }
    _commitTextFields();
    if (_step < _totalSteps) {
      setState(() => _step += 1);
    } else {
      // Deliberately not awaited: this is a button callback, and _save owns
      // both the busy flag and every failure it can produce.
      _save();
    }
  }

  void _back() {
    _commitTextFields();
    if (_step > 1) {
      setState(() => _step -= 1);
    }
  }

  void _commitTextFields() {
    _wizard.update(
      (HealthProfile current) => current.copyWith(
        heightCm: double.tryParse(_height.text.trim()),
        weightKg: double.tryParse(_weight.text.trim()),
        city: _city.text.trim().isEmpty ? null : _city.text.trim(),
        pincode: _pincode.text.trim().isEmpty ? null : _pincode.text.trim(),
      ),
    );
  }

  /// Save the profile, and go on **only** if it was actually saved.
  ///
  /// Same shape as the consent screen, and for the same reason: this is the
  /// second call a new account makes, it can arrive while the free host is
  /// still waking, and a spinner that never stops on the last step of a
  /// six-step form is how somebody decides the app is broken and force-quits.
  /// The busy flag is cleared in a `finally`, the failure is shown in our own
  /// words, and the wizard keeps every answer so "try again" costs one tap.
  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    String? failure;
    try {
      await _wizard.save();
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'Your profile could not be saved just now. Everything you '
            'typed is still here - try again in a moment.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = failure;
        });
      }
    }

    if (failure != null) {
      return;
    }
    if (!mounted) {
      return;
    }
    context.go('/today');
  }

  Future<void> _pickDob() async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: ref.read(profileWizardProvider).dob ??
          DateTime(now.year - 30, now.month, now.day),
      firstDate: DateTime(now.year - 110),
      lastDate: now,
      helpText: 'Your date of birth',
    );
    if (picked != null) {
      _wizard.update((HealthProfile c) => c.copyWith(dob: picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final HealthProfile profile = ref.watch(profileWizardProvider);
    final String? error = _error;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HpSpacing.gutter,
                HpSpacing.xl,
                HpSpacing.gutter,
                HpSpacing.lg,
              ),
              child: HpStepIndicator(
                step: _step,
                total: _totalSteps,
                title: _titleFor(_step),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  HpSpacing.gutter,
                  HpSpacing.lg,
                  HpSpacing.gutter,
                  HpSpacing.section,
                ),
                children: <Widget>[
                  Text(
                    _blurbFor(_step),
                    style: HpType.reading.copyWith(color: p.inkMuted),
                  ),
                  const SizedBox(height: HpSpacing.xxl),
                  ..._bodyFor(_step, profile),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(
                HpSpacing.gutter,
                HpSpacing.md,
                HpSpacing.gutter,
                HpSpacing.md,
              ),
              decoration: BoxDecoration(
                color: p.ground,
                border: Border(top: BorderSide(color: p.hairline)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // The profile save is the second request a new account makes,
                  // so it can be the one that pays for the cold start.
                  const ApiWakingNotice(),
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
                  Row(
                    children: <Widget>[
                      if (_step > 1) ...<Widget>[
                        HpButton(
                          label: 'Back',
                          tone: HpButtonTone.secondary,
                          expand: false,
                          onPressed: _back,
                        ),
                        const SizedBox(width: HpSpacing.md),
                      ],
                      Expanded(
                        child: HpButton(
                          label:
                              _step == _totalSteps ? 'Save profile' : 'Continue',
                          busy: _saving,
                          onPressed: _next,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _titleFor(int step) {
    switch (step) {
      case 1:
        return 'About you';
      case 2:
        return 'How you eat';
      case 3:
        return 'Allergies and conditions';
      case 4:
        return 'The shape of your day';
      case 5:
        return 'How much you move';
      default:
        return 'Where you are, and what you want';
    }
  }

  String _blurbFor(int step) {
    switch (step) {
      case 1:
        return 'Reference ranges for blood values differ by age and sex, so this '
            'is what lets us say whether a value is usual for you rather than '
            'usual for everybody.';
      case 2:
        return 'Every meal we suggest is chosen from food you would actually '
            'eat. Tell us the rules and we will not break them.';
      case 3:
        return 'Allergies are a hard filter — nothing on this list will ever '
            'appear in a plan. Conditions help us keep suggestions sensible.';
      case 4:
        return 'Meal, water and sleep reminders are scheduled by your phone at '
            'these times, so they work even with no signal.';
      case 5:
        return 'This sets your daily energy and protein targets, using the '
            'ICMR-NIN tables rather than a guess.';
      default:
        return 'Your city helps with seasonal and local food. Your goals decide '
            'what the plan pushes on first.';
    }
  }

  List<Widget> _bodyFor(int step, HealthProfile profile) {
    switch (step) {
      case 1:
        return _aboutYou(profile);
      case 2:
        return _howYouEat(profile);
      case 3:
        return _allergiesAndConditions(profile);
      case 4:
        return _yourDay(profile);
      case 5:
        return _movement(profile);
      default:
        return _placeAndGoals(profile);
    }
  }

  List<Widget> _aboutYou(HealthProfile profile) {
    final HpPalette p = context.hp;
    final DateTime? dob = profile.dob;
    return <Widget>[
      HpField(
        label: 'Date of birth',
        helper: 'Used only to pick the right reference range.',
        child: Material(
          color: p.surface,
          borderRadius: HpRadii.fieldRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _pickDob,
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
                      dob == null
                          ? 'Choose a date'
                          : HpFormat.dayWithYear(dob),
                      style: HpType.body.copyWith(
                        color: dob == null ? p.inkFaint : p.ink,
                      ),
                    ),
                  ),
                  if (profile.ageYears != null)
                    Text(
                      '${profile.ageYears} years',
                      style: HpType.label.copyWith(color: p.inkFaint),
                    ),
                  const SizedBox(width: HpSpacing.sm),
                  Icon(Icons.event_outlined, size: 18, color: p.inkFaint),
                ],
              ),
            ),
          ),
        ),
      ),
      HpField(
        label: 'Sex',
        helper: 'Reference ranges for haemoglobin, ferritin and others differ.',
        child: HpChoiceGroup<Sex>(
          choices: <HpChoice<Sex>>[
            for (final Sex sex in Sex.values)
              HpChoice<Sex>(value: sex, label: sex.label),
          ],
          selected: profile.sex,
          onChanged: (Sex value) =>
              _wizard.update((HealthProfile c) => c.copyWith(sex: value)),
        ),
      ),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: HpField(
              label: 'Height',
              optional: true,
              child: TextFormField(
                controller: _height,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  hintText: '168',
                  suffixText: 'cm',
                ),
              ),
            ),
          ),
          const SizedBox(width: HpSpacing.lg),
          Expanded(
            child: HpField(
              label: 'Weight',
              optional: true,
              child: TextFormField(
                controller: _weight,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  hintText: '64',
                  suffixText: 'kg',
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _howYouEat(HealthProfile profile) {
    return <Widget>[
      HpField(
        label: 'What do you eat?',
        child: HpChoiceList<DietType>(
          choices: <HpChoice<DietType>>[
            for (final DietType diet in DietType.values)
              HpChoice<DietType>(
                value: diet,
                label: diet.label,
                detail: _dietDetail(diet),
              ),
          ],
          selected: profile.dietType,
          onChanged: (DietType value) =>
              _wizard.update((HealthProfile c) => c.copyWith(dietType: value)),
        ),
      ),
      HpField(
        label: 'Which food do you actually enjoy?',
        helper: 'Pick as many as you like. We start here and learn from there.',
        child: HpMultiChoiceGroup<String>(
          choices: <HpChoice<String>>[
            for (final String cuisine in _cuisines)
              HpChoice<String>(value: cuisine, label: cuisine),
          ],
          selected: profile.cuisinePrefs.toSet(),
          onToggled: _wizard.toggleCuisine,
        ),
      ),
    ];
  }

  static String _dietDetail(DietType diet) {
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

  List<Widget> _allergiesAndConditions(HealthProfile profile) {
    final HpPalette p = context.hp;
    return <Widget>[
      HpField(
        label: 'Any food allergies?',
        helper: 'Nothing you list here will ever appear in a plan.',
        optional: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (profile.allergies.isNotEmpty) ...<Widget>[
              Wrap(
                spacing: HpSpacing.sm,
                runSpacing: HpSpacing.sm,
                children: <Widget>[
                  for (final Allergy allergy in profile.allergies)
                    InputChip(
                      label: Text(
                        '${allergy.allergen} · ${allergy.severity.label}',
                      ),
                      onDeleted: () => _wizard.removeAllergy(allergy.id),
                      deleteIconColor: p.inkMuted,
                    ),
                ],
              ),
              const SizedBox(height: HpSpacing.md),
            ],
            TextFormField(
              controller: _allergen,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Peanuts, prawns, milk…',
              ),
              onFieldSubmitted: (String value) {
                _wizard.addAllergy(value, _allergenSeverity);
                _allergen.clear();
              },
            ),
            const SizedBox(height: HpSpacing.md),
            HpChoiceGroup<AllergySeverity>(
              choices: <HpChoice<AllergySeverity>>[
                for (final AllergySeverity severity in AllergySeverity.values)
                  HpChoice<AllergySeverity>(
                    value: severity,
                    label: severity.label,
                  ),
              ],
              selected: _allergenSeverity,
              onChanged: (AllergySeverity value) =>
                  setState(() => _allergenSeverity = value),
            ),
            const SizedBox(height: HpSpacing.md),
            HpButton(
              label: 'Add allergy',
              tone: HpButtonTone.secondary,
              expand: false,
              icon: Icons.add_rounded,
              onPressed: () {
                _wizard.addAllergy(_allergen.text, _allergenSeverity);
                _allergen.clear();
              },
            ),
          ],
        ),
      ),
      HpField(
        label: 'Has a doctor told you about any of these?',
        helper:
            'Only what you already know. HealthPulse never decides this for you.',
        optional: true,
        child: HpMultiChoiceGroup<String>(
          choices: <HpChoice<String>>[
            for (final String condition in _conditions)
              HpChoice<String>(value: condition, label: condition),
          ],
          selected: profile.conditions.toSet(),
          onToggled: _wizard.toggleCondition,
        ),
      ),
    ];
  }

  List<Widget> _yourDay(HealthProfile profile) {
    return <Widget>[
      HpField(
        label: 'When do you wake and sleep?',
        child: Column(
          children: <Widget>[
            HpTimeRow(
              label: 'Wake up',
              value: HpFormat.clockLabel(profile.wakeTime),
              onChanged: (TimeOfDay time) => _wizard.update(
                (HealthProfile c) =>
                    c.copyWith(wakeTime: HpFormat.formatTime(time)),
              ),
            ),
            const SizedBox(height: HpSpacing.sm),
            HpTimeRow(
              label: 'Go to sleep',
              value: HpFormat.clockLabel(profile.sleepTime),
              onChanged: (TimeOfDay time) => _wizard.update(
                (HealthProfile c) =>
                    c.copyWith(sleepTime: HpFormat.formatTime(time)),
              ),
            ),
          ],
        ),
      ),
      HpField(
        label: 'When do you eat?',
        helper: 'Skip any slot you do not use — just leave it as it is.',
        child: Column(
          children: <Widget>[
            for (final MealSlot slot in MealSlot.values) ...<Widget>[
              HpTimeRow(
                label: slot.label,
                value: HpFormat.clockLabel(
                  profile.mealTimes[slot.wire] ?? slot.defaultTime,
                ),
                onChanged: (TimeOfDay time) =>
                    _wizard.setMealTime(slot, HpFormat.formatTime(time)),
              ),
              const SizedBox(height: HpSpacing.sm),
            ],
          ],
        ),
      ),
    ];
  }

  List<Widget> _movement(HealthProfile profile) {
    return <Widget>[
      HpField(
        label: 'On a normal day',
        child: HpChoiceList<ActivityLevel>(
          choices: <HpChoice<ActivityLevel>>[
            for (final ActivityLevel level in ActivityLevel.values)
              HpChoice<ActivityLevel>(
                value: level,
                label: level.label,
                detail: level.detail,
              ),
          ],
          selected: profile.activityLevel,
          onChanged: (ActivityLevel value) => _wizard
              .update((HealthProfile c) => c.copyWith(activityLevel: value)),
        ),
      ),
    ];
  }

  List<Widget> _placeAndGoals(HealthProfile profile) {
    return <Widget>[
      HpField(
        label: 'City',
        optional: true,
        helper: 'For seasonal produce and what is easy to buy near you.',
        child: TextFormField(
          controller: _city,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Hyderabad'),
        ),
      ),
      HpField(
        label: 'PIN code',
        optional: true,
        child: TextFormField(
          controller: _pincode,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(hintText: '500081'),
        ),
      ),
      HpField(
        label: 'What would you like to work on?',
        helper: 'Pick up to three. You can change these whenever you like.',
        child: HpMultiChoiceGroup<GoalType>(
          choices: <HpChoice<GoalType>>[
            for (final GoalType goal in GoalType.values)
              HpChoice<GoalType>(value: goal, label: goal.label),
          ],
          selected: profile.goalTypes.toSet(),
          onToggled: _wizard.toggleGoal,
        ),
      ),
    ];
  }
}
