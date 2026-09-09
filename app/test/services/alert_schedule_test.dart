import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/services/alert_schedule.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// The arithmetic behind every reminder.
///
/// None of this touches a platform channel, which is the point: the part that
/// decides *when* a notification fires is the part most likely to be wrong, and
/// it is the part a widget test can never reach. A reminder at the wrong hour is
/// not a cosmetic bug in a health app.
void main() {
  AlertDefinition alert(
    String type,
    String at, {
    bool enabled = true,
    bool suppressed = false,
  }) {
    return AlertDefinition(
      alertType: type,
      title: 'Title',
      body: 'Body',
      at: at,
      enabled: enabled,
      suppressedByQuietHours: suppressed,
    );
  }

  group('reading a time of day', () {
    test('HH:mm and HH:MM:SS both parse; nonsense does not', () {
      expect(minutesOfDay('08:30'), 510);
      expect(minutesOfDay('08:30:00'), 510);
      expect(minutesOfDay('00:00'), 0);
      expect(minutesOfDay('23:59'), 1439);
      expect(minutesOfDay('24:00'), isNull);
      expect(minutesOfDay('08:60'), isNull);
      expect(minutesOfDay('breakfast'), isNull);
      expect(minutesOfDay(''), isNull);
    });

    test('normalising pads and drops the seconds', () {
      expect(normaliseTimeOfDay('8:5'), '08:05');
      expect(normaliseTimeOfDay('22:45:00'), '22:45');
      expect(normaliseTimeOfDay('nope'), isNull);
      expect(normaliseTimeOfDay(null), isNull);
    });
  });

  group('quiet hours', () {
    const QuietHours overnight = QuietHours(start: '22:30', end: '06:00');
    const QuietHours daytime = QuietHours(start: '13:00', end: '15:00');

    test('a window that crosses midnight is the normal case', () {
      expect(overnight.covers('23:30'), isTrue);
      expect(overnight.covers('02:00'), isTrue);
      expect(overnight.covers('05:59'), isTrue);
      expect(overnight.covers('06:00'), isFalse, reason: 'the end is exclusive');
      expect(overnight.covers('22:30'), isTrue, reason: 'the start is inclusive');
      expect(overnight.covers('22:29'), isFalse);
      expect(overnight.covers('12:00'), isFalse);
    });

    test('a window inside one day works the same way', () {
      expect(daytime.covers('13:00'), isTrue);
      expect(daytime.covers('14:59'), isTrue);
      expect(daytime.covers('15:00'), isFalse);
      expect(daytime.covers('12:59'), isFalse);
    });

    test('no window set means nothing is covered', () {
      expect(const QuietHours().covers('03:00'), isFalse);
      expect(const QuietHours(start: '22:00').covers('23:00'), isFalse);
    });
  });

  group('what actually gets an alarm', () {
    test('quiet hours silence an ordinary reminder', () {
      const AlertPlan plan = AlertPlan(
        alerts: <AlertDefinition>[
          AlertDefinition(
              alertType: 'hydration', title: 'Water', body: 'x', at: '23:30'),
          AlertDefinition(
              alertType: 'meal', title: 'Breakfast', body: 'x', at: '08:20'),
        ],
        quietHours: QuietHours(start: '22:30', end: '06:00'),
      );
      expect(
        plan.schedulable.map((AlertDefinition a) => a.at),
        <String>['08:20'],
      );
    });

    test('quiet hours never silence an escalation', () {
      const AlertPlan plan = AlertPlan(
        alerts: <AlertDefinition>[
          AlertDefinition(
            alertType: 'escalation',
            title: 'Please speak to a doctor today',
            body: 'x',
            at: '23:45',
            // Even if a stale payload claimed otherwise, and even switched off.
            enabled: false,
            suppressedByQuietHours: true,
          ),
        ],
        quietHours: QuietHours(start: '22:30', end: '06:00'),
      );
      expect(plan.schedulable, hasLength(1));
      expect(plan.schedulable.single.alwaysOn, isTrue);
    });

    test('the server\'s own suppression flag is honoured too', () {
      final AlertPlan plan = AlertPlan(
        alerts: <AlertDefinition>[alert('sleep', '10:00', suppressed: true)],
      );
      expect(plan.schedulable, isEmpty);
    });

    test('a switched-off type is dropped', () {
      final AlertPlan plan = AlertPlan(
        alerts: <AlertDefinition>[alert('grocery', '10:00', enabled: false)],
      );
      expect(plan.schedulable, isEmpty);
    });

    test('an unreadable time is dropped rather than guessed at', () {
      final AlertPlan plan =
          AlertPlan(alerts: <AlertDefinition>[alert('meal', 'lunchtime')]);
      expect(plan.schedulable, isEmpty);
    });

    test('they come out in the order of the day', () {
      final AlertPlan plan = AlertPlan(
        alerts: <AlertDefinition>[
          alert('sleep', '21:45'),
          alert('meal', '08:20'),
          alert('hydration', '11:00'),
        ],
      );
      expect(
        plan.schedulable.map((AlertDefinition a) => a.at),
        <String>['08:20', '11:00', '21:45'],
      );
    });

    test('ids are stable for the same alert and different across times', () {
      expect(alert('meal', '08:20').notificationId,
          alert('meal', '08:20').notificationId);
      expect(alert('meal', '08:20').notificationId,
          isNot(alert('meal', '08:30').notificationId));
      expect(alert('meal', '08:20').notificationId,
          isNot(alert('hydration', '08:20').notificationId));
      // Android notification ids are 32-bit signed.
      expect(alert('meal', '08:20').notificationId, greaterThanOrEqualTo(0));
      expect(alert('meal', '08:20').notificationId, lessThan(0x40000000));
    });
  });

  group('rescheduling only when something changed', () {
    test('the same definitions fingerprint the same', () {
      final AlertPlan a = AlertPlan(
        alerts: <AlertDefinition>[alert('meal', '08:20'), alert('sleep', '21:45')],
      );
      final AlertPlan b = AlertPlan(
        alerts: <AlertDefinition>[alert('sleep', '21:45'), alert('meal', '08:20')],
      );
      expect(a.fingerprint, b.fingerprint);
    });

    test('a moved time is a different fingerprint', () {
      final AlertPlan a = AlertPlan(alerts: <AlertDefinition>[alert('meal', '08:20')]);
      final AlertPlan b = AlertPlan(alerts: <AlertDefinition>[alert('meal', '08:30')]);
      expect(a.fingerprint, isNot(b.fingerprint));
    });

    test('a changed quiet-hours window changes it, because the set changes', () {
      final AlertPlan a = AlertPlan(alerts: <AlertDefinition>[alert('meal', '23:00')]);
      final AlertPlan b = AlertPlan(
        alerts: <AlertDefinition>[alert('meal', '23:00')],
        quietHours: const QuietHours(start: '22:30', end: '06:00'),
      );
      expect(a.fingerprint, isNot(b.fingerprint));
    });
  });

  group('the next occurrence', () {
    test('later today when the time has not passed', () {
      final DateTime next =
          nextDailyOccurrence(DateTime(2026, 9, 9, 7, 0), '08:20');
      expect(next, DateTime(2026, 9, 9, 8, 20));
    });

    test('tomorrow when it has', () {
      final DateTime next =
          nextDailyOccurrence(DateTime(2026, 9, 9, 9, 0), '08:20');
      expect(next, DateTime(2026, 9, 10, 8, 20));
    });

    test('tomorrow when it is exactly now, never this instant', () {
      final DateTime next =
          nextDailyOccurrence(DateTime(2026, 9, 9, 8, 20), '08:20');
      expect(next, DateTime(2026, 9, 10, 8, 20));
    });

    test('rolls over a month end', () {
      final DateTime next =
          nextDailyOccurrence(DateTime(2026, 9, 30, 23, 0), '06:30');
      expect(next, DateTime(2026, 10, 1, 6, 30));
    });
  });

  group('daylight saving', () {
    setUpAll(tz_data.initializeTimeZones);

    tz.Location london() => tz.getLocation('Europe/London');

    List<ScheduledAlarm> alarmsIn(
      tz.Location location,
      AlertPlan plan,
      tz.TZDateTime now,
    ) {
      return alarmsFor(
        plan,
        now: now,
        build: (int y, int m, int d, int h, int min) =>
            tz.TZDateTime(location, y, m, d, h, min),
      );
    }

    test('a 07:00 reminder is still at 07:00 the morning the clocks go forward',
        () {
      final tz.Location loc = london();
      // 28 March 2027 is the spring-forward Sunday: 01:00 GMT becomes 02:00 BST.
      final tz.TZDateTime saturdayEvening =
          tz.TZDateTime(loc, 2027, 3, 27, 20, 0);
      final List<ScheduledAlarm> alarms = alarmsIn(
        loc,
        AlertPlan(alerts: <AlertDefinition>[alert('meal', '07:00')]),
        saturdayEvening,
      );

      expect(alarms, hasLength(1));
      final DateTime at = alarms.single.at;
      expect(at.year, 2027);
      expect(at.month, 3);
      expect(at.day, 28);
      expect(at.hour, 7, reason: 'wall clock, not elapsed hours');
      expect(at.minute, 0);
      // Proof it really is the day after the change: British Summer Time.
      expect(at.timeZoneOffset, const Duration(hours: 1));
    });

    test('a wall-clock time that does not exist that morning still fires later, '
        'never in the past', () {
      final tz.Location loc = london();
      // 01:30 simply does not happen on 28 March 2027.
      final tz.TZDateTime justBefore = tz.TZDateTime(loc, 2027, 3, 28, 0, 30);
      final List<ScheduledAlarm> alarms = alarmsIn(
        loc,
        AlertPlan(alerts: <AlertDefinition>[alert('hydration', '01:30')]),
        justBefore,
      );

      expect(alarms, hasLength(1));
      expect(alarms.single.at.isAfter(justBefore), isTrue);
    });

    test('an autumn repeated hour does not schedule into the past', () {
      final tz.Location loc = london();
      // 31 October 2027: 02:00 BST becomes 01:00 GMT, so 01:30 happens twice.
      final tz.TZDateTime evening = tz.TZDateTime(loc, 2027, 10, 30, 22, 0);
      final List<ScheduledAlarm> alarms = alarmsIn(
        loc,
        AlertPlan(alerts: <AlertDefinition>[alert('hydration', '01:30')]),
        evening,
      );
      expect(alarms, hasLength(1));
      expect(alarms.single.at.isAfter(evening), isTrue);
      expect(alarms.single.at.hour, 1);
      expect(alarms.single.at.minute, 30);
    });

    test('a zone with no daylight saving is unaffected', () {
      final tz.Location loc = tz.getLocation('Asia/Kolkata');
      final tz.TZDateTime now = tz.TZDateTime(loc, 2026, 9, 9, 7, 0);
      final List<ScheduledAlarm> alarms = alarmsIn(
        loc,
        AlertPlan(alerts: <AlertDefinition>[alert('meal', '08:20')]),
        now,
      );
      expect(alarms.single.at.hour, 8);
      expect(alarms.single.at.minute, 20);
      expect(alarms.single.at.day, 9);
    });
  });

  group('alarms', () {
    test('are ordered by when they fire and carry their alert', () {
      final DateTime now = DateTime(2026, 9, 9, 7, 0);
      final List<ScheduledAlarm> alarms = alarmsFor(
        AlertPlan(
          alerts: <AlertDefinition>[
            alert('sleep', '21:45'),
            alert('meal', '08:20'),
            alert('grocery', '06:00'),
          ],
        ),
        now: now,
      );
      expect(alarms, hasLength(3));
      expect(alarms.first.alert.alertType, 'meal');
      expect(alarms.last.alert.alertType, 'grocery',
          reason: '06:00 has passed, so it is tomorrow');
      expect(alarms.last.at, DateTime(2026, 9, 10, 6, 0));
      expect(alarms.first.id, alarms.first.alert.notificationId);
    });
  });

  group('reading /v1/alerts', () {
    test('parses the payload the API actually returns', () {
      final AlertPlan plan = AlertPlan.fromJson(<String, dynamic>{
        'alerts': <Object>[
          <String, dynamic>{
            'id': 'a1',
            'alert_type': 'meal',
            'title': 'Breakfast time',
            'body': 'Today’s breakfast is ready in your plan.',
            'at': '08:20',
            'enabled': true,
            'suppressed_by_quiet_hours': false,
          },
          <String, dynamic>{
            'id': 'a2',
            'alert_type': 'hydration',
            'title': 'Water',
            'body': 'Time for a glass of water.',
            'at': '23:30',
            'enabled': true,
            'suppressed_by_quiet_hours': true,
          },
        ],
        'quiet_hours': <String, dynamic>{'start': '22:30', 'end': '06:00'},
      });

      expect(plan.alerts, hasLength(2));
      expect(plan.quietHours.start, '22:30');
      expect(plan.schedulable, hasLength(1));
      expect(plan.schedulable.single.id, 'a1');
      // The words come from the server and are not touched here.
      expect(plan.schedulable.single.body,
          'Today’s breakfast is ready in your plan.');
    });

    test('an empty payload is an empty plan, not a crash', () {
      expect(AlertPlan.fromJson(const <String, dynamic>{}).alerts, isEmpty);
      expect(AlertPlan.fromJson(const <String, dynamic>{}).schedulable, isEmpty);
    });
  });
}
