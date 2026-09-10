import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/api/api_failure.dart';
import '../../data/models/json.dart';
import '../../data/providers.dart';
import '../../data/repository/health_repository.dart';

/// The week just gone, as the backend counted it.
///
/// Two halves, and keeping them apart is the whole point of the shape.
///
/// **[facts] and [lines] are arithmetic.** Every number in them was computed in
/// Python from rows the backend already holds — plan items marked eaten,
/// meals logged, movement logged — and no model has been near any of it.
///
/// **[summary] is the only sentence a model wrote**, and it went through the
/// same safety pipeline as chat and the plan. It contains no digits at all: the
/// backend refuses one that does, because a number a model restates is a number
/// nobody checked. So the screen never has to reconcile two accounts of the same
/// week.
///
/// [hasEnoughData] false means the week had too little logged in it to say
/// anything encouraging that is also true. There is then no [summary] at all,
/// [lines] says which things were not logged, and **no model was called**. That
/// is deliberate and it is the honest answer: an empty week reported as empty is
/// what makes a full week's sentence worth reading.
class WeeklySummary {
  const WeeklySummary({
    required this.weekStart,
    required this.weekEnd,
    required this.hasEnoughData,
    required this.proseSource,
    this.summary,
    this.lines = const <String>[],
    this.notMeasured = const <String>[],
    this.facts = const WeekFacts(),
    this.generated = false,
  });

  factory WeeklySummary.fromJson(Map<String, dynamic> json) {
    return WeeklySummary(
      weekStart: asDate(json['week_start']) ?? DateTime.now(),
      weekEnd: asDate(json['week_end']) ?? DateTime.now(),
      hasEnoughData: asBool(json['has_enough_data']),
      proseSource: WeeklyProseSource.fromWire(asString(json['prose_source'])),
      summary: asStringOrNull(json['summary']),
      lines: asStringList(json['lines']),
      notMeasured: asStringList(json['not_measured']),
      facts: WeekFacts.fromJson(asMap(json['facts'])),
      generated: asBool(json['generated']),
    );
  }

  /// Monday.
  final DateTime weekStart;

  /// Sunday.
  final DateTime weekEnd;

  final bool hasEnoughData;

  /// Whether the reader is getting the model's sentence, the counts alone, or a
  /// week too quiet to say anything about. Sent by the backend rather than
  /// guessed from a null [summary], so a downgrade is never silent.
  final WeeklyProseSource proseSource;

  final String? summary;

  /// The backend's own sentences about the week. Always present.
  final List<String> lines;

  /// What this summary deliberately does not say, and why. Water is the big one:
  /// glasses are tallied on this phone and nothing sends them to the backend, so
  /// counting them there would be a guess.
  final List<String> notMeasured;

  final WeekFacts facts;

  /// True when a model was called for this response.
  final bool generated;
}

/// Where the prose on screen came from.
enum WeeklyProseSource {
  /// The model wrote it, and it passed the rails and the safety layer.
  model('model'),

  /// The counts alone. The model either wrote something that broke a rail, was
  /// blocked, or was not configured — and the screen says so rather than showing
  /// an unexplained gap.
  computed('computed'),

  /// The week had too little in it. No model was called.
  quiet('quiet');

  const WeeklyProseSource(this.wire);

  final String wire;

  static WeeklyProseSource fromWire(String value) {
    for (final WeeklyProseSource source in WeeklyProseSource.values) {
      if (source.wire == value) {
        return source;
      }
    }
    return WeeklyProseSource.computed;
  }
}

/// The counts. Arithmetic, all of it.
class WeekFacts {
  const WeekFacts({
    this.mealsPlanned = 0,
    this.daysPlanned = 0,
    this.markedEaten = 0,
    this.markedSkipped = 0,
    this.daysWithAMark = 0,
    this.mealsLogged = 0,
    this.daysWithAMealLogged = 0,
    this.movementMinutes = 0,
    this.daysMoved = 0,
    this.movementTargetMinutesPerWeek,
    this.movementTargetSource = '',
    this.reportMeasuredOn,
    this.reportValues = 0,
    this.reportOutsideUsualRange = 0,
  });

  factory WeekFacts.fromJson(Map<String, dynamic> json) {
    return WeekFacts(
      mealsPlanned: asInt(json['meals_planned']),
      daysPlanned: asInt(json['days_planned']),
      markedEaten: asInt(json['marked_eaten']),
      markedSkipped: asInt(json['marked_skipped']),
      daysWithAMark: asInt(json['days_with_a_mark']),
      mealsLogged: asInt(json['meals_logged']),
      daysWithAMealLogged: asInt(json['days_with_a_meal_logged']),
      movementMinutes: asInt(json['movement_minutes']),
      daysMoved: asInt(json['days_moved']),
      movementTargetMinutesPerWeek:
          asIntOrNull(json['movement_target_minutes_per_week']),
      movementTargetSource: asString(json['movement_target_source']),
      reportMeasuredOn: asDate(json['report_measured_on']),
      reportValues: asInt(json['report_values']),
      reportOutsideUsualRange: asInt(json['report_outside_usual_range']),
    );
  }

  final int mealsPlanned;
  final int daysPlanned;

  /// "Marked", not "eaten". What is recorded is the tap, and those are two
  /// different claims — the backend is careful about it and so is this screen.
  final int markedEaten;
  final int markedSkipped;
  final int daysWithAMark;

  final int mealsLogged;
  final int daysWithAMealLogged;

  /// Moderate-equivalent minutes, the unit the WHO weekly target is written in.
  final int movementMinutes;
  final int daysMoved;
  final int? movementTargetMinutesPerWeek;
  final String movementTargetSource;

  final DateTime? reportMeasuredOn;
  final int reportValues;
  final int reportOutsideUsualRange;

  /// True when there is at least one count worth drawing a tile for.
  bool get hasAnything =>
      markedEaten > 0 ||
      markedSkipped > 0 ||
      mealsLogged > 0 ||
      movementMinutes > 0 ||
      mealsPlanned > 0;
}

/// Fetching a week.
///
/// A feature-local service rather than a method on [HealthRepository], for the
/// same reason `features/chat/chat_photo.dart` keeps its own: this is the only
/// screen that calls these two endpoints, and adding to the shared interface
/// would mean editing files this change does not own. If the summary ever needs
/// to be read from Today as well, moving it into the repository is a small
/// change and this is the place it moves from.
abstract class WeeklySummaryService {
  /// `GET /v1/summary/weekly`. Generates the sentence the first time a week is
  /// opened and serves the stored one afterwards, so this is usually a read.
  Future<WeeklySummary> load({DateTime? weekStart});

  /// `POST /v1/summary/weekly/refresh`. Always calls a model — and only when the
  /// week has enough in it to be worth one.
  Future<WeeklySummary> refresh({DateTime? weekStart});
}

/// The service, or null in a build with no backend address.
///
/// Null rather than a stub that throws, so the screen can say the honest thing
/// instead of spinning against a server it does not have.
final weeklySummaryServiceProvider = Provider<WeeklySummaryService?>((ref) {
  final ApiClient? api = ref.watch(apiClientProvider);
  if (api == null) {
    return null;
  }
  return HttpWeeklySummaryService(api);
});

/// The real one, against our own FastAPI service.
class HttpWeeklySummaryService implements WeeklySummaryService {
  HttpWeeklySummaryService(this._api);

  final ApiClient _api;

  @override
  Future<WeeklySummary> load({DateTime? weekStart}) async {
    // `generates: true`: the first look at a week may write its sentence, and
    // that is a model call rather than a row read. Asking for the reading-a-row
    // timeout here is how a first open times out on a cold free-tier instance.
    return _fetch(() => _api.getMap(
          '/v1/summary/weekly',
          query: _query(weekStart),
          generates: true,
        ));
  }

  @override
  Future<WeeklySummary> refresh({DateTime? weekStart}) async {
    return _fetch(() => _api.postMap(
          '/v1/summary/weekly/refresh',
          query: _query(weekStart),
        ));
  }

  Future<WeeklySummary> _fetch(
    Future<Map<String, dynamic>> Function() call,
  ) async {
    try {
      return WeeklySummary.fromJson(await call());
    } on ApiFailure catch (failure) {
      // Rethrown as the exception `explainFailure` knows how to turn into a
      // sentence, so this screen shows the same words for an expired sign-in or
      // a sleeping backend as every other screen does.
      throw HealthRepositoryException(failure.message);
    }
  }

  static Map<String, String>? _query(DateTime? weekStart) {
    if (weekStart == null) {
      return null;
    }
    final String iso = weekStart.toIso8601String().split('T').first;
    return <String, String>{'week_start': iso};
  }
}
