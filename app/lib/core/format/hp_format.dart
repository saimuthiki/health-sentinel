import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Formatting the interface agrees on, so a time never appears two ways.
class HpFormat {
  const HpFormat._();

  static final DateFormat _dayFull = DateFormat('EEEE, d MMMM');
  static final DateFormat _dayShort = DateFormat('d MMM');
  static final DateFormat _dayWithYear = DateFormat('d MMM yyyy');
  static final DateFormat _clock = DateFormat('h:mm a');

  /// "Tuesday, 9 September".
  static String dayFull(DateTime date) => _dayFull.format(date);

  /// "14 Aug".
  static String dayShort(DateTime date) => _dayShort.format(date);

  /// "14 Aug 2026".
  static String dayWithYear(DateTime date) => _dayWithYear.format(date);

  /// "Today", "Yesterday", or "14 Aug 2026".
  static String relativeDay(DateTime date, {DateTime? now}) {
    final DateTime today = now ?? DateTime.now();
    final DateTime a = DateTime(date.year, date.month, date.day);
    final DateTime b = DateTime(today.year, today.month, today.day);
    final int days = b.difference(a).inDays;
    if (days == 0) {
      return 'Today';
    }
    if (days == 1) {
      return 'Yesterday';
    }
    if (days == -1) {
      return 'Tomorrow';
    }
    return dayWithYear(date);
  }

  /// "06:30" becomes "6:30 am". Lower case, because a sentence of interface copy
  /// should not have two shouted letters in the middle of it.
  static String clockLabel(String hhmm) {
    final TimeOfDay? parsed = parseTime(hhmm);
    if (parsed == null) {
      return hhmm;
    }
    final DateTime asDate =
        DateTime(2000, 1, 1, parsed.hour, parsed.minute);
    return _clock.format(asDate).toLowerCase();
  }

  static String clockLabelFromTime(TimeOfDay time) =>
      clockLabel(formatTime(time));

  /// Parses the 24-hour "HH:mm" the database stores.
  static TimeOfDay? parseTime(String hhmm) {
    final List<String> parts = hhmm.split(':');
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
    return TimeOfDay(hour: hour, minute: minute);
  }

  /// Back to the 24-hour "HH:mm" the database stores.
  static String formatTime(TimeOfDay time) {
    final String h = time.hour.toString().padLeft(2, '0');
    final String m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// Minutes since midnight, for ordering the day.
  static int minutesOfDay(String hhmm) {
    final TimeOfDay? parsed = parseTime(hhmm);
    if (parsed == null) {
      return 0;
    }
    return parsed.hour * 60 + parsed.minute;
  }

  /// "Good morning" / "Good afternoon" / "Good evening".
  static String greeting(DateTime now) {
    if (now.hour < 12) {
      return 'Good morning';
    }
    if (now.hour < 17) {
      return 'Good afternoon';
    }
    return 'Good evening';
  }

  /// Numbers without pointless decimals: 2.0 becomes "2", 2.35 becomes "2.4".
  static String number(double value, {int decimals = 1}) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(decimals);
  }

  /// "1.6 L" reads better than "1600 ml" once it is past a litre.
  static String volume(double millilitres) {
    if (millilitres >= 1000) {
      return '${number(millilitres / 1000)} L';
    }
    return '${number(millilitres, decimals: 0)} ml';
  }
}
