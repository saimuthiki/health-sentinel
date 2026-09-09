import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/format/hp_format.dart';

void main() {
  group('clock labels', () {
    test('turn 24-hour storage into readable time', () {
      expect(HpFormat.clockLabel('06:30'), '6:30 am');
      expect(HpFormat.clockLabel('13:30'), '1:30 pm');
      expect(HpFormat.clockLabel('00:05'), '12:05 am');
      expect(HpFormat.clockLabel('12:00'), '12:00 pm');
    });

    test('hand back anything they cannot parse, rather than guessing', () {
      expect(HpFormat.clockLabel('not a time'), 'not a time');
      expect(HpFormat.clockLabel('25:00'), '25:00');
    });
  });

  group('time parsing', () {
    test('round-trips through TimeOfDay', () {
      const TimeOfDay time = TimeOfDay(hour: 20, minute: 30);
      expect(HpFormat.formatTime(time), '20:30');
      expect(HpFormat.parseTime('20:30'), time);
    });

    test('rejects out-of-range values', () {
      expect(HpFormat.parseTime('24:00'), isNull);
      expect(HpFormat.parseTime('10:70'), isNull);
      expect(HpFormat.parseTime('nonsense'), isNull);
    });

    test('orders the day by minutes past midnight', () {
      expect(HpFormat.minutesOfDay('06:30'), 390);
      expect(HpFormat.minutesOfDay('20:30'), 1230);
      expect(HpFormat.minutesOfDay('bad'), 0);
    });
  });

  group('day labels', () {
    final DateTime now = DateTime(2026, 9, 9);

    test('name today and its neighbours', () {
      expect(HpFormat.relativeDay(DateTime(2026, 9, 9), now: now), 'Today');
      expect(
        HpFormat.relativeDay(DateTime(2026, 9, 8), now: now),
        'Yesterday',
      );
      expect(
        HpFormat.relativeDay(DateTime(2026, 9, 10), now: now),
        'Tomorrow',
      );
      expect(
        HpFormat.relativeDay(DateTime(2026, 8, 14), now: now),
        '14 Aug 2026',
      );
    });
  });

  group('greeting', () {
    test('follows the clock', () {
      expect(HpFormat.greeting(DateTime(2026, 9, 9, 7)), 'Good morning');
      expect(HpFormat.greeting(DateTime(2026, 9, 9, 14)), 'Good afternoon');
      expect(HpFormat.greeting(DateTime(2026, 9, 9, 21)), 'Good evening');
    });
  });

  group('numbers', () {
    test('drop a decimal that says nothing', () {
      expect(HpFormat.number(18), '18');
      expect(HpFormat.number(11.8), '11.8');
      expect(HpFormat.number(2.35), '2.4');
    });

    test('switch to litres past a litre', () {
      expect(HpFormat.volume(750), '750 ml');
      expect(HpFormat.volume(1600), '1.6 L');
      expect(HpFormat.volume(2000), '2 L');
    });
  });
}
