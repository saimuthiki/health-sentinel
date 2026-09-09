/// How old a saved copy is, and how to say so without lying about it.
///
/// The rule this file exists to keep is short: **cached is never presented as
/// current.** An app that shows yesterday's plan with today's confidence is
/// worse than an app that shows nothing, because the person has no way to tell
/// the difference — and in a health app the difference is the whole point.
///
/// So anything served from the cache arrives wrapped in [Cached], carrying the
/// moment it was fetched, and every screen that renders one is expected to
/// render [stalenessLabel] with it.
library;

/// A value, and when it came off the network.
class Cached<T> {
  const Cached({required this.value, required this.storedAt});

  final T value;

  /// When the backend answered — not when it was written to disk, and not when
  /// it was read back.
  final DateTime storedAt;

  Duration ageAt(DateTime now) {
    final Duration age = now.difference(storedAt);
    // A phone whose clock has moved backwards is not evidence of freshness.
    return age.isNegative ? Duration.zero : age;
  }

  /// Old enough that the interface should say so rather than only note it.
  bool isStaleAt(
    DateTime now, {
    Duration freshFor = const Duration(minutes: 15),
  }) =>
      ageAt(now) >= freshFor;

  Cached<R> map<R>(R Function(T value) change) =>
      Cached<R>(value: change(value), storedAt: storedAt);
}

/// "just now", "2 hours ago", "3 days ago".
///
/// Deliberately coarse. "1 hour 47 minutes ago" is a number nobody needs and a
/// sentence nobody reads; what matters is whether this is minutes old or days
/// old. Rounding is downward — the copy never claims data is fresher than it is.
String relativeAge(DateTime storedAt, {DateTime? now}) {
  final DateTime at = now ?? DateTime.now();
  final Duration age = at.difference(storedAt);
  if (age.isNegative || age.inSeconds < 60) {
    return 'just now';
  }
  if (age.inMinutes < 60) {
    final int minutes = age.inMinutes;
    return minutes == 1 ? '1 minute ago' : '$minutes minutes ago';
  }
  if (age.inHours < 24) {
    final int hours = age.inHours;
    return hours == 1 ? '1 hour ago' : '$hours hours ago';
  }
  final int days = age.inDays;
  return days == 1 ? '1 day ago' : '$days days ago';
}

/// The full sentence a screen shows over cached content.
///
/// It says two things in one line: this came off the phone, and this is how old
/// it is. Both halves are needed — "2 hours ago" alone reads like a freshness
/// boast rather than a warning.
String stalenessLabel(DateTime storedAt, {DateTime? now}) =>
    'Saved on this phone — last updated ${relativeAge(storedAt, now: now)}';
