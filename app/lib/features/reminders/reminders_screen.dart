import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format/hp_format.dart';
import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/providers.dart';
import '../../services/alert_schedule.dart';
import '../../services/notification_service.dart';
import '../common/failure_copy.dart';

/// Which reminders you get, and when the phone stays quiet.
///
/// Three things are worth knowing before reading the code, because each of them
/// is a decision rather than an accident.
///
/// **The server owns the answer.** A switch here never moves on its own. It is
/// drawn from the plan the backend last sent, the tap sends a request, and the
/// switch only changes when the reply comes back saying it changed. That is
/// slower by a round trip than flicking it optimistically, and it is the only
/// version that cannot end up showing "off" for a reminder that still fires.
/// While the request is in flight a small spinner sits beside the switch, so
/// the wait is visible rather than mysterious.
///
/// **Quiet hours are two times, and nothing more.** Whether a particular
/// reminder falls inside them is worked out in `backend/app/api/alerts.py` and
/// sent back per alert. This screen shows that answer; it does not compute a
/// second one. Two places deciding what "inside quiet hours" means is how a
/// phone and a server come to disagree about ten o'clock at night.
///
/// **One kind of alert has no switch.** An escalation is the reminder that says
/// a result needs a doctor. The backend refuses to switch it off, and so does
/// this screen — but it says why, in words, rather than showing a control that
/// does not work. That rule is in CLAUDE.md: an undismissable finding is not a
/// preference.
///
/// **The words under each row are the server's own.** A reminder's body is
/// built in `backend/app/planner/alerts.py` from the user's profile and from
/// curated constants — including the water goal actually in force, which may
/// be one the person set for themselves. Showing it here is the only way to
/// see, without waiting for a notification, what a reminder will actually say.
/// It is rendered verbatim: nothing on this screen writes a sentence about
/// somebody's health.
class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  /// What the backend last told us. Null until the first fetch answers.
  AlertPlan? _plan;

  bool _loading = true;

  /// Why the list could not be fetched at all. Shown instead of the list.
  String? _loadFailure;

  /// Why the last change did not happen. Shown above the list, which stays
  /// usable — a refused toggle is not a reason to take the screen away.
  String? _writeFailure;

  /// The alert types with a request in flight, so a second tap on the same row
  /// does nothing and two rows can still be changed one after the other.
  final Set<String> _busyTypes = <String>{};

  bool _savingQuietHours = false;

  /// The times in the two pickers, as 24-hour `HH:mm`.
  ///
  /// Held apart from [_plan] because they are an edit in progress: somebody who
  /// has chosen a start time and not yet a finish has changed nothing at all
  /// until they press save, and the screen should not pretend otherwise.
  String _quietStart = _defaultQuietStart;
  String _quietEnd = _defaultQuietEnd;

  /// A window offered before anyone has set one. Ten at night to six in the
  /// morning is the ordinary shape of a night, and it is only a proposal — the
  /// backend holds no quiet hours until save is pressed.
  static const String _defaultQuietStart = '22:00';
  static const String _defaultQuietEnd = '06:00';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Fetch the plan. Called on arrival and by "Try again".
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailure = null;
    });

    AlertPlan? plan;
    String? failure;
    try {
      plan = await ref.read(healthRepositoryProvider).loadAlerts();
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'Your reminders could not be fetched just now. Nothing has '
            'changed — try again in a moment.',
      );
    } finally {
      // In a `finally`, so a thrown failure cannot leave this screen spinning
      // for ever with no way back to it.
      final AlertPlan? fetched = plan;
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailure = failure;
          if (fetched != null) {
            _plan = fetched;
            _adoptQuietHours(fetched);
          }
        });
      }
    }
  }

  /// Take the saved window into the pickers, or leave the proposal standing.
  ///
  /// Only ever called from inside a `setState`.
  void _adoptQuietHours(AlertPlan plan) {
    final String? start = plan.quietHours.start;
    final String? end = plan.quietHours.end;
    if (start != null && end != null) {
      _quietStart = start;
      _quietEnd = end;
    }
  }

  /// Turn one type of reminder on or off.
  ///
  /// The busy set is cleared in a `finally` for the same reason the consent
  /// screen clears its flag there: a path out of here that skipped it would
  /// leave the row spinning for ever and every later tap on it turned away as
  /// a duplicate. A refusal changes nothing on screen but the sentence above —
  /// [_plan] is only ever replaced by what the server actually answered, so a
  /// switch that failed to move is still showing the state the backend holds.
  Future<void> _setEnabled(String alertType, bool enabled) async {
    if (_busyTypes.contains(alertType)) {
      // Already in flight. A second tap would send the same change twice.
      return;
    }
    setState(() {
      _busyTypes.add(alertType);
      _writeFailure = null;
    });

    AlertPlan? updated;
    String? failure;
    try {
      updated = await ref.read(healthRepositoryProvider).setAlertEnabled(
            alertType,
            enabled: enabled,
          );
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'That reminder could not be changed just now. It is still '
            'set the way it was — try again in a moment.',
      );
    } finally {
      final AlertPlan? fresh = updated;
      if (mounted) {
        setState(() {
          _busyTypes.remove(alertType);
          _writeFailure = failure;
          if (fresh != null) {
            _plan = fresh;
          }
        });
      }
    }

    if (updated != null) {
      await _reschedule(updated);
    }
  }

  /// Save the quiet-hours window.
  Future<void> _saveQuietHours() async {
    if (_savingQuietHours) {
      return;
    }
    setState(() {
      _savingQuietHours = true;
      _writeFailure = null;
    });

    AlertPlan? updated;
    String? failure;
    try {
      updated = await ref.read(healthRepositoryProvider).setQuietHours(
            start: _quietStart,
            end: _quietEnd,
          );
    } catch (error) {
      failure = explainFailure(
        error,
        fallback: 'Your quiet hours could not be saved just now. Nothing has '
            'changed — try again in a moment.',
      );
    } finally {
      final AlertPlan? fresh = updated;
      if (mounted) {
        setState(() {
          _savingQuietHours = false;
          _writeFailure = failure;
          if (fresh != null) {
            _plan = fresh;
            // Back to whatever the backend now holds, which is the only honest
            // thing to show in the pickers after a save.
            _adoptQuietHours(fresh);
          }
        });
      }
    }

    if (updated != null) {
      await _reschedule(updated);
    }
  }

  /// Hand the changed plan to Android straight away.
  ///
  /// The alarms are set by the phone, not pushed by a server, so a setting that
  /// only reached the backend would not take effect until the next time Today
  /// happened to fetch the alerts. [NotificationService.applyPlan] compares
  /// fingerprints, so re-applying an unchanged plan does nothing and no pending
  /// reminder is cancelled needlessly.
  Future<void> _reschedule(AlertPlan plan) async {
    if (ref.read(apiClientProvider) == null) {
      // Sample mode. The alerts belong to a fictional person, and putting their
      // breakfast on somebody's lock screen is exactly what
      // `scheduledRemindersProvider` refuses to do for the same reason.
      return;
    }
    final NotificationService notifications =
        ref.read(notificationServiceProvider);
    try {
      await notifications.applyPlan(plan);
    } catch (_) {
      // The setting itself is saved; only the phone's own alarm table is
      // behind, and the next app open lays the plan down again. Reporting this
      // as a failed change would be a lie about what happened.
    }
    if (!mounted) {
      return;
    }
    // Today shows how many reminders are set. That number has just changed.
    ref.invalidate(scheduledRemindersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AlertPlan? plan = _plan;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to More',
          onPressed: () => context.go('/more'),
        ),
        title: const Text('Reminders'),
      ),
      body: SafeArea(
        bottom: false,
        child: _body(p, plan),
      ),
    );
  }

  Widget _body(HpPalette p, AlertPlan? plan) {
    if (plan == null && _loading) {
      return const HpLoadingState(
        message: 'Getting your reminders',
        detail: 'The health engine sleeps between visits, so the first look of '
            'the day can take a moment.',
      );
    }
    final String? loadFailure = _loadFailure;
    if (plan == null) {
      return HpErrorState(
        title: 'We could not fetch your reminders',
        body: loadFailure ??
            'Nothing has changed. Your existing reminders are still set on '
                'this phone.',
        onRetry: _load,
      );
    }

    final List<_ReminderGroup> groups = _groupsOf(plan);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HpSpacing.gutter,
        HpSpacing.lg,
        HpSpacing.gutter,
        HpSpacing.section,
      ),
      children: <Widget>[
        Text(
          'Your phone sets these itself, so they still arrive with the app '
          'closed and with no signal. Turning one off stops it from the next '
          'time it would have gone off.',
          style: HpType.reading.copyWith(color: p.inkMuted),
        ),
        if (_writeFailure != null) ...<Widget>[
          const SizedBox(height: HpSpacing.lg),
          _FailureLine(message: _writeFailure!),
        ],
        const SizedBox(height: HpSpacing.section),
        if (groups.isEmpty)
          const HpEmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'No reminders yet',
            body: 'Reminders are built from your plan — your meal times, your '
                'water target, when you wind down. Once there is a plan, they '
                'appear here and you can switch any of them off.',
          )
        else ...<Widget>[
          const HpSectionHeader(title: 'What you get reminded about'),
          for (final _ReminderGroup group in groups)
            _ReminderRow(
              group: group,
              busy: _busyTypes.contains(group.alertType),
              onChanged: group.alwaysOn
                  ? null
                  : (bool value) => _setEnabled(group.alertType, value),
            ),
          const SizedBox(height: HpSpacing.section),
          const HpSectionHeader(title: 'Quiet hours'),
          _QuietHoursCard(
            start: _quietStart,
            end: _quietEnd,
            isSet: plan.quietHours.isSet,
            saving: _savingQuietHours,
            onStartChanged: (TimeOfDay time) =>
                setState(() => _quietStart = HpFormat.formatTime(time)),
            onEndChanged: (TimeOfDay time) =>
                setState(() => _quietEnd = HpFormat.formatTime(time)),
            onSave: _saveQuietHours,
          ),
        ],
      ],
    );
  }

  /// One row per kind of reminder, in the order the backend lists its types.
  ///
  /// The rows are built from what this account actually has: asking the backend
  /// to switch off a type there are no alerts for answers "you have no alerts
  /// of that type yet", so offering a switch for it would be offering a control
  /// that cannot work.
  List<_ReminderGroup> _groupsOf(AlertPlan plan) {
    final List<_ReminderGroup> groups = <_ReminderGroup>[];
    final List<String> seen = <String>[];
    for (final AlertDefinition alert in plan.alerts) {
      if (!seen.contains(alert.alertType)) {
        seen.add(alert.alertType);
      }
    }
    // Known types first, in the order `backend/app/domain/enums.py` declares
    // them, so the list does not reshuffle itself when one is switched off.
    // Anything new the backend grows later still gets a row, at the end.
    final List<String> ordered = <String>[
      for (final String type in _knownTypeOrder)
        if (seen.contains(type)) type,
      for (final String type in seen)
        if (!_knownTypeOrder.contains(type)) type,
    ];

    for (final String type in ordered) {
      final List<AlertDefinition> ofType = plan.alerts
          .where((AlertDefinition alert) => alert.alertType == type)
          .toList()
        ..sort((AlertDefinition a, AlertDefinition b) => a.at.compareTo(b.at));
      groups.add(
        _ReminderGroup(
          alertType: type,
          // The backend switches every row of a type together, so these agree
          // in practice. If they ever did not, saying "on" while one still
          // fires is the truthful half of the two.
          enabled: ofType.any((AlertDefinition alert) => alert.enabled),
          alwaysOn: ofType.any((AlertDefinition alert) => alert.alwaysOn),
          // The earliest one's words. Every reminder of a kind is derived with
          // the same body, so the first is the kind's sentence; taking it from
          // the earliest rather than from whichever row arrived first keeps it
          // stable when the list is re-fetched.
          body: ofType.isEmpty ? '' : ofType.first.body,
          times: <String>[
            for (final AlertDefinition alert in ofType) alert.at,
          ],
          allHeldByQuietHours: ofType.every(
            (AlertDefinition alert) => alert.suppressedByQuietHours,
          ),
        ),
      );
    }
    return groups;
  }

  static const List<String> _knownTypeOrder = <String>[
    'hydration',
    'meal',
    'grocery',
    'activity',
    'sleep',
    'nutrition',
    'report_followup',
    'weekly_summary',
    AlertDefinition.escalationType,
  ];
}

/// Every reminder of one kind, as a single row's worth of facts.
class _ReminderGroup {
  const _ReminderGroup({
    required this.alertType,
    required this.enabled,
    required this.alwaysOn,
    required this.times,
    required this.body,
    required this.allHeldByQuietHours,
  });

  /// The wire string, which is what the endpoint is addressed with.
  final String alertType;

  final bool enabled;

  /// True for the one type that cannot be switched off.
  final bool alwaysOn;

  /// The times of day, 24-hour `HH:mm`, earliest first.
  final List<String> times;

  /// What the reminder says, written by the backend and shown verbatim. Empty
  /// only if the server sent no body at all.
  final String body;

  /// True when quiet hours cover every reminder of this kind — the backend's
  /// judgement, read off the reply, not worked out here.
  final bool allHeldByQuietHours;

  String get title => reminderTypeTitle(alertType);

  IconData get icon => reminderTypeIcon(alertType);
}

/// What each kind of reminder is called on screen.
///
/// Written here rather than taken from the wire string, because `report_followup`
/// is a column name and "Report follow-ups" is English. A type this app has not
/// heard of still gets a readable row rather than being hidden, because a
/// reminder somebody is receiving and cannot see in this list is worse than an
/// imperfect name.
String reminderTypeTitle(String alertType) {
  switch (alertType) {
    case 'hydration':
      return 'Water';
    case 'meal':
      return 'Meals';
    case 'grocery':
      return 'Grocery list';
    case 'activity':
      return 'Movement';
    case 'sleep':
      return 'Sleep and winding down';
    case 'nutrition':
      return 'Nutrition notes';
    case 'report_followup':
      return 'Report follow-ups';
    case 'weekly_summary':
      return 'Weekly summary';
    case AlertDefinition.escalationType:
      return 'Findings that need a doctor';
  }
  final String spaced = alertType.replaceAll('_', ' ').trim();
  if (spaced.isEmpty) {
    return 'Reminder';
  }
  return spaced[0].toUpperCase() + spaced.substring(1);
}

IconData reminderTypeIcon(String alertType) {
  switch (alertType) {
    case 'hydration':
      return Icons.local_drink_outlined;
    case 'meal':
      return Icons.restaurant_outlined;
    case 'grocery':
      return Icons.shopping_cart_outlined;
    case 'activity':
      return Icons.directions_walk_rounded;
    case 'sleep':
      return Icons.bedtime_outlined;
    case 'nutrition':
      return Icons.science_outlined;
    case 'report_followup':
      return Icons.description_outlined;
    case 'weekly_summary':
      return Icons.event_outlined;
    case AlertDefinition.escalationType:
      return Icons.health_and_safety_outlined;
  }
  return Icons.notifications_none_rounded;
}

/// The sentence shown in place of a switch on the one type that has none.
const String escalationCannotBeSilenced =
    'This one cannot be switched off. It only appears when something in your '
    'results needs a doctor, and quiet hours do not hold it either.';

class _ReminderRow extends StatelessWidget {
  const _ReminderRow({
    required this.group,
    required this.busy,
    required this.onChanged,
  });

  final _ReminderGroup group;

  /// True while this row's change is in flight. A spinner appears beside the
  /// switch; the guard against a second tap is in the screen, not in here.
  final bool busy;

  /// Null for a type that cannot be switched off.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final ValueChanged<bool>? onChanged = this.onChanged;

    return Padding(
      padding: const EdgeInsets.only(bottom: HpSpacing.sm),
      child: HpCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(group.icon, size: 21, color: p.pine),
                const SizedBox(width: HpSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        group.title,
                        style: HpType.bodyStrong.copyWith(color: p.ink),
                      ),
                      const SizedBox(height: HpSpacing.xxs),
                      Text(
                        _timesLine(group.times),
                        style: HpType.label.copyWith(color: p.inkFaint),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: HpSpacing.md),
                if (busy) ...<Widget>[
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: p.pine,
                    ),
                  ),
                  const SizedBox(width: HpSpacing.md),
                ],
                if (onChanged == null)
                  Icon(Icons.shield_outlined, size: 20, color: p.pineDeep)
                else
                  // Left switched on and left tappable while the change is in
                  // flight, on purpose. The switch shows what the backend
                  // holds, so it has nothing to say yet; the spinner beside it
                  // says a change is on its way; and a second tap is turned
                  // away by the guard in `_setEnabled` rather than by a dead
                  // control, so nothing is sent twice.
                  Switch(value: group.enabled, onChanged: onChanged),
              ],
            ),
            if (group.body.isNotEmpty) ...<Widget>[
              const SizedBox(height: HpSpacing.md),
              Text(
                group.body,
                style: HpType.reading.copyWith(color: p.inkMuted),
              ),
            ],
            if (onChanged == null) ...<Widget>[
              const SizedBox(height: HpSpacing.md),
              Text(
                escalationCannotBeSilenced,
                style: HpType.label.copyWith(color: p.inkMuted),
              ),
            ] else if (group.enabled && group.allHeldByQuietHours) ...<Widget>[
              const SizedBox(height: HpSpacing.md),
              Text(
                'On, but inside your quiet hours, so the phone stays silent.',
                style: HpType.label.copyWith(color: p.inkMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// "8:20 am", or "8:20 am · 11:00 pm" when a kind has more than one time.
  ///
  /// Past four times the list stops being readable and starts being a wall:
  /// water reminders now run every ninety minutes to two hours across a waking
  /// day, which is eight to ten of them. So a long list is said as a count and
  /// a span instead — "10 times a day, 7:00 am to 8:30 pm" — which is what
  /// somebody actually wants to know about a repeating reminder.
  static String _timesLine(List<String> times) {
    if (times.isEmpty) {
      return 'No time set';
    }
    if (times.length > 4) {
      return '${times.length} times a day, ${HpFormat.clockLabel(times.first)} '
          'to ${HpFormat.clockLabel(times.last)}';
    }
    return times.map(HpFormat.clockLabel).join(' · ');
  }
}

class _QuietHoursCard extends StatelessWidget {
  const _QuietHoursCard({
    required this.start,
    required this.end,
    required this.isSet,
    required this.saving,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onSave,
  });

  /// 24-hour `HH:mm`, as edited in this screen.
  final String start;
  final String end;

  /// True when the backend is already holding a window.
  final bool isSet;

  final bool saving;
  final ValueChanged<TimeOfDay> onStartChanged;
  final ValueChanged<TimeOfDay> onEndChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return HpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            isSet
                ? 'Reminders that fall in this window are held. Findings that '
                    'need a doctor are not.'
                : 'You have not set quiet hours yet. Pick a window and the '
                    'phone will hold ordinary reminders inside it. Findings '
                    'that need a doctor are never held.',
            style: HpType.reading.copyWith(color: p.inkMuted),
          ),
          const SizedBox(height: HpSpacing.lg),
          HpTimeRow(
            label: 'Quiet from',
            value: HpFormat.clockLabel(start),
            onChanged: onStartChanged,
          ),
          const SizedBox(height: HpSpacing.sm),
          HpTimeRow(
            label: 'Quiet until',
            value: HpFormat.clockLabel(end),
            onChanged: onEndChanged,
          ),
          const SizedBox(height: HpSpacing.lg),
          HpButton(
            label: 'Save quiet hours',
            icon: Icons.schedule_rounded,
            busy: saving,
            onPressed: onSave,
          ),
        ],
      ),
    );
  }
}

/// A refusal, said where the thing that was refused is.
class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 18, color: p.urgentInk),
          const SizedBox(width: HpSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: HpType.label.copyWith(color: p.urgentInk),
            ),
          ),
        ],
      ),
    );
  }
}
