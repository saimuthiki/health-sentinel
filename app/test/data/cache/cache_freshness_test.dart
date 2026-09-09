import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/cache/cache_freshness.dart';
import 'package:healthpulse/data/cache/offline_cache.dart';

/// Staleness, said honestly.
///
/// The product rule these enforce: anything read off the phone is labelled with
/// where it came from and how old it is. A cached plan that looks exactly like a
/// live one is the failure mode this file exists to prevent.
void main() {
  final DateTime now = DateTime(2026, 9, 9, 18, 30);

  group('how old it is, in words', () {
    test('seconds are "just now"', () {
      expect(
        relativeAge(now.subtract(const Duration(seconds: 40)), now: now),
        'just now',
      );
    });

    test('minutes are counted, and one is singular', () {
      expect(
        relativeAge(now.subtract(const Duration(minutes: 1)), now: now),
        '1 minute ago',
      );
      expect(
        relativeAge(now.subtract(const Duration(minutes: 47)), now: now),
        '47 minutes ago',
      );
    });

    test('hours round down, so the copy never claims to be fresher', () {
      expect(
        relativeAge(
          now.subtract(const Duration(hours: 2, minutes: 59)),
          now: now,
        ),
        '2 hours ago',
      );
      expect(
        relativeAge(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
    });

    test('a day and more', () {
      expect(
        relativeAge(now.subtract(const Duration(hours: 25)), now: now),
        '1 day ago',
      );
      expect(
        relativeAge(now.subtract(const Duration(days: 3)), now: now),
        '3 days ago',
      );
    });

    test('a phone whose clock went backwards is not fresher than now', () {
      expect(
        relativeAge(now.add(const Duration(hours: 4)), now: now),
        'just now',
      );
    });
  });

  test('the label says where it came from as well as how old it is', () {
    final String label =
        stalenessLabel(now.subtract(const Duration(hours: 2)), now: now);
    expect(label, contains('2 hours ago'));
    expect(label.toLowerCase(), contains('saved on this phone'));
    // Never "live", never "up to date", never "current".
    expect(label.toLowerCase(), isNot(contains('live')));
    expect(label.toLowerCase(), isNot(contains('up to date')));
  });

  group('Cached', () {
    test('ages, and goes stale on a threshold', () {
      final Cached<int> entry = Cached<int>(
        value: 1,
        storedAt: now.subtract(const Duration(minutes: 20)),
      );
      expect(entry.ageAt(now), const Duration(minutes: 20));
      expect(entry.isStaleAt(now), isTrue);
      expect(
        entry.isStaleAt(now, freshFor: const Duration(hours: 1)),
        isFalse,
      );
    });

    test('a clock that moved backwards reads as no age, never a negative one',
        () {
      final Cached<int> entry =
          Cached<int>(value: 1, storedAt: now.add(const Duration(hours: 1)));
      expect(entry.ageAt(now), Duration.zero);
      expect(entry.isStaleAt(now), isFalse);
    });
  });

  group('the in-memory store behaves like the real one', () {
    test('reads back what was written, with its timestamp', () async {
      final MemoryOfflineCache cache = MemoryOfflineCache();
      await cache.write(
        OfflineCache.plan,
        <String, dynamic>{'display_name': 'Sai'},
        at: now,
      );
      final Cached<Map<String, dynamic>>? read =
          await cache.read(OfflineCache.plan);
      expect(read, isNotNull);
      expect(read!.value['display_name'], 'Sai');
      expect(read.storedAt, now);
    });

    test('a miss is null rather than an empty map pretending to be data',
        () async {
      final MemoryOfflineCache cache = MemoryOfflineCache();
      expect(await cache.read(OfflineCache.plan), isNull);
    });

    test('what was stored cannot be changed from outside afterwards', () async {
      final MemoryOfflineCache cache = MemoryOfflineCache();
      final Map<String, dynamic> source = <String, dynamic>{'ml': 250};
      await cache.write(OfflineCache.plan, source);
      source['ml'] = 9999;
      final Cached<Map<String, dynamic>>? read =
          await cache.read(OfflineCache.plan);
      expect(read!.value['ml'], 250);
    });

    test('sign-out empties it', () async {
      final MemoryOfflineCache cache = MemoryOfflineCache();
      await cache.write(OfflineCache.plan, <String, dynamic>{'a': 1});
      await cache.write(OfflineCache.alerts, <String, dynamic>{'b': 2});
      await cache.clear();
      expect(await cache.read(OfflineCache.plan), isNull);
      expect(await cache.read(OfflineCache.alerts), isNull);
    });

    test('hydration is keyed per calendar day', () {
      expect(
        OfflineCache.hydrationFor(DateTime(2026, 9, 9)),
        'hydration.2026-09-09',
      );
      expect(
        OfflineCache.hydrationFor(DateTime(2026, 9, 9, 23, 59)),
        OfflineCache.hydrationFor(DateTime(2026, 9, 9, 0, 1)),
      );
      expect(
        OfflineCache.hydrationFor(DateTime(2026, 9, 10)),
        isNot(OfflineCache.hydrationFor(DateTime(2026, 9, 9))),
      );
    });
  });
}
