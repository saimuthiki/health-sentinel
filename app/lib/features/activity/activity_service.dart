/// Named exercise, over the wire.
///
/// **Why this is not on `HealthRepository`.** It could be, and one day it should
/// be. It is not today because `data/` is owned elsewhere this round, and the
/// alternative — a card with a button that does nothing until somebody else's
/// change lands — is worse than a small service that works now. The precedent is
/// `features/chat/chat_photo.dart`, which reaches `ApiClient` the same way and
/// for the same reason.
///
/// Everything else about it follows the repository's own habits, because those
/// are what keep the app honest:
///
/// * **No number is composed here.** The kilocalorie figure is worked out on the
///   server from the Compendium MET value and the weight on the profile. This
///   file carries it; it never calculates one, and it never fills a missing one
///   in with a zero.
/// * **No server sentence reaches a screen.** `ApiFailure` is caught and
///   rethrown as an [ActivityException], whose message this app wrote, so
///   `explainFailure` can show it like any other failure.
/// * **Null is an answer.** A build with no backend address gets `null` from
///   [activityServiceProvider] rather than a stub that throws when tapped, so
///   the card can say the honest thing before offering a button.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/api/api_failure.dart';
import '../../data/models/json.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';

/// A failure this app can explain. Extends the repository's exception so that
/// `explainFailure` treats it like every other one.
class ActivityException extends HealthRepositoryException {
  const ActivityException(super.message);
}

/// Shown when this build has no health engine to talk to.
const String activityNeedsBackendMessage =
    'Logging exercise needs the health engine, and this build has no address '
    'for one. The minutes above are sample data.';

/// One named activity, exactly as the backend published it.
///
/// [mets] and [intensity] are null for one row only — "Something else" — where
/// nobody knows what was done and so no published figure applies. That row is
/// the reason [needsIntensity] exists.
class ActivityType {
  const ActivityType({
    required this.key,
    required this.label,
    required this.example,
    required this.source,
    this.mets,
    this.intensity,
    this.countsTowardTarget = true,
    this.needsIntensity = false,
  });

  final String key;
  final String label;

  /// What it looks like in a life: "A social game, singles or doubles".
  final String example;

  /// Where the energy figure for this activity comes from, or why there is not
  /// one. Shown to anyone who asks, never paraphrased.
  final String source;

  final double? mets;

  /// `light`, `moderate`, `vigorous`, or null when only the person can say.
  final String? intensity;

  /// False for activity under 3 METs, which the WHO weekly figure does not
  /// count. It is still worth doing and it still gets an energy figure.
  final bool countsTowardTarget;

  /// True only for "Something else", which cannot be logged without one.
  final bool needsIntensity;

  factory ActivityType.fromJson(Map<String, dynamic> json) => ActivityType(
        key: asString(json['key']),
        label: asString(json['label']),
        example: asString(json['example']),
        source: asString(json['source']),
        mets: asDoubleOrNull(json['mets']),
        intensity: asStringOrNull(json['intensity']),
        countsTowardTarget:
            asBool(json['counts_toward_target'], fallback: true),
        needsIntensity: asBool(json['needs_intensity']),
      );
}

/// The list, and the one caveat that has to travel with every figure from it.
class ActivityCatalogue {
  const ActivityCatalogue({
    required this.activities,
    required this.source,
    required this.energyBasis,
  });

  final List<ActivityType> activities;

  /// The published work every MET value in [activities] came out of.
  final String source;

  /// Why an energy figure is an estimate. The card must not show a number
  /// without showing this somewhere reachable.
  final String energyBasis;

  factory ActivityCatalogue.fromJson(Map<String, dynamic> json) =>
      ActivityCatalogue(
        activities: asMapList(json['activities'])
            .map(ActivityType.fromJson)
            .toList(),
        source: asString(json['source']),
        energyBasis: asString(json['energy_basis']),
      );
}

/// An energy figure, or a stated reason there is not one.
///
/// [kcal] null is never rendered as zero. "We cannot say" and "you burnt
/// nothing" are different sentences and the second one would be a lie.
class ActivityEnergy {
  const ActivityEnergy({
    this.kcal,
    this.unavailableReason,
    this.sessionsWithoutEnergy = 0,
  });

  final int? kcal;

  /// Present only when [kcal] is null: which input was missing.
  final String? unavailableReason;

  /// Sessions inside this total that carry no figure of their own, so the total
  /// is a floor rather than the whole truth.
  final int sessionsWithoutEnergy;

  bool get isKnown => kcal != null;

  factory ActivityEnergy.fromJson(Map<String, dynamic> json) => ActivityEnergy(
        kcal: asIntOrNull(json['kcal']),
        unavailableReason: asStringOrNull(json['unavailable_reason']),
        sessionsWithoutEnergy: asInt(json['sessions_without_energy']),
      );
}

/// What was done over one window of days.
class ActivityTotals {
  const ActivityTotals({
    this.start,
    this.end,
    this.sessions = 0,
    this.minutes = 0,
    this.moderateEquivalentMinutes = 0,
    this.daysLogged = 0,
    this.energy = const ActivityEnergy(),
    this.truncated = false,
  });

  /// The first day this total covers. For the lifetime total it is the first day
  /// with anything logged on it, which is what lets the card name a real date
  /// instead of the untrue phrase "till date".
  final DateTime? start;
  final DateTime? end;

  final int sessions;
  final int minutes;

  /// Minutes in the unit the WHO target is written in: a vigorous minute counts
  /// twice, and light activity is not counted at all.
  final int moderateEquivalentMinutes;

  final int daysLogged;
  final ActivityEnergy energy;

  /// True when the read hit the audit trail's row limit, so this is "at least"
  /// rather than "exactly". See `GAPS.md` item G19.
  final bool truncated;

  bool get isEmpty => sessions == 0;

  factory ActivityTotals.fromJson(Map<String, dynamic> json) => ActivityTotals(
        start: asDate(json['start']),
        end: asDate(json['end']),
        sessions: asInt(json['sessions']),
        minutes: asInt(json['minutes']),
        moderateEquivalentMinutes: asInt(json['moderate_equivalent_minutes']),
        daysLogged: asInt(json['days_logged']),
        energy: ActivityEnergy.fromJson(asMap(json['energy'])),
        truncated: asBool(json['truncated']),
      );
}

/// Today, this week, and everything logged so far.
class ActivitySummary {
  const ActivitySummary({
    required this.today,
    required this.week,
    required this.total,
    this.loggedDaysInARow = 0,
    this.targetMinutesPerDay,
    this.targetMinutesPerWeek,
    this.targetSource = '',
    this.weightKg,
    this.energyBasis = '',
  });

  final ActivityTotals today;
  final ActivityTotals week;
  final ActivityTotals total;

  /// Consecutive days with something logged. A count of logging, and the copy
  /// beside it says exactly that — it is not a claim about anybody's health.
  final int loggedDaysInARow;

  final int? targetMinutesPerDay;
  final int? targetMinutesPerWeek;
  final String targetSource;

  /// The weight the figures were worked out from. Null when the profile has
  /// none, which is also when every [ActivityEnergy] here is unknown.
  final double? weightKg;

  final String energyBasis;

  factory ActivitySummary.fromJson(Map<String, dynamic> json) =>
      ActivitySummary(
        today: ActivityTotals.fromJson(asMap(json['today'])),
        week: ActivityTotals.fromJson(asMap(json['week'])),
        total: ActivityTotals.fromJson(asMap(json['total'])),
        loggedDaysInARow: asInt(json['logged_days_in_a_row']),
        targetMinutesPerDay: asIntOrNull(json['target_minutes_per_day']),
        targetMinutesPerWeek: asIntOrNull(json['target_minutes_per_week']),
        targetSource: asString(json['target_source']),
        weightKg: asDoubleOrNull(json['weight_kg']),
        energyBasis: asString(json['energy_basis']),
      );
}

/// What came back from logging one session.
class LoggedActivity {
  const LoggedActivity({
    required this.label,
    required this.minutes,
    required this.intensity,
    required this.energy,
    this.countsTowardTarget = true,
    this.moderateEquivalentMinutes = 0,
  });

  final String label;
  final int minutes;
  final String intensity;
  final ActivityEnergy energy;
  final bool countsTowardTarget;
  final int moderateEquivalentMinutes;

  factory LoggedActivity.fromJson(Map<String, dynamic> json) => LoggedActivity(
        label: asString(json['label']),
        minutes: asInt(json['minutes']),
        intensity: asString(json['intensity'], fallback: 'moderate'),
        energy: ActivityEnergy.fromJson(asMap(json['energy'])),
        countsTowardTarget: asBool(json['counts_toward_target'], fallback: true),
        moderateEquivalentMinutes: asInt(json['moderate_equivalent_minutes']),
      );
}

/// The three calls the card makes.
abstract class ActivityService {
  /// The named list, with a citation on every row.
  Future<ActivityCatalogue> types();

  /// Today, this week and the lifetime total.
  Future<ActivitySummary> summary();

  /// Record one session. [intensity] is sent only for "Something else"; the
  /// backend refuses it for any other activity, because the intensity of
  /// badminton is the Compendium's and not this app's to state.
  Future<LoggedActivity> log({
    required String activity,
    required int minutes,
    String? intensity,
  });
}

/// The service, or null in a build with no backend address.
final activityServiceProvider = Provider<ActivityService?>((ref) {
  final ApiClient? api = ref.watch(apiClientProvider);
  if (api == null) {
    return null;
  }
  return HttpActivityService(api);
});

/// The named list. Fetched once and kept while the card is on screen.
final activityTypesProvider =
    FutureProvider.autoDispose<ActivityCatalogue?>((ref) async {
  final ActivityService? service = ref.watch(activityServiceProvider);
  if (service == null) {
    return null;
  }
  return service.types();
});

/// Today, this week and the running total.
final activitySummaryProvider =
    FutureProvider.autoDispose<ActivitySummary?>((ref) async {
  final ActivityService? service = ref.watch(activityServiceProvider);
  if (service == null) {
    return null;
  }
  return service.summary();
});

/// The real one, against our own FastAPI service.
class HttpActivityService implements ActivityService {
  const HttpActivityService(this._api);

  final ApiClient _api;

  @override
  Future<ActivityCatalogue> types() async {
    try {
      return ActivityCatalogue.fromJson(
        await _api.getMap('/v1/activity/types'),
      );
    } on ApiFailure catch (failure) {
      throw ActivityException(failure.message);
    }
  }

  @override
  Future<ActivitySummary> summary() async {
    try {
      return ActivitySummary.fromJson(
        await _api.getMap('/v1/activity/summary'),
      );
    } on ApiFailure catch (failure) {
      throw ActivityException(failure.message);
    }
  }

  @override
  Future<LoggedActivity> log({
    required String activity,
    required int minutes,
    String? intensity,
  }) async {
    try {
      return LoggedActivity.fromJson(
        await _api.postMap(
          '/v1/activity/sessions',
          // `prune` drops the intensity when there is none, rather than sending
          // an explicit null: the request model is `extra="forbid"` and refuses
          // an intensity on any activity that has a published one.
          body: prune(<String, dynamic>{
            'activity': activity,
            'minutes': minutes,
            'intensity': intensity,
          }),
        ),
      );
    } on ApiFailure catch (failure) {
      throw ActivityException(failure.message);
    }
  }
}
