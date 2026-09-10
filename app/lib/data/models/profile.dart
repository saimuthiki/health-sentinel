import 'enums.dart';
import 'json.dart';

/// `profiles` - who the user is to the app.
class UserProfile {
  const UserProfile({
    required this.userId,
    required this.displayName,
    this.locale = 'en_IN',
    this.timezone = 'Asia/Kolkata',
    this.email,
    this.createdAt,
  });

  final String userId;
  final String displayName;
  final String locale;
  final String timezone;
  final String? email;
  final DateTime? createdAt;

  /// The name used in a greeting: "Good morning, Sai".
  String get firstName {
    final String trimmed = displayName.trim();
    if (trimmed.isEmpty) {
      return 'there';
    }
    return trimmed.split(RegExp(r'\s+')).first;
  }

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        userId: asString(json['user_id']),
        displayName: asString(json['display_name']),
        locale: asString(json['locale'], fallback: 'en_IN'),
        timezone: asString(json['timezone'], fallback: 'Asia/Kolkata'),
        email: asStringOrNull(json['email']),
        createdAt: asTimestamp(json['created_at']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'user_id': userId,
        'display_name': displayName,
        'locale': locale,
        'timezone': timezone,
        'email': email,
        'created_at': timestampToJson(createdAt),
      });
}

/// `allergies` - one row per allergen.
class Allergy {
  const Allergy({
    required this.id,
    required this.allergen,
    this.severity = AllergySeverity.mild,
  });

  final String id;
  final String allergen;
  final AllergySeverity severity;

  factory Allergy.fromJson(Map<String, dynamic> json) => Allergy(
        id: asString(json['id']),
        allergen: asString(json['allergen']),
        severity: AllergySeverity.fromWire(json['severity']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'allergen': allergen,
        'severity': severity.wire,
      };
}

/// `health_profiles` - everything the planner needs before it can plan a day.
///
/// The meal, wake and sleep times are not decoration: the alert engine schedules
/// device-local reminders from them, and the meal planner uses them to decide
/// what a "breakfast" even is for this person.
class HealthProfile {
  const HealthProfile({
    required this.userId,
    this.dob,
    this.sex = Sex.other,
    this.heightCm,
    this.weightKg,
    this.activityLevel = ActivityLevel.light,
    this.dietType = DietType.veg,
    this.cuisinePrefs = const <String>[],
    this.city,
    this.pincode,
    this.wakeTime = '06:30',
    this.sleepTime = '22:30',
    this.mealTimes = const <String, String>{},
    this.conditions = const <String>[],
    this.allergies = const <Allergy>[],
    this.goalTypes = const <GoalType>[],
    this.hydrationTargetOverrideMl,
    this.updatedAt,
  });

  final String userId;
  final DateTime? dob;
  final Sex sex;
  final double? heightCm;
  final double? weightKg;
  final ActivityLevel activityLevel;
  final DietType dietType;
  final List<String> cuisinePrefs;
  final String? city;
  final String? pincode;

  /// 24-hour "HH:mm".
  final String wakeTime;
  final String sleepTime;

  /// Keyed by [MealSlot.wire].
  final Map<String, String> mealTimes;

  /// Free text the user told us about, e.g. "thyroid". Never inferred by the app.
  final List<String> conditions;

  final List<Allergy> allergies;

  /// What they want to work on, most important first.
  ///
  /// These are rows in `goals`, not a column on `health_profiles`, but they are
  /// carried on the profile because that is how they are asked and how they are
  /// saved: one multi-select in the wizard, one `PUT /v1/me/profile`.
  final List<GoalType> goalTypes;

  /// A water target the person set for themselves, in millilitres, or null when
  /// they have not set one.
  ///
  /// Held and sent, never interpreted. What a sensible figure is, and what wins
  /// when it disagrees with the computed target, belongs to the hydration work
  /// and not to this model.
  final int? hydrationTargetOverrideMl;

  final DateTime? updatedAt;

  int? get ageYears {
    final DateTime? birth = dob;
    if (birth == null) {
      return null;
    }
    final DateTime now = DateTime.now();
    int years = now.year - birth.year;
    final bool beforeBirthday = now.month < birth.month ||
        (now.month == birth.month && now.day < birth.day);
    if (beforeBirthday) {
      years -= 1;
    }
    return years < 0 ? null : years;
  }

  HealthProfile copyWith({
    DateTime? dob,
    Sex? sex,
    double? heightCm,
    double? weightKg,
    ActivityLevel? activityLevel,
    DietType? dietType,
    List<String>? cuisinePrefs,
    String? city,
    String? pincode,
    String? wakeTime,
    String? sleepTime,
    Map<String, String>? mealTimes,
    List<String>? conditions,
    List<Allergy>? allergies,
    List<GoalType>? goalTypes,
    int? hydrationTargetOverrideMl,
    DateTime? updatedAt,
  }) {
    return HealthProfile(
      userId: userId,
      dob: dob ?? this.dob,
      sex: sex ?? this.sex,
      heightCm: heightCm ?? this.heightCm,
      weightKg: weightKg ?? this.weightKg,
      activityLevel: activityLevel ?? this.activityLevel,
      dietType: dietType ?? this.dietType,
      cuisinePrefs: cuisinePrefs ?? this.cuisinePrefs,
      city: city ?? this.city,
      pincode: pincode ?? this.pincode,
      wakeTime: wakeTime ?? this.wakeTime,
      sleepTime: sleepTime ?? this.sleepTime,
      mealTimes: mealTimes ?? this.mealTimes,
      conditions: conditions ?? this.conditions,
      allergies: allergies ?? this.allergies,
      goalTypes: goalTypes ?? this.goalTypes,
      hydrationTargetOverrideMl:
          hydrationTargetOverrideMl ?? this.hydrationTargetOverrideMl,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory HealthProfile.fromJson(Map<String, dynamic> json) => HealthProfile(
        userId: asString(json['user_id']),
        dob: asDate(json['dob']),
        sex: Sex.fromWire(json['sex']),
        heightCm: asDoubleOrNull(json['height_cm']),
        weightKg: asDoubleOrNull(json['weight_kg']),
        activityLevel: ActivityLevel.fromWire(json['activity_level']),
        dietType: DietType.fromWire(json['diet_type']),
        cuisinePrefs: asStringList(json['cuisine_pref']),
        city: asStringOrNull(json['city']),
        pincode: asStringOrNull(json['pincode']),
        wakeTime: asString(json['wake_time'], fallback: '06:30'),
        sleepTime: asString(json['sleep_time'], fallback: '22:30'),
        mealTimes: asStringMap(json['meal_times']),
        conditions: asStringList(json['conditions']),
        allergies: asMapList(json['allergies'])
            .map(Allergy.fromJson)
            .toList(),
        goalTypes: asStringList(json['goal_types'])
            .map(GoalType.fromWire)
            .toList(),
        hydrationTargetOverrideMl:
            asIntOrNull(json['hydration_target_override_ml']),
        updatedAt: asTimestamp(json['updated_at']),
      );

  Map<String, dynamic> toJson() => prune(<String, dynamic>{
        'user_id': userId,
        'dob': dateToJson(dob),
        'sex': sex.wire,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'activity_level': activityLevel.wire,
        'diet_type': dietType.wire,
        'cuisine_pref': cuisinePrefs,
        'city': city,
        'pincode': pincode,
        'wake_time': wakeTime,
        'sleep_time': sleepTime,
        'meal_times': mealTimes,
        'conditions': conditions,
        'allergies':
            allergies.map((Allergy a) => a.toJson()).toList(),
        'goal_types': goalTypes.map((GoalType g) => g.wire).toList(),
        'hydration_target_override_ml': hydrationTargetOverrideMl,
        'updated_at': timestampToJson(updatedAt),
      });
}

/// `consents` - what was agreed to, when, and against which version of the text.
class ConsentRecord {
  const ConsentRecord({
    required this.id,
    required this.consentType,
    required this.version,
    required this.acceptedAt,
  });

  final String id;
  final ConsentType consentType;
  final String version;
  final DateTime acceptedAt;

  factory ConsentRecord.fromJson(Map<String, dynamic> json) => ConsentRecord(
        id: asString(json['id']),
        consentType: ConsentType.fromWire(json['consent_type']),
        version: asString(json['version']),
        acceptedAt: asTimestamp(json['accepted_at']) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'consent_type': consentType.wire,
        'version': version,
        'accepted_at': acceptedAt.toIso8601String(),
      };
}
