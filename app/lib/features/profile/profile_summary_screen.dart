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

/// One thing the profile knows about you, and one thing you can change on its
/// own without touching anything else.
///
/// The list is deliberately finer-grained than the wizard's six steps. A step is
/// the right unit for asking somebody a question they have never been asked
/// before; it is the wrong unit for changing your city, which is a single fact
/// and should cost a single tap.
enum _Answer {
  dateOfBirth,
  sex,
  height,
  weight,
  diet,
  cuisines,
  allergies,
  conditions,
  wakeAndSleep,
  mealTimes,
  activity,
  city,
  pincode,
  goals,
}

/// Everything the profile already holds, with each answer editable on its own.
///
/// This screen exists because of a bug report in the owner's own words: tapping
/// "Health profile" in More started the six-step first-run wizard again, from
/// question one, with every box empty and no way back. Nothing was actually
/// lost - the answers were on the server the whole time - but the screen had no
/// idea they existed, so it asked for all of them again, and being asked for
/// your date of birth for the third time is how somebody stops trusting an app
/// with their health data.
///
/// Three decisions are worth knowing before reading the code.
///
/// **The working copy is the whole profile, always.** On arrival this fetches
/// the saved profile and puts *all* of it into the wizard's working copy, and
/// every edit is a change to that one record. That is not tidiness: the backend
/// replaces the profile on every save (`PUT /v1/me/profile`), so a save built
/// from only the field being edited would blank every other answer. Seeding the
/// whole record and changing one field of it is what makes "change my city"
/// unable to erase an allergy.
///
/// **One question is open at a time.** Opening a second closes the first and
/// puts its answer back as it was, so there is never a half-made change sitting
/// in the working copy waiting to be sent by a save nobody connected it to.
///
/// **Saving is per change, and a refusal keeps the change.** The busy flag is
/// cleared in a `finally`, the refusal is shown in this app's own words, and the
/// edit stays on screen and stays sendable - the same shape as the consent
/// screen, whose missing `finally` once locked the owner out of his account.
class ProfileSummaryScreen extends ConsumerStatefulWidget {
  const ProfileSummaryScreen({super.key});

  @override
  ConsumerState<ProfileSummaryScreen> createState() =>
      _ProfileSummaryScreenState();
}

class _ProfileSummaryScreenState extends ConsumerState<ProfileSummaryScreen> {
  /// True until the first fetch answers, one way or the other.
  bool _loading = true;

  /// Why the profile could not be fetched at all, in our own words.
  String? _loadFailure;

  /// Whether the backend has a profile for this account yet.
  bool _hasProfile = false;

  /// The question whose editor is open, or null when the page is being read.
  _Answer? _open;

  /// The whole profile as it stood when that editor was opened.
  ///
  /// Cancel puts this back, so backing out of a change costs nothing and needs
  /// no second trip to the server.
  HealthProfile? _beforeEdit;

  bool _saving = false;

  /// Why the last save did not happen. Shown inside the open editor, which
  /// stays open and stays usable: a refused save is not a reason to throw away
  /// what somebody just typed.
  String? _saveFailure;

  /// Whether the last save succeeded, so the screen can say so plainly.
  bool _justSaved = false;

  final TextEditingController _height = TextEditingController();
  final TextEditingController _weight = TextEditingController();
  final TextEditingController _city = TextEditingController();
  final TextEditingController _pincode = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
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

  /// Fetch the saved profile and make it the working copy.
  ///
  /// Called on arrival and by "Try again". The whole record goes in, not the
  /// parts this screen happens to show, because the next save sends the whole
  /// record back.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailure = null;
    });

    String? failure;
    HealthProfile? fetched;
    try {
      fetched = await ref.read(healthRepositoryProvider).loadHealthProfile();
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'We could not fetch your health profile just now. Nothing '
            'has changed - try again in a moment.',
      );
    } finally {
      // Everything that touches the widget or the working copy happens here,
      // behind one `mounted` check: this screen can be left while the fetch is
      // still out, and reaching for `ref` after that throws.
      if (mounted) {
        final HealthProfile? loaded = fetched;
        if (loaded != null) {
          _wizard.update((HealthProfile current) => loaded);
        }
        setState(() {
          _loading = false;
          _loadFailure = failure;
          _hasProfile = loaded != null;
        });
      }
    }
  }

  /// Copy the saved answers into the four text boxes.
  ///
  /// Done on every open rather than once, so a box always starts from what is
  /// actually saved rather than from whatever was left in it last time.
  void _seedTextFields(HealthProfile profile) {
    final double? heightCm = profile.heightCm;
    final double? weightKg = profile.weightKg;
    _height.text = heightCm == null ? '' : HpFormat.number(heightCm);
    _weight.text = weightKg == null ? '' : HpFormat.number(weightKg);
    _city.text = profile.city ?? '';
    _pincode.text = profile.pincode ?? '';
  }

  void _openEditor(_Answer answer) {
    if (_saving) {
      return;
    }
    // Opening a second question while another is still open would strand that
    // one's half-made change in the working copy, where the next save would
    // send it without anybody having asked for it. So it is put back first.
    final HealthProfile? before = _beforeEdit;
    if (before != null) {
      _wizard.update((HealthProfile current) => before);
    }
    final HealthProfile current = ref.read(profileWizardProvider);
    _seedTextFields(current);
    setState(() {
      _open = answer;
      _beforeEdit = current;
      _saveFailure = null;
      _justSaved = false;
    });
  }

  void _cancelEditor() {
    if (_saving) {
      return;
    }
    final HealthProfile? before = _beforeEdit;
    if (before != null) {
      _wizard.update((HealthProfile current) => before);
    }
    setState(() {
      _open = null;
      _beforeEdit = null;
      _saveFailure = null;
      _justSaved = false;
    });
  }

  /// Read the four text boxes back into the working copy.
  ///
  /// An empty box is left alone rather than written as a blank. That is not
  /// laziness: `HealthProfile.copyWith` reads null as "leave this as it is",
  /// and the wire format drops null fields from the request altogether, so a
  /// blanked box could not clear the saved answer even if we asked it to. The
  /// helper text under each optional box says so, rather than offering a
  /// gesture that quietly does nothing.
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

  /// Send the whole profile, with this one answer changed.
  ///
  /// The busy flag is set before anything can throw and cleared in a `finally`,
  /// so no path out of here - a refusal, a timeout while the free host wakes, a
  /// bug in the repository - can leave the button spinning for ever. A second
  /// tap while the first is in flight is turned away rather than sending the
  /// profile twice.
  Future<void> _save() async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _saveFailure = null;
      _justSaved = false;
    });

    _commitTextFields();

    String? failure;
    try {
      await _wizard.save();
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'That change could not be saved just now. It is still on '
            'screen, and nothing already saved has been touched - try again in '
            'a moment.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveFailure = failure;
          _justSaved = failure == null;
          if (failure == null) {
            _open = null;
            _beforeEdit = null;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final HealthProfile profile = ref.watch(profileWizardProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to More',
          onPressed: () => context.go('/more'),
        ),
        title: const Text('Health profile'),
      ),
      body: SafeArea(bottom: false, child: _body(profile)),
    );
  }

  Widget _body(HealthProfile profile) {
    if (_loading && !_hasProfile) {
      return const HpLoadingState(
        message: 'Getting your health profile',
        detail: 'The health engine sleeps between visits, so the first look of '
            'the day can take a moment.',
      );
    }

    final String? loadFailure = _loadFailure;
    if (loadFailure != null && !_hasProfile) {
      return HpErrorState(
        title: 'We could not fetch your health profile',
        body: loadFailure,
        onRetry: _load,
      );
    }

    if (!_hasProfile) {
      return HpEmptyState(
        icon: Icons.tune_rounded,
        title: 'Nothing saved here yet',
        body: 'Once you have answered a few questions about how you eat, when '
            'you sleep and what you want to work on, this is where all of it '
            'lives - and where you change any one of it without going through '
            'the rest.',
        actionLabel: 'Set up my health profile',
        onAction: () => context.go(profileWizardPath),
      );
    }

    return _answers(profile);
  }

  Widget _answers(HealthProfile profile) {
    final HpPalette p = context.hp;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HpSpacing.gutter,
        HpSpacing.lg,
        HpSpacing.gutter,
        HpSpacing.section,
      ),
      children: <Widget>[
        Text(
          'Everything you have told us. Change any one of these on its own — '
          'the rest stays exactly as it is.',
          style: HpType.reading.copyWith(color: p.inkMuted),
        ),
        if (_justSaved) ...<Widget>[
          const SizedBox(height: HpSpacing.lg),
          Semantics(
            liveRegion: true,
            container: true,
            child: Row(
              children: <Widget>[
                Icon(Icons.check_circle_outline_rounded,
                    size: 18, color: p.pineDeep),
                const SizedBox(width: HpSpacing.sm),
                Expanded(
                  child: Text(
                    'Saved.',
                    style: HpType.label.copyWith(color: p.pineDeep),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: HpSpacing.xxl),
        const HpSectionHeader(title: 'About you'),
        _row(_Answer.dateOfBirth, profile),
        _row(_Answer.sex, profile),
        _row(_Answer.height, profile),
        _row(_Answer.weight, profile),
        const SizedBox(height: HpSpacing.section),
        const HpSectionHeader(title: 'How you eat'),
        _row(_Answer.diet, profile),
        _row(_Answer.cuisines, profile),
        const SizedBox(height: HpSpacing.section),
        const HpSectionHeader(title: 'Allergies and conditions'),
        _row(_Answer.allergies, profile),
        _row(_Answer.conditions, profile),
        const SizedBox(height: HpSpacing.section),
        const HpSectionHeader(title: 'The shape of your day'),
        _row(_Answer.wakeAndSleep, profile),
        _row(_Answer.mealTimes, profile),
        const SizedBox(height: HpSpacing.section),
        const HpSectionHeader(title: 'How much you move'),
        _row(_Answer.activity, profile),
        const SizedBox(height: HpSpacing.section),
        const HpSectionHeader(title: 'Where you are, and what you want'),
        _row(_Answer.city, profile),
        _row(_Answer.pincode, profile),
        _row(_Answer.goals, profile),
        const SizedBox(height: HpSpacing.section),
        Text(
          'Would you rather be asked the whole set of questions again? Nothing '
          'is cleared: the six steps start from the answers above.',
          style: HpType.label.copyWith(color: p.inkFaint),
        ),
        const SizedBox(height: HpSpacing.md),
        HpButton(
          label: 'Go through all the questions again',
          tone: HpButtonTone.secondary,
          icon: Icons.replay_rounded,
          expand: false,
          onPressed: () => context.go(profileWizardFromReviewPath),
        ),
      ],
    );
  }

  /// One answer: what it is called, what it says, and a way to change it.
  Widget _row(_Answer answer, HealthProfile profile) {
    final HpPalette p = context.hp;
    final bool open = _open == answer;
    final String? value = _valueFor(answer, profile);
    final String? saveFailure = _saveFailure;

    return Padding(
      key: ValueKey<String>('profile-answer-${answer.name}'),
      padding: const EdgeInsets.only(bottom: HpSpacing.sm),
      child: Container(
        padding: const EdgeInsets.all(HpSpacing.lg),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: HpRadii.fieldRadius,
          border: Border.all(
            color: open ? p.pine : p.hairline,
            width: open ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _labelFor(answer),
                        style: HpType.label.copyWith(color: p.inkFaint),
                      ),
                      const SizedBox(height: HpSpacing.xxs),
                      Text(
                        value ?? profileNotAnswered,
                        style: HpType.body.copyWith(
                          color: value == null ? p.inkFaint : p.ink,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: HpSpacing.md),
                HpTextAction(
                  label: open ? 'Cancel' : 'Edit',
                  onPressed: open ? _cancelEditor : () => _openEditor(answer),
                ),
              ],
            ),
            if (open) ...<Widget>[
              const SizedBox(height: HpSpacing.lg),
              Container(height: 1, color: p.hairline),
              const SizedBox(height: HpSpacing.lg),
              ..._editorFor(answer, profile),
              const SizedBox(height: HpSpacing.lg),
              // Changing one answer is still a request to a host that may be
              // asleep, so the wait is named here too.
              const ApiWakingNotice(),
              if (saveFailure != null) ...<Widget>[
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.error_outline_rounded,
                          size: 18, color: p.urgentInk),
                      const SizedBox(width: HpSpacing.sm),
                      Expanded(
                        child: Text(
                          saveFailure,
                          style: HpType.label.copyWith(color: p.urgentInk),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: HpSpacing.md),
              ],
              HpButton(
                label: 'Save this change',
                busy: _saving,
                onPressed: _save,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _labelFor(_Answer answer) {
    switch (answer) {
      case _Answer.dateOfBirth:
        return 'Date of birth';
      case _Answer.sex:
        return 'Sex';
      case _Answer.height:
        return 'Height';
      case _Answer.weight:
        return 'Weight';
      case _Answer.diet:
        return 'What you eat';
      case _Answer.cuisines:
        return 'Food you enjoy';
      case _Answer.allergies:
        return 'Food allergies';
      case _Answer.conditions:
        return 'Conditions a doctor has told you about';
      case _Answer.wakeAndSleep:
        return 'Waking and sleeping';
      case _Answer.mealTimes:
        return 'Meal times';
      case _Answer.activity:
        return 'How much you move';
      case _Answer.city:
        return 'City';
      case _Answer.pincode:
        return 'PIN code';
      case _Answer.goals:
        return 'What you want to work on';
    }
  }

  /// What this answer says, or null when there is nothing to say.
  ///
  /// Null is not the same as an empty string, and the row draws it differently:
  /// [profileNotAnswered] in the faint ink, so a question nobody has got to yet
  /// cannot be mistaken for one answered with a blank.
  ///
  /// The choices that carry a default - sex, diet, activity level, the times -
  /// always read as answered, because the record genuinely holds a value for
  /// them and the app has no way to tell "chose this" from "left it". Making
  /// that distinction would need a nullable field on `HealthProfile`, which is
  /// noted in the report rather than done here.
  String? _valueFor(_Answer answer, HealthProfile profile) {
    switch (answer) {
      case _Answer.dateOfBirth:
        {
          final DateTime? dob = profile.dob;
          if (dob == null) {
            return null;
          }
          final int? age = profile.ageYears;
          if (age == null) {
            return HpFormat.dayWithYear(dob);
          }
          return '${HpFormat.dayWithYear(dob)} · $age years';
        }
      case _Answer.sex:
        return profile.sex.label;
      case _Answer.height:
        {
          final double? cm = profile.heightCm;
          return cm == null ? null : '${HpFormat.number(cm)} cm';
        }
      case _Answer.weight:
        {
          final double? kg = profile.weightKg;
          return kg == null ? null : '${HpFormat.number(kg)} kg';
        }
      case _Answer.diet:
        return profile.dietType.label;
      case _Answer.cuisines:
        return profile.cuisinePrefs.isEmpty
            ? null
            : profile.cuisinePrefs.join(', ');
      case _Answer.allergies:
        return profile.allergies.isEmpty
            ? null
            : profile.allergies
                .map((Allergy a) => '${a.allergen} · ${a.severity.label}')
                .join(', ');
      case _Answer.conditions:
        return profile.conditions.isEmpty
            ? null
            : profile.conditions.join(', ');
      case _Answer.wakeAndSleep:
        return 'Awake ${HpFormat.clockLabel(profile.wakeTime)} · asleep '
            '${HpFormat.clockLabel(profile.sleepTime)}';
      case _Answer.mealTimes:
        {
          final List<String> times = <String>[];
          for (final MealSlot slot in MealSlot.values) {
            final String at =
                profile.mealTimes[slot.wire] ?? slot.defaultTime;
            times.add('${slot.label} ${HpFormat.clockLabel(at)}');
          }
          return times.join(' · ');
        }
      case _Answer.activity:
        return profile.activityLevel.label;
      case _Answer.city:
        {
          final String? city = profile.city;
          return (city == null || city.isEmpty) ? null : city;
        }
      case _Answer.pincode:
        {
          final String? pincode = profile.pincode;
          return (pincode == null || pincode.isEmpty) ? null : pincode;
        }
      case _Answer.goals:
        return profile.goalTypes.isEmpty
            ? null
            : profile.goalTypes.map((GoalType g) => g.label).join(', ');
    }
  }

  /// The control for changing one answer, and nothing else.
  List<Widget> _editorFor(_Answer answer, HealthProfile profile) {
    switch (answer) {
      case _Answer.dateOfBirth:
        return <Widget>[
          ProfileDobRow(
            dob: profile.dob,
            ageYears: profile.ageYears,
            onChanged: (DateTime picked) =>
                _wizard.update((HealthProfile c) => c.copyWith(dob: picked)),
          ),
          _helper('Used only to pick the right reference range for your blood '
              'values.'),
        ];
      case _Answer.sex:
        return <Widget>[
          profileSexChoices(
            selected: profile.sex,
            onChanged: (Sex value) =>
                _wizard.update((HealthProfile c) => c.copyWith(sex: value)),
          ),
          _helper('Reference ranges for haemoglobin, ferritin and others '
              'differ.'),
        ];
      case _Answer.height:
        return <Widget>[
          profileNumberField(
            fieldKey: profileHeightFieldKey,
            controller: _height,
            hint: '168',
            suffix: 'cm',
          ),
          _helper(_emptyKeeps),
        ];
      case _Answer.weight:
        return <Widget>[
          profileNumberField(
            fieldKey: profileWeightFieldKey,
            controller: _weight,
            hint: '64',
            suffix: 'kg',
          ),
          _helper(_emptyKeeps),
        ];
      case _Answer.diet:
        return <Widget>[
          profileDietChoices(
            selected: profile.dietType,
            onChanged: (DietType value) => _wizard
                .update((HealthProfile c) => c.copyWith(dietType: value)),
          ),
        ];
      case _Answer.cuisines:
        return <Widget>[
          profileCuisineChoices(
            selected: profile.cuisinePrefs.toSet(),
            onToggled: _wizard.toggleCuisine,
          ),
          _helper('Pick as many as you like. We start here and learn from '
              'there.'),
        ];
      case _Answer.allergies:
        return <Widget>[
          ProfileAllergyEditor(
            allergies: profile.allergies,
            onAdd: _wizard.addAllergy,
            onRemove: _wizard.removeAllergy,
          ),
          _helper('Nothing on this list will ever appear in a plan.'),
        ];
      case _Answer.conditions:
        return <Widget>[
          profileConditionChoices(
            selected: profile.conditions.toSet(),
            onToggled: _wizard.toggleCondition,
          ),
          _helper('Only what you already know. HealthPulse never decides this '
              'for you.'),
        ];
      case _Answer.wakeAndSleep:
        return <Widget>[
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
          _helper('Your sleep reminder is scheduled by this phone at these '
              'times, so it works even with no signal.'),
        ];
      case _Answer.mealTimes:
        return <Widget>[
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
          _helper('Skip any slot you do not use — just leave it as it is.'),
        ];
      case _Answer.activity:
        return <Widget>[
          profileActivityChoices(
            selected: profile.activityLevel,
            onChanged: (ActivityLevel value) => _wizard
                .update((HealthProfile c) => c.copyWith(activityLevel: value)),
          ),
          _helper('This sets your daily energy and protein targets, using the '
              'ICMR-NIN tables rather than a guess.'),
        ];
      case _Answer.city:
        return <Widget>[
          profileCityField(controller: _city),
          _helper('For seasonal produce and what is easy to buy near you. '
              'Leaving this empty keeps the city already saved.'),
        ];
      case _Answer.pincode:
        return <Widget>[
          profilePincodeField(controller: _pincode),
          _helper(_emptyKeeps),
        ];
      case _Answer.goals:
        return <Widget>[
          profileGoalChoices(
            selected: profile.goalTypes.toSet(),
            onToggled: _wizard.toggleGoal,
          ),
          _helper('Pick up to three. You can change these whenever you like.'),
        ];
    }
  }

  /// Said under every optional box, because it is what actually happens.
  ///
  /// The save replaces the profile, but a field left null is dropped from the
  /// request rather than sent as a blank, so emptying a box cannot remove an
  /// answer the server already has. Promising otherwise would be a button that
  /// lies.
  static const String _emptyKeeps =
      'Leaving this empty keeps the answer already saved.';

  Widget _helper(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: HpSpacing.sm),
      child: Text(
        text,
        style: HpType.label.copyWith(color: context.hp.inkFaint),
      ),
    );
  }
}
