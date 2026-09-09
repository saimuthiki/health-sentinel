/// The arithmetic behind every reminder, with no plugin, no platform channel and
/// no clock of its own.
///
/// It lives apart from [NotificationService] so that the part that is easy to
/// get wrong — quiet hours across midnight, the next occurrence of a daily time,
/// what happens on the morning a country puts its clocks forward — can be tested
/// as ordinary Dart. A notification that fires at the wrong hour is not a
/// cosmetic bug in a health app: it is the difference between a reminder to eat
/// before a lab test and a reminder after it.
library;

/// Minutes since midnight for a 24-hour `HH:mm`, or null if it is not one.
///
/// The backend sends `HH:MM`; a stored value may carry seconds (`08:30:00`).
/// Both are accepted, anything else is refused rather than guessed at.
int? minutesOfDay(String hhmm) {
  final List<String> parts = hhmm.trim().split(':');
  if (parts.length < 2) {
    return null;
  }
  final int? hour = int.tryParse(parts[0]);
  final int? minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) {
    return null;
  }
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return null;
  }
  return hour * 60 + minute;
}

/// `08:30:00` and `8:30` both become `08:30`.
String? normaliseTimeOfDay(String? raw) {
  if (raw == null) {
    return null;
  }
  final int? minutes = minutesOfDay(raw);
  if (minutes == null) {
    return null;
  }
  final String h = (minutes ~/ 60).toString().padLeft(2, '0');
  final String m = (minutes % 60).toString().padLeft(2, '0');
  return '$h:$m';
}

/// The window in which the phone stays quiet.
///
/// The rule is deliberately the same one `app/planner/alerts.py` uses, including
/// the half-open comparison, so that a device and the server never disagree
/// about whether 22:00 is inside `22:00`–`07:00`. The backend already sends
/// `suppressed_by_quiet_hours` per alert; this recomputes it rather than only
/// trusting the flag, because the flag was computed when the alerts were fetched
/// and the user may have changed the window since, offline.
class QuietHours {
  const QuietHours({this.start, this.end});

  /// `HH:mm`, or null when the user has set no quiet hours.
  final String? start;
  final String? end;

  bool get isSet => start != null && end != null;

  factory QuietHours.fromJson(Map<String, dynamic> json) => QuietHours(
        start: normaliseTimeOfDay(
          json['start'] is String ? json['start'] as String : null,
        ),
        end: normaliseTimeOfDay(
          json['end'] is String ? json['end'] as String : null,
        ),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (start != null) 'start': start,
        if (end != null) 'end': end,
      };

  /// True when [hhmm] falls inside the window. A window that crosses midnight
  /// (22:00 to 07:00) is the normal case, not the edge case.
  bool covers(String hhmm) {
    final int? at = minutesOfDay(hhmm);
    final int? from = start == null ? null : minutesOfDay(start!);
    final int? to = end == null ? null : minutesOfDay(end!);
    if (at == null || from == null || to == null) {
      return false;
    }
    if (from <= to) {
      return from <= at && at < to;
    }
    return at >= from || at < to;
  }
}

/// One reminder the phone should schedule for itself, exactly as `/v1/alerts`
/// describes it.
///
/// Nothing here is composed on the device. The title and the body are strings
/// the backend built from the user's own profile and from constants, and they
/// are shown verbatim — an alert is one more place a model must never be able
/// to put words in front of somebody, and the server is where that is enforced.
class AlertDefinition {
  const AlertDefinition({
    required this.alertType,
    required this.title,
    required this.body,
    required this.at,
    this.id,
    this.enabled = true,
    this.suppressedByQuietHours = false,
  });

  /// `hydration`, `meal`, `grocery`, `activity`, `sleep`, `nutrition`,
  /// `report_followup`, `weekly_summary`, `escalation`.
  final String alertType;

  final String? id;
  final String title;
  final String body;

  /// Local time of day, `HH:mm`.
  final String at;

  final bool enabled;

  /// What the backend worked out about quiet hours when it answered.
  final bool suppressedByQuietHours;

  /// An escalation is not a preference. `app/api/alerts.py` refuses to switch
  /// this type off and never marks it suppressed; the device honours the same
  /// rule so that a quiet-hours window set at midnight cannot silence a red flag.
  bool get alwaysOn => alertType == escalationType;

  static const String escalationType = 'escalation';

  /// A stable, collision-resistant id for the Android notification, derived from
  /// what the alert *is* rather than from a row id — so the same reminder keeps
  /// the same slot across sign-ins, and a changed time is a different slot that
  /// the reschedule pass replaces cleanly.
  int get notificationId => _fnv1a('$alertType@$at');

  factory AlertDefinition.fromJson(Map<String, dynamic> json) {
    return AlertDefinition(
      alertType: json['alert_type'] is String
          ? json['alert_type'] as String
          : 'nutrition',
      id: json['id'] is String ? json['id'] as String : null,
      title: json['title'] is String ? json['title'] as String : '',
      body: json['body'] is String ? json['body'] as String : '',
      at: normaliseTimeOfDay(
            json['at'] is String ? json['at'] as String : null,
          ) ??
          '',
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      suppressedByQuietHours: json['suppressed_by_quiet_hours'] is bool
          ? json['suppressed_by_quiet_hours'] as bool
          : false,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'alert_type': alertType,
        if (id != null) 'id': id,
        'title': title,
        'body': body,
        'at': at,
        'enabled': enabled,
        'suppressed_by_quiet_hours': suppressedByQuietHours,
      };
}

/// Everything `/v1/alerts` returned, and the decision about what to schedule.
class AlertPlan {
  const AlertPlan({
    this.alerts = const <AlertDefinition>[],
    this.quietHours = const QuietHours(),
  });

  final List<AlertDefinition> alerts;
  final QuietHours quietHours;

  static const AlertPlan empty = AlertPlan();

  /// The alerts that actually get an alarm.
  ///
  /// Dropped: anything switched off, anything without a readable time, and
  /// anything inside quiet hours — unless it is an escalation, which is never
  /// silenced by either rule.
  List<AlertDefinition> get schedulable {
    final List<AlertDefinition> out = <AlertDefinition>[];
    for (final AlertDefinition alert in alerts) {
      if (minutesOfDay(alert.at) == null) {
        continue;
      }
      if (alert.alwaysOn) {
        out.add(alert);
        continue;
      }
      if (!alert.enabled) {
        continue;
      }
      if (alert.suppressedByQuietHours || quietHours.covers(alert.at)) {
        continue;
      }
      out.add(alert);
    }
    out.sort((AlertDefinition a, AlertDefinition b) =>
        minutesOfDay(a.at)!.compareTo(minutesOfDay(b.at)!));
    return out;
  }

  /// Changes when, and only when, something that affects an alarm changes.
  ///
  /// Rescheduling is destructive — every pending alarm is cancelled first — so
  /// doing it on every app open would drop a reminder for anyone who opens the
  /// app a minute before one is due. This is how the service knows to leave
  /// well alone.
  String get fingerprint {
    final StringBuffer buffer = StringBuffer();
    for (final AlertDefinition alert in schedulable) {
      buffer
        ..write(alert.alertType)
        ..write('|')
        ..write(alert.at)
        ..write('|')
        ..write(alert.title)
        ..write('|')
        ..write(alert.body)
        ..write('\n');
    }
    return _fnv1a(buffer.toString()).toRadixString(16);
  }

  factory AlertPlan.fromJson(Map<String, dynamic> json) {
    final Object? rawAlerts = json['alerts'];
    final List<AlertDefinition> alerts = <AlertDefinition>[];
    if (rawAlerts is List) {
      for (final Object? entry in rawAlerts) {
        if (entry is Map) {
          alerts.add(AlertDefinition.fromJson(entry.cast<String, dynamic>()));
        }
      }
    }
    final Object? rawQuiet = json['quiet_hours'];
    return AlertPlan(
      alerts: alerts,
      quietHours: rawQuiet is Map
          ? QuietHours.fromJson(rawQuiet.cast<String, dynamic>())
          : const QuietHours(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'alerts': alerts.map((AlertDefinition a) => a.toJson()).toList(),
        'quiet_hours': quietHours.toJson(),
      };
}

/// The next wall-clock moment at which [hhmm] happens, strictly after [now].
///
/// Wall clock, not elapsed time, is the whole point. A reminder set for eight in
/// the morning is set for whatever the phone calls eight in the morning, on both
/// sides of a daylight-saving change — so this returns the *date* to hang the
/// time on and leaves the conversion to the time zone, which is the only thing
/// that knows whether that day has 23, 24 or 25 hours in it.
///
/// "Strictly after" matters: an alarm asked for at exactly the current minute
/// either fires immediately or is discarded, and both look like a bug.
///
/// [build] makes the local date-time. The app passes a time-zone-aware
/// constructor; a caller with nothing to prove passes nothing and gets a plain
/// [DateTime] with the same arithmetic.
DateTime nextDailyOccurrence(
  DateTime now,
  String hhmm, {
  LocalDateTimeBuilder? build,
}) {
  final int? minutes = minutesOfDay(hhmm);
  if (minutes == null) {
    throw ArgumentError.value(hhmm, 'hhmm', 'not a 24-hour time of day');
  }
  final LocalDateTimeBuilder make = build ?? DateTime.new;
  final int hour = minutes ~/ 60;
  final int minute = minutes % 60;

  DateTime at = make(now.year, now.month, now.day, hour, minute);
  // Usually one step. More than one only when the time zone moved the wall
  // clock out from under us, which is what the spring-forward morning does.
  int forward = 0;
  while (!at.isAfter(now) && forward < 3) {
    forward += 1;
    at = make(now.year, now.month, now.day + forward, hour, minute);
  }
  return at;
}

/// FNV-1a, masked into the positive half of a 32-bit int so it is a valid
/// Android notification id on every device.
int _fnv1a(String value) {
  int hash = 0x811c9dc5;
  for (final int unit in value.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x3fffffff;
}

/// One reminder pinned to an actual moment.
class ScheduledAlarm {
  const ScheduledAlarm({required this.alert, required this.at});

  final AlertDefinition alert;

  /// The first firing. Everything after it repeats daily at the same wall-clock
  /// time, which the platform recomputes rather than adding 24 hours to this.
  final DateTime at;

  int get id => alert.notificationId;
}

/// Builds a local date-time. The app passes a time-zone-aware constructor; a
/// test passes `DateTime.new` and gets the same arithmetic without a database.
typedef LocalDateTimeBuilder = DateTime Function(
  int year,
  int month,
  int day,
  int hour,
  int minute,
);

/// Turn a plan into the alarms to set, in the order they will fire.
///
/// The build function is what keeps this honest across a daylight-saving change.
/// The alarm is described as "07:00 on this date", never as "eight hours from
/// now", and the time zone decides what that means — so on the morning a country
/// puts its clocks forward, a seven o'clock reminder is still at seven o'clock
/// and not at six. [nextDailyOccurrence] does that step; what is left here is
/// filtering, ordering, and refusing to set an alarm that is already in the
/// past because the device's clock is wrong.
List<ScheduledAlarm> alarmsFor(
  AlertPlan plan, {
  required DateTime now,
  LocalDateTimeBuilder? build,
}) {
  final List<ScheduledAlarm> alarms = <ScheduledAlarm>[];
  for (final AlertDefinition alert in plan.schedulable) {
    final DateTime at = nextDailyOccurrence(now, alert.at, build: build);
    if (!at.isAfter(now)) {
      // Days of trying and still in the past means something is wrong with the
      // clock, not with the alert. Skipping is safer than firing immediately.
      continue;
    }
    alarms.add(ScheduledAlarm(alert: alert, at: at));
  }
  alarms.sort((ScheduledAlarm a, ScheduledAlarm b) => a.at.compareTo(b.at));
  return alarms;
}
