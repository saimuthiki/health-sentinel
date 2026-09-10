import 'package:flutter/material.dart';

import '../../core/format/hp_format.dart';
import '../../data/models/models.dart';

/// What a moment in the day is *for*.
///
/// The screen uses this to decide what a tap does - a meal opens the plan, a
/// glass of water opens nothing - instead of recognising a moment by reading
/// its title back, which would quietly break the first time the wording
/// changed.
enum DayMomentKind {
  wake,
  movement,
  meal,
  water,
  windDown,
}

/// One thing that happens at one time of day.
@immutable
class DayMoment {
  const DayMoment({
    required this.kind,
    required this.time,
    required this.title,
    required this.icon,
    this.detail,
  });

  final DayMomentKind kind;

  /// 24-hour "HH:mm", the same shape the database and the profile use.
  final String time;

  final String title;

  /// The line under the title. Null when the title says everything.
  final String? detail;

  final IconData icon;

  /// Minutes since midnight, which is how the day is ordered.
  int get minutesOfDay => HpFormat.minutesOfDay(time);
}

/// How long a gap between meals has to be before a glass of water is suggested
/// inside it, in minutes. Two and a half hours: short enough that a long
/// afternoon gets two prompts, long enough that a snack forty minutes after
/// breakfast does not get one wedged in beside it.
const int _thirstyGapMinutes = 150;

/// The shortest gap before breakfast that is worth putting movement into.
/// Under three quarters of an hour there is no room for it, so it is left out
/// rather than squeezed in against a meal.
const int _shortestMovementGap = 45;

/// The day as a routine, in the order it happens.
///
/// The rule this file exists to hold: **one moment per meal slot, never one per
/// food item**. A lunch of pearl millet, green gram, paneer and ghee is half
/// past one arriving once, with four things to choose between - not four
/// lunches in a row. Emitting a row per item is what made the ribbon
/// unreadable, because a column of four separate one-thirty entries reads as a
/// list to eat in full rather than a choice to make.
///
/// Everything else is arranged around those meals, so the day reads the way a
/// day is actually lived: wake, a stretch of movement in the gap before
/// breakfast, breakfast, the meals in their order with a glass of water in each
/// long gap between them, and winding down at the end.
///
/// Nothing here invents a health fact. The movement moment repeats the target
/// minutes the briefing already carries and deliberately does not name an
/// exercise - the server planned a number of minutes, not a game of badminton,
/// and the app must not put words in its mouth. A water moment is a prompt and
/// never a record: it does not say anything was drunk, because only the
/// hydration control knows that.
List<DayMoment> buildDayRoutine(TodayBriefing briefing) {
  final Map<MealSlot, List<MealPlanItem>> bySlot = groupMealsBySlot(briefing);
  final List<DayMoment> meals = _mealMoments(bySlot);

  final List<DayMoment> moments = <DayMoment>[
    DayMoment(
      kind: DayMomentKind.wake,
      time: briefing.wakeTime,
      title: 'Wake up',
      detail: 'Fifteen minutes of morning light helps your vitamin D.',
      icon: Icons.wb_sunny_outlined,
    ),
    ...meals,
    ..._waterMoments(meals),
    DayMoment(
      kind: DayMomentKind.windDown,
      time: briefing.sleepTime,
      title: 'Wind down',
      detail: 'Screens away thirty minutes before this.',
      icon: Icons.bedtime_outlined,
    ),
  ];

  final DayMoment? movement = _movementMoment(briefing, bySlot, meals);
  if (movement != null) {
    moments.add(movement);
  }

  // Two things can land on the same minute - waking and an early glass of warm
  // water often do - so the tie is broken by kind. `List.sort` is not stable in
  // Dart, and without the second key the order of two 6:30 entries would be
  // whatever the sort happened to do that morning.
  moments.sort((DayMoment a, DayMoment b) {
    final int byTime = a.minutesOfDay.compareTo(b.minutesOfDay);
    if (byTime != 0) {
      return byTime;
    }
    return a.kind.index.compareTo(b.kind.index);
  });
  return moments;
}

/// The briefing's meals, gathered under the slot each one belongs to.
///
/// Kept public because the screen counts the slots for its section heading, and
/// counting `briefing.meals` there would put the same off-by-three back on
/// screen in words ("6 planned" for three meals) after the ribbon had been
/// fixed.
Map<MealSlot, List<MealPlanItem>> groupMealsBySlot(TodayBriefing briefing) {
  final Map<MealSlot, List<MealPlanItem>> grouped =
      <MealSlot, List<MealPlanItem>>{};
  for (final MealPlanItem item in briefing.meals) {
    grouped.putIfAbsent(item.mealSlot, () => <MealPlanItem>[]).add(item);
  }
  return grouped;
}

/// The line under a meal's title.
///
/// With one thing planned it is simply that thing. With more than one it has to
/// say, in the fewest possible words, that these are alternatives: the count
/// first, so the eye gets "one of four" before it gets the four names. This
/// sentence is the whole fix. Read as a list, "pearl millet, green gram,
/// paneer, ghee" is four things to eat; read as "Choose one of 4", it is a
/// question with four answers.
String describeMealChoice(List<MealPlanItem> items) {
  if (items.isEmpty) {
    return '';
  }
  if (items.length == 1) {
    final MealPlanItem only = items.first;
    final String? portion = only.portion;
    if (portion == null || portion.isEmpty) {
      return only.title;
    }
    return '${only.title} · $portion';
  }
  final String names =
      items.map((MealPlanItem item) => item.title).join(', ');
  return 'Choose one of ${items.length}: $names';
}

List<DayMoment> _mealMoments(Map<MealSlot, List<MealPlanItem>> bySlot) {
  // Iterating the enum rather than the map keeps the day in the order a day
  // happens, whatever order the server sent the items in.
  final List<DayMoment> moments = <DayMoment>[];
  for (final MealSlot slot in MealSlot.values) {
    final List<MealPlanItem>? items = bySlot[slot];
    if (items == null || items.isEmpty) {
      continue;
    }
    moments.add(
      DayMoment(
        kind: DayMomentKind.meal,
        time: items.first.timeOfDay ?? slot.defaultTime,
        title: slot.label,
        detail: describeMealChoice(items),
        icon: Icons.restaurant_outlined,
      ),
    );
  }
  return moments;
}

/// A glass of water in every long gap between two meals.
///
/// Spread evenly inside the gap rather than dropped at its midpoint, so a seven
/// hour afternoon gets two prompts three hours apart instead of one lonely one
/// in the middle of it.
List<DayMoment> _waterMoments(List<DayMoment> meals) {
  final List<DayMoment> water = <DayMoment>[];
  for (int i = 0; i + 1 < meals.length; i++) {
    final int from = meals[i].minutesOfDay;
    final int to = meals[i + 1].minutesOfDay;
    final int gap = to - from;
    final int count = gap ~/ _thirstyGapMinutes;
    for (int n = 1; n <= count; n++) {
      water.add(
        DayMoment(
          kind: DayMomentKind.water,
          time: _clockOf(from + gap * n ~/ (count + 1)),
          title: 'Water',
          detail: 'A good moment for a glass.',
          icon: Icons.local_drink_outlined,
        ),
      );
    }
  }
  return water;
}

/// Movement, placed in the gap between getting up and breakfast.
///
/// The owner runs or plays badminton in the morning, so this is where it
/// belongs in the ribbon - but the moment says the target minutes and nothing
/// else. Naming a sport the server did not plan would be the app inventing a
/// prescription, and it is exactly the kind of small invention the safety
/// charter exists to stop.
DayMoment? _movementMoment(
  TodayBriefing briefing,
  Map<MealSlot, List<MealPlanItem>> bySlot,
  List<DayMoment> meals,
) {
  if (briefing.movementTargetMinutes <= 0) {
    return null;
  }

  final int wake = HpFormat.minutesOfDay(briefing.wakeTime);
  final List<MealPlanItem>? breakfast = bySlot[MealSlot.breakfast];
  final int breakfastAt = breakfast == null || breakfast.isEmpty
      // No breakfast planned, so there is no hard edge to work back from. Two
      // hours after waking is a guess about the shape of a morning, not about
      // anybody's health.
      ? wake + 120
      : HpFormat.minutesOfDay(
          breakfast.first.timeOfDay ?? MealSlot.breakfast.defaultTime,
        );

  // Anything already planned before breakfast - the early-morning glass of
  // warm water, say - has to come first, so the gap starts at whichever is
  // later.
  int from = wake;
  for (final DayMoment meal in meals) {
    if (meal.minutesOfDay < breakfastAt && meal.minutesOfDay > from) {
      from = meal.minutesOfDay;
    }
  }

  if (breakfastAt - from < _shortestMovementGap) {
    return null;
  }

  return DayMoment(
    kind: DayMomentKind.movement,
    time: _clockOf(from + (breakfastAt - from) ~/ 2),
    title: 'Move',
    detail: '${briefing.movementTargetMinutes} minutes is the target today. '
        'Whatever you already enjoy doing counts.',
    icon: Icons.directions_walk_rounded,
  );
}

/// Minutes since midnight back to the "HH:mm" the rest of the app speaks.
///
/// Written out rather than with `clamp` because the day must never wrap past
/// midnight into "24:10", which `HpFormat.parseTime` would refuse and the
/// ribbon would then sort to the top of the morning.
String _clockOf(int minutes) {
  int held = minutes;
  if (held < 0) {
    held = 0;
  }
  if (held > 24 * 60 - 1) {
    held = 24 * 60 - 1;
  }
  final String hours = (held ~/ 60).toString().padLeft(2, '0');
  final String rest = (held % 60).toString().padLeft(2, '0');
  return '$hours:$rest';
}
