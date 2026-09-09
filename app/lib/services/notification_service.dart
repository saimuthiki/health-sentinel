import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../data/cache/cache_freshness.dart';
import '../data/cache/offline_cache.dart';
import 'alert_schedule.dart';

/// Every reminder in this product, scheduled by the phone itself.
///
/// This is the one part of the app that has to keep working when nothing else
/// does. The backend sleeps on a free tier, the flat has no signal, the app has
/// been closed since yesterday — and the eight o'clock reminder still has to
/// arrive at eight o'clock. That is only true if the alarm was handed to
/// Android's `AlarmManager` while the app was last open, which is exactly what
/// this class does and the entire reason there is no push service in the
/// architecture (docs/07-open-decisions.md, D3).
///
/// The server decides *what* and *when* — `/v1/alerts` returns the definitions,
/// with quiet hours already applied — and the device decides nothing except
/// which calendar day each one lands on next. Alert copy is never composed here:
/// a notification is one more surface where a model must not be able to put
/// words in front of somebody, and the strings arrive already written and
/// already checked.
class NotificationService {
  NotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    required OfflineCache cache,
  })  : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
        _cache = cache;

  final FlutterLocalNotificationsPlugin _plugin;
  final OfflineCache _cache;

  bool _initialised = false;
  bool _permissionRequested = false;

  /// Ordinary reminders: meals, water, a walk, winding down.
  static const String reminderChannelId = 'healthpulse_reminders';
  static const String reminderChannelName = 'Daily reminders';

  /// Findings that need a doctor. A separate channel so a person can quieten
  /// the reminders without quietening these, and so Android gives them weight.
  static const String escalationChannelId = 'healthpulse_escalations';
  static const String escalationChannelName = 'Findings that need a doctor';

  /// Called once, early, from the app's bootstrap.
  ///
  /// Deliberately asks for **no permission**. A permission dialog on first
  /// launch, before the person has a plan or any reason to want a reminder, is
  /// how an app trains someone to press "don't allow" — see [requestPermission].
  Future<void> initialise() async {
    if (_initialised) {
      return;
    }
    tz_data.initializeTimeZones();
    try {
      final String name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // An unknown zone name is better handled as UTC than as a crash on
      // launch. Times will be wrong until the next start, but the app opens.
      tz.setLocalLocation(tz.UTC);
    }

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );

    final AndroidFlutterLocalNotificationsPlugin? android = _android;
    if (android != null) {
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          reminderChannelId,
          reminderChannelName,
          description:
              'Meals, water, movement and winding down, at the times you set.',
          importance: Importance.defaultImportance,
        ),
      );
      await android.createNotificationChannel(
        const AndroidNotificationChannel(
          escalationChannelId,
          escalationChannelName,
          description:
              'The rare reminder about a result that a doctor should see.',
          importance: Importance.max,
        ),
      );
    }
    _initialised = true;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android {
    try {
      return _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasPermission() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _android;
    if (android == null) {
      return false;
    }
    try {
      return await android.areNotificationsEnabled() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ask for notifications, and for the right to fire them at an exact minute.
  ///
  /// Called from [applyPlan] the first time there is actually something to
  /// remind somebody about, which is the moment the request makes sense: the
  /// person has a plan in front of them with times on it, so "may we tell you
  /// when?" is a question with an obvious answer rather than an interruption.
  ///
  /// Exact alarms are asked for separately because Android treats them as a
  /// second, heavier permission. Without them the reminders still arrive, just
  /// batched by the system — so a refusal degrades the product rather than
  /// breaking it, and [applyPlan] falls back on its own.
  Future<bool> requestPermission() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _android;
    if (android == null) {
      return false;
    }
    _permissionRequested = true;
    bool granted = false;
    try {
      granted = await android.requestNotificationsPermission() ?? false;
    } catch (_) {
      granted = false;
    }
    if (granted) {
      try {
        await android.requestExactAlarmsPermission();
      } catch (_) {
        // Refused, or not applicable on this Android version. Inexact alarms
        // are the fallback and applyPlan chooses between them.
      }
    }
    return granted;
  }

  /// Cancel everything pending and lay the plan down again.
  ///
  /// Rescheduling is destructive, so it only happens when something actually
  /// changed. [AlertPlan.fingerprint] is what "changed" means: the times, the
  /// types and the words. Re-applying an identical plan on every app open would
  /// cancel a reminder due in ninety seconds and set it again — usually fine,
  /// occasionally the reason somebody's water reminder went missing.
  ///
  /// Returns the number of alarms now set.
  Future<int> applyPlan(AlertPlan plan, {bool force = false}) async {
    await initialise();

    final List<ScheduledAlarm> alarms = alarmsFor(
      plan,
      now: tz.TZDateTime.now(tz.local),
      build: (int y, int m, int d, int h, int min) =>
          tz.TZDateTime(tz.local, y, m, d, h, min),
    );

    if (alarms.isEmpty) {
      await cancelAll();
      await _cache.remove(OfflineCache.scheduledAlertsFingerprint);
      return 0;
    }

    if (!await hasPermission()) {
      if (_permissionRequested) {
        // Asked once, refused. Asking again on every plan is nagging, and the
        // system will not show the dialog a second time anyway.
        return 0;
      }
      if (!await requestPermission()) {
        return 0;
      }
    }

    final String fingerprint = plan.fingerprint;
    if (!force) {
      final Cached<Map<String, dynamic>>? stored =
          await _cache.read(OfflineCache.scheduledAlertsFingerprint);
      if (stored != null && stored.value['fingerprint'] == fingerprint) {
        return alarms.length;
      }
    }

    await cancelAll();

    final bool exact = await _canBeExact();
    int scheduled = 0;
    for (final ScheduledAlarm alarm in alarms) {
      if (await _schedule(alarm, exact: exact)) {
        scheduled += 1;
      }
    }

    await _cache.write(
      OfflineCache.scheduledAlertsFingerprint,
      <String, dynamic>{'fingerprint': fingerprint, 'count': scheduled},
    );
    return scheduled;
  }

  Future<bool> _canBeExact() async {
    final AndroidFlutterLocalNotificationsPlugin? android = _android;
    if (android == null) {
      return false;
    }
    try {
      return await android.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _schedule(ScheduledAlarm alarm, {required bool exact}) async {
    final tz.TZDateTime when = alarm.at is tz.TZDateTime
        ? alarm.at as tz.TZDateTime
        : tz.TZDateTime.from(alarm.at, tz.local);
    try {
      await _plugin.zonedSchedule(
        alarm.id,
        alarm.alert.title,
        alarm.alert.body,
        when,
        _detailsFor(alarm.alert),
        // iOS 9 and older only; the app is Android-first and this is the
        // wall-clock reading, which is what a daily reminder means.
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.wallClockTime,
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        // Daily, at the same wall-clock time. The platform recomputes the next
        // one in the device's zone rather than adding twenty-four hours, which
        // is what keeps it at eight o'clock across a clock change.
        matchDateTimeComponents: DateTimeComponents.time,
        payload: alarm.alert.alertType,
      );
      return true;
    } catch (_) {
      // Usually the exact-alarm permission being refused between the check and
      // the call. One reminder that arrives a few minutes late is far better
      // than an exception that loses the rest of the day's reminders.
      if (exact) {
        return _schedule(alarm, exact: false);
      }
      return false;
    }
  }

  NotificationDetails _detailsFor(AlertDefinition alert) {
    final bool urgent = alert.alwaysOn;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        urgent ? escalationChannelId : reminderChannelId,
        urgent ? escalationChannelName : reminderChannelName,
        channelDescription: urgent
            ? 'The rare reminder about a result that a doctor should see.'
            : 'Meals, water, movement and winding down, at the times you set.',
        importance: urgent ? Importance.max : Importance.defaultImportance,
        priority: urgent ? Priority.high : Priority.defaultPriority,
      ),
    );
  }

  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {
      // Nothing scheduled, or no platform under us. Either way there is nothing
      // to tell anyone.
    }
  }

  /// Sign-out, and "delete all my health data".
  ///
  /// Reminders carry the user's own meal times in their bodies, so leaving them
  /// scheduled after a sign-out would keep telling a stranger holding the phone
  /// when the last person ate.
  Future<void> forgetEverything() async {
    await cancelAll();
    await _cache.remove(OfflineCache.scheduledAlertsFingerprint);
    _permissionRequested = false;
  }
}
