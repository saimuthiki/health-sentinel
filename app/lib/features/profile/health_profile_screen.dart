import 'package:flutter/material.dart';
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
import 'profile_inputs.dart';
import 'profile_routing.dart';

/// Setting up the health profile, in six short steps.
///
/// This is the longest form in the app, and it is the one that decides whether
/// the plan is any good, so it is broken into steps small enough to finish while
/// standing up. Every question says why it is being asked - people answer
/// honestly when they can see what the answer is for - and everything except
/// name, diet and the day's times is skippable.
///
/// **This screen is the first run, and only the first run.** It used to be the
/// only way into the profile, which meant that tapping "Health profile" in More
/// started the same six-step interrogation from question one with every box
/// empty, whether you wanted to change your city or not. Coming back is now a
/// different screen - `ProfileSummaryScreen`, at [profileReviewPath] - which
/// shows what is already saved and lets one answer be changed on its own.
///
/// The wizard can still be asked for from there, by somebody who skipped
/// questions the first time and would rather be walked through all of them
/// again. That is what [returnToReview] is for: the same six steps, started
/// from the answers already saved rather than from nothing, with a back control
/// on step one and a finish that goes back to the summary instead of to Today.
class HealthProfileScreen extends ConsumerStatefulWidget {
  const HealthProfileScreen({super.key, this.returnToReview = false});

  /// True when this wizard was opened from the summary rather than from consent.
  ///
  /// Set from the `return` query parameter in `core/router/app_router.dart`, the
  /// same way `?blocked=1` is read on the consent screen. It changes none of the
  /// questions; it only changes where "Back" on step one and "Save profile" on
  /// step six lead, so that somebody who came from More is returned to More.
  final bool returnToReview;

  @override
  ConsumerState<HealthProfileScreen> createState() =>
      _HealthProfileScreenState();
}

class _HealthProfileScreenState extends ConsumerState<HealthProfileScreen> {
  static const int _totalSteps = 6;

  int _step = 1;
  bool _saving = false;

  /// The last refusal from the profile save, in our own words, or null.
  String? _error;

  final TextEditingController _height = TextEditingController();
  final TextEditingController _weight = TextEditingController();
  final TextEditingController _city = TextEditingController();
  final TextEditingController _pincode = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Start the boxes from whatever the working copy already holds.
    //
    // A text controller has no idea a profile exists, so an empty one shows an
    // empty box no matter what has been saved. On a genuine first run the
    // working copy is empty and this changes nothing; when the wizard has been
    // opened again from the summary, it is the difference between "here is
    // what you told us, change what you like" and "type it all in again".
    final HealthProfile current = ref.read(profileWizardProvider);
    final double? heightCm = current.heightCm;
    final double? weightKg = current.weightKg;
    _height.text = heightCm == null ? '' : HpFormat.number(heightCm);
    _weight.text = weightKg == null ? '' : HpFormat.number(weightKg);
    _city.text = current.city ?? '';
    _pincode.text = current.pincode ?? '';
  }

  @override
  void dispose() {
    _height.dispose();
    _weight.dispose();
    _city.dispose();
    _pincode.dispose();
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
    if (_saving) {
      return;
    }
    _commitTextFields();
    if (_step > 1) {
      setState(() => _step -= 1);
      return;
    }
    // Step one, and there is somewhere behind it: the summary this wizard was
    // opened from. Leaving here loses nothing, because everything typed so far
    // is in the working copy and the summary reads the same copy.
    if (widget.returnToReview) {
      context.go(profileReviewPath);
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
    context.go(widget.returnToReview ? profileReviewPath : '/today');
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final HealthProfile profile = ref.watch(profileWizardProvider);
    final String? error = _error;
    // On a first run there is nothing behind step one - consent has already
    // been recorded and going back to it would undo nothing - so no control is
    // offered that would do nothing. From the summary there always is.
    final bool canGoBack = _step > 1 || widget.returnToReview;

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
                      if (canGoBack) ...<Widget>[
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
    return <Widget>[
      HpField(
        label: 'Date of birth',
        helper: 'Used only to pick the right reference range.',
        child: ProfileDobRow(
          dob: profile.dob,
          ageYears: profile.ageYears,
          onChanged: (DateTime picked) =>
              _wizard.update((HealthProfile c) => c.copyWith(dob: picked)),
        ),
      ),
      HpField(
        label: 'Sex',
        helper: 'Reference ranges for haemoglobin, ferritin and others differ.',
        child: profileSexChoices(
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
              child: profileNumberField(
                fieldKey: profileHeightFieldKey,
                controller: _height,
                hint: '168',
                suffix: 'cm',
              ),
            ),
          ),
          const SizedBox(width: HpSpacing.lg),
          Expanded(
            child: HpField(
              label: 'Weight',
              optional: true,
              child: profileNumberField(
                fieldKey: profileWeightFieldKey,
                controller: _weight,
                hint: '64',
                suffix: 'kg',
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
        child: profileDietChoices(
          selected: profile.dietType,
          onChanged: (DietType value) =>
              _wizard.update((HealthProfile c) => c.copyWith(dietType: value)),
        ),
      ),
      HpField(
        label: 'Which food do you actually enjoy?',
        helper: 'Pick as many as you like. We start here and learn from there.',
        child: profileCuisineChoices(
          selected: profile.cuisinePrefs.toSet(),
          onToggled: _wizard.toggleCuisine,
        ),
      ),
    ];
  }

  List<Widget> _allergiesAndConditions(HealthProfile profile) {
    return <Widget>[
      HpField(
        label: 'Any food allergies?',
        helper: 'Nothing you list here will ever appear in a plan.',
        optional: true,
        child: ProfileAllergyEditor(
          allergies: profile.allergies,
          onAdd: _wizard.addAllergy,
          onRemove: _wizard.removeAllergy,
        ),
      ),
      HpField(
        label: 'Has a doctor told you about any of these?',
        helper:
            'Only what you already know. HealthPulse never decides this for you.',
        optional: true,
        child: profileConditionChoices(
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
        child: profileActivityChoices(
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
        child: profileCityField(controller: _city),
      ),
      HpField(
        label: 'PIN code',
        optional: true,
        child: profilePincodeField(controller: _pincode),
      ),
      HpField(
        label: 'What would you like to work on?',
        helper: 'Pick up to three. You can change these whenever you like.',
        child: profileGoalChoices(
          selected: profile.goalTypes.toSet(),
          onToggled: _wizard.toggleGoal,
        ),
      ),
    ];
  }
}
