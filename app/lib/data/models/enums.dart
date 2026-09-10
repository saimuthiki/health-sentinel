/// Every enum carries its own wire string and its own display label.
///
/// The wire strings match the check constraints in `db/migrations`; the labels
/// are what a person reads. Keeping both on the enum means a rename can never
/// drift apart from what the database will accept, and no screen has to hold its
/// own switch statement of strings.
library;

/// The three answers the backend can actually store.
///
/// There used to be a fourth, "Prefer not to say". It was never a real option:
/// `health_profiles.sex` has no such value, so the wire mapping sent it as
/// `other`, and the next time the profile was read the person's answer had
/// changed to "Another term" without anybody touching it.
///
/// The question itself stays. `app/rules/classify.py` picks lab reference
/// ranges by sex, and `db/seed/202_reference_ranges.sql` is keyed on it: a
/// haemoglobin that is normal for a woman is anaemia in a man. Dropping the
/// question would not decline to answer it, it would make every lab reading
/// quietly wrong. Only the option that could not survive a reload is gone.
enum Sex {
  female('female', 'Female'),
  male('male', 'Male'),
  other('other', 'Another term');

  const Sex(this.wire, this.label);
  final String wire;
  final String label;

  /// Anything unrecognised reads as [Sex.other] — including `prefer_not_to_say`,
  /// which rows written before this change may still carry, and which the
  /// backend has always read back as `other` too.
  static Sex fromWire(Object? value) => Sex.values.firstWhere(
        (Sex e) => e.wire == value,
        orElse: () => Sex.other,
      );
}

enum DietType {
  veg('veg', 'Vegetarian'),
  nonVeg('non_veg', 'Non-vegetarian'),
  egg('egg', 'Eggetarian'),
  vegan('vegan', 'Vegan'),
  jain('jain', 'Jain');

  const DietType(this.wire, this.label);
  final String wire;
  final String label;

  static DietType fromWire(Object? value) => DietType.values.firstWhere(
        (DietType e) => e.wire == value,
        orElse: () => DietType.veg,
      );
}

enum ActivityLevel {
  sedentary('sedentary', 'Mostly seated', 'Desk work, little walking'),
  light('light', 'Lightly active', 'On your feet some of the day'),
  moderate('moderate', 'Moderately active', 'Exercise or walking most days'),
  active('active', 'Very active', 'Hard training or physical work');

  const ActivityLevel(this.wire, this.label, this.detail);
  final String wire;
  final String label;
  final String detail;

  static ActivityLevel fromWire(Object? value) =>
      ActivityLevel.values.firstWhere(
        (ActivityLevel e) => e.wire == value,
        orElse: () => ActivityLevel.light,
      );
}

enum AllergySeverity {
  mild('mild', 'Mild'),
  moderate('moderate', 'Moderate'),
  severe('severe', 'Severe');

  const AllergySeverity(this.wire, this.label);
  final String wire;
  final String label;

  static AllergySeverity fromWire(Object? value) =>
      AllergySeverity.values.firstWhere(
        (AllergySeverity e) => e.wire == value,
        orElse: () => AllergySeverity.mild,
      );
}

enum ReportStatus {
  uploaded('uploaded', 'Uploaded'),
  extracting('extracting', 'Reading it now'),
  extracted('extracted', 'Ready'),
  failed('failed', 'Could not be read');

  const ReportStatus(this.wire, this.label);
  final String wire;
  final String label;

  static ReportStatus fromWire(Object? value) => ReportStatus.values.firstWhere(
        (ReportStatus e) => e.wire == value,
        orElse: () => ReportStatus.uploaded,
      );
}

/// How a measured value sits against the reference range for this person's age
/// and sex. Set by deterministic backend rules, never by the model, and never
/// stated to the user as a diagnosis.
enum LabStatus {
  criticalLow('critical_low', 'Far below the usual range'),
  low('low', 'Below the usual range'),
  borderlineLow('borderline_low', 'Just below the usual range'),
  normal('normal', 'In the usual range'),
  borderlineHigh('borderline_high', 'Just above the usual range'),
  high('high', 'Above the usual range'),
  criticalHigh('critical_high', 'Far above the usual range'),
  needsReview('needs_review', 'Needs your check');

  const LabStatus(this.wire, this.label);
  final String wire;
  final String label;

  static LabStatus fromWire(Object? value) => LabStatus.values.firstWhere(
        (LabStatus e) => e.wire == value,
        orElse: () => LabStatus.needsReview,
      );
}

/// The tone of a coaching note on the Today screen.
enum NoteTone {
  calm('calm'),
  watch('watch'),
  attention('attention'),
  urgent('urgent'),
  unknown('unknown');

  const NoteTone(this.wire);
  final String wire;

  static NoteTone fromWire(Object? value) => NoteTone.values.firstWhere(
        (NoteTone e) => e.wire == value,
        orElse: () => NoteTone.calm,
      );
}

enum GoalType {
  weight('weight', 'Weight'),
  hair('hair', 'Hair'),
  skin('skin', 'Skin'),
  energy('energy', 'Energy'),
  sleep('sleep', 'Sleep'),
  fitness('fitness', 'Fitness'),
  deficiency('deficiency', 'A low nutrient');

  const GoalType(this.wire, this.label);
  final String wire;
  final String label;

  static GoalType fromWire(Object? value) => GoalType.values.firstWhere(
        (GoalType e) => e.wire == value,
        orElse: () => GoalType.energy,
      );
}

enum GoalStatus {
  active('active', 'Working on it'),
  achieved('achieved', 'Reached'),
  paused('paused', 'Paused'),
  closed('closed', 'Closed');

  const GoalStatus(this.wire, this.label);
  final String wire;
  final String label;

  static GoalStatus fromWire(Object? value) => GoalStatus.values.firstWhere(
        (GoalStatus e) => e.wire == value,
        orElse: () => GoalStatus.active,
      );
}

/// The slots a day is planned in. The default times are Indian household
/// defaults and every one of them is editable in the health profile.
enum MealSlot {
  earlyMorning('early_morning', 'Early morning', '06:30'),
  breakfast('breakfast', 'Breakfast', '08:30'),
  midMorning('mid_morning', 'Mid-morning', '11:00'),
  lunch('lunch', 'Lunch', '13:30'),
  evening('evening', 'Evening', '17:00'),
  dinner('dinner', 'Dinner', '20:30');

  const MealSlot(this.wire, this.label, this.defaultTime);
  final String wire;
  final String label;

  /// 24-hour "HH:mm".
  final String defaultTime;

  static MealSlot fromWire(Object? value) => MealSlot.values.firstWhere(
        (MealSlot e) => e.wire == value,
        orElse: () => MealSlot.breakfast,
      );

  static Map<String, String> get defaultTimes => <String, String>{
        for (final MealSlot slot in MealSlot.values)
          slot.wire: slot.defaultTime,
      };
}

enum ChatRole {
  user('user'),
  assistant('assistant'),
  system('system');

  const ChatRole(this.wire);
  final String wire;

  static ChatRole fromWire(Object? value) => ChatRole.values.firstWhere(
        (ChatRole e) => e.wire == value,
        orElse: () => ChatRole.assistant,
      );
}

enum ConsentType {
  termsOfUse('terms_of_use', 'Terms of use'),
  healthDataProcessing('health_data_processing', 'Health data processing'),
  aiProcessing('ai_processing', 'Analysis by Google Gemini');

  const ConsentType(this.wire, this.label);
  final String wire;
  final String label;

  static ConsentType fromWire(Object? value) => ConsentType.values.firstWhere(
        (ConsentType e) => e.wire == value,
        orElse: () => ConsentType.termsOfUse,
      );
}
