import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/core/widgets/hp_stale_notice.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/repository/fake_health_repository.dart';
import 'package:healthpulse/data/repository/health_repository.dart';

import '../_harness.dart';
import '_today_harness.dart';

/// A day that came off the phone, with a switch for "the network is back".
///
/// It extends the sample repository and adds the one thing Today asks about
/// staleness — [CacheAware.servedFromCacheAt] — because that really is all the
/// screen is told. There is no failure kind here to inspect, which is the whole
/// point of the copy change these tests guard.
class _CachedDayRepository extends FakeHealthRepository implements CacheAware {
  _CachedDayRepository({required this.briefing, this.storedAt})
      : super(latency: Duration.zero, signedIn: true);

  final TodayBriefing briefing;

  /// When the saved copy was fetched, or null once a fetch gets through.
  DateTime? storedAt;

  /// How many times Today has been asked for, so a test can prove that
  /// something other than the person's own thumb asked for it.
  int loads = 0;

  @override
  Future<TodayBriefing> loadToday(DateTime date) async {
    loads += 1;
    return briefing;
  }

  @override
  DateTime? servedFromCacheAt(String subject) =>
      subject == CacheAware.cacheSubjectToday ? storedAt : null;

  /// The backend answers again: the next load is off the network.
  void networkIsBack() => storedAt = null;
}

/// Let a queued load land without waiting on any animation.
///
/// [WidgetTester.pumpAndSettle] cannot be used on this screen: it shows a
/// spinner while Today is loading and a spinner animates for ever, so settling
/// would time out rather than finish. Several small pumps instead, which is
/// enough for a provider to be invalidated, recomputed and drawn.
Future<void> settleQuietly(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

/// Take the screen down so nothing is left running after the test.
///
/// The notice keeps a repeating timer while the day on screen is a saved one.
/// It is cancelled when the widget is disposed, and this is what disposes it.
Future<void> closeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  group('what the notice itself says', () {
    testWidgets('one quiet line: saved here, and how old', (
      WidgetTester tester,
    ) async {
      final DateTime storedAt = DateTime(2026, 9, 10, 7, 30);
      await pumpOnce(
        tester,
        wrapForTest(
          HpStaleNotice(
            storedAt: storedAt,
            now: storedAt.add(const Duration(minutes: 4)),
          ),
        ),
      );

      expect(
        find.text('Saved on this phone — last updated 4 minutes ago'),
        findsOneWidget,
      );
      // Closed, it is one line and nothing else. The frightening clause is not
      // gone, it is behind the tap below.
      expect(find.textContaining('would need a doctor'), findsNothing);
      expect(find.text(HpStaleNotice.expandLabel), findsOneWidget);
    });

    testWidgets('the withheld findings are one tap away', (
      WidgetTester tester,
    ) async {
      final DateTime storedAt = DateTime(2026, 9, 10, 7, 30);
      await pumpOnce(
        tester,
        wrapForTest(
          HpStaleNotice(
            storedAt: storedAt,
            now: storedAt.add(const Duration(hours: 2)),
          ),
        ),
      );

      await tester.ensureVisible(find.byType(HpStaleNotice));
      await tester.tap(find.byType(HpStaleNotice));
      await tester.pump();

      expect(find.textContaining('would need a doctor'), findsOneWidget);
      // And the line that is always on screen is still on screen.
      expect(
        find.text('Saved on this phone — last updated 2 hours ago'),
        findsOneWidget,
      );
      expect(find.text(HpStaleNotice.collapseLabel), findsOneWidget);
    });

    testWidgets('it never claims to know that the phone is offline', (
      WidgetTester tester,
    ) async {
      // The flag behind this notice is set for any retryable failure, and a
      // sleeping free-tier backend times out far more often than a phone loses
      // signal. Nothing the screen is given can tell those apart, so the copy
      // must not pick one.
      final DateTime storedAt = DateTime(2026, 9, 10, 7, 30);
      await pumpOnce(
        tester,
        wrapForTest(
          HpStaleNotice(
            storedAt: storedAt,
            now: storedAt.add(const Duration(minutes: 4)),
          ),
        ),
      );

      await tester.ensureVisible(find.byType(HpStaleNotice));
      await tester.tap(find.byType(HpStaleNotice));
      await tester.pump();

      expect(find.textContaining('offline'), findsNothing);
      expect(find.textContaining('no signal'), findsNothing);
      expect(
        find.textContaining('cannot tell whether that is your connection'),
        findsOneWidget,
      );
    });

    testWidgets('it says when it is trying, without losing the line', (
      WidgetTester tester,
    ) async {
      final DateTime storedAt = DateTime(2026, 9, 10, 7, 30);
      await pumpOnce(
        tester,
        wrapForTest(
          HpStaleNotice(
            storedAt: storedAt,
            checking: true,
            now: storedAt.add(const Duration(minutes: 4)),
          ),
        ),
      );

      expect(find.text(HpStaleNotice.checkingLabel), findsOneWidget);
      expect(
        find.text('Saved on this phone — last updated 4 minutes ago'),
        findsOneWidget,
      );
    });
  });

  group('Today, when the day came off the phone', () {
    testWidgets('says so, above the day itself', (WidgetTester tester) async {
      useTallSurface(tester);
      final _CachedDayRepository repository = _CachedDayRepository(
        briefing: briefingWith(),
        storedAt: DateTime.now().subtract(const Duration(minutes: 4)),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await settleQuietly(tester);

      expect(find.byType(HpStaleNotice), findsOneWidget);
      expect(find.textContaining('Saved on this phone'), findsOneWidget);
      // Quiet: the sentence about a doctor is not shouted at him on arrival.
      expect(find.textContaining('would need a doctor'), findsNothing);
      // And it is nowhere claimed that he has no connection.
      expect(find.textContaining('offline'), findsNothing);

      await closeScreen(tester);
    });

    testWidgets('the full explanation is reachable on the screen itself', (
      WidgetTester tester,
    ) async {
      useTallSurface(tester);
      final _CachedDayRepository repository = _CachedDayRepository(
        briefing: briefingWith(),
        storedAt: DateTime.now().subtract(const Duration(minutes: 4)),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await settleQuietly(tester);

      await tester.ensureVisible(find.byType(HpStaleNotice));
      await tester.tap(find.byType(HpStaleNotice));
      await tester.pump();

      expect(find.textContaining('would need a doctor'), findsOneWidget);

      await closeScreen(tester);
    });

    testWidgets('a day off the network shows no notice at all', (
      WidgetTester tester,
    ) async {
      useTallSurface(tester);
      final _CachedDayRepository repository = _CachedDayRepository(
        briefing: briefingWith(),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await settleQuietly(tester);

      expect(find.byType(HpStaleNotice), findsNothing);
      expect(find.byType(HpFreshNotice), findsNothing);
      expect(find.textContaining('Saved on this phone'), findsNothing);

      await closeScreen(tester);
    });

    testWidgets('it tries again by itself and takes itself away', (
      WidgetTester tester,
    ) async {
      // The complaint underneath the complaint: nothing retried, so the notice
      // stayed until he pulled the screen down.
      useTallSurface(tester);
      final _CachedDayRepository repository = _CachedDayRepository(
        briefing: briefingWith(),
        storedAt: DateTime.now().subtract(const Duration(minutes: 4)),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await settleQuietly(tester);
      expect(repository.loads, 1);
      expect(find.byType(HpStaleNotice), findsOneWidget);

      // The backend wakes up. Nobody touches the phone.
      repository.networkIsBack();
      await tester.pump(const Duration(seconds: 31));
      await settleQuietly(tester);

      expect(repository.loads, 2);
      expect(find.byType(HpStaleNotice), findsNothing);
      // And the recovery is visible rather than silent.
      expect(find.text(HpFreshNotice.text), findsOneWidget);

      // Which then gets out of the way on its own.
      await tester.pump(const Duration(seconds: 7));
      expect(find.byType(HpFreshNotice), findsNothing);

      await closeScreen(tester);
    });

    testWidgets('a retry that fails leaves the notice exactly where it was', (
      WidgetTester tester,
    ) async {
      useTallSurface(tester);
      final _CachedDayRepository repository = _CachedDayRepository(
        briefing: briefingWith(),
        storedAt: DateTime.now().subtract(const Duration(minutes: 4)),
      );

      await tester.pumpWidget(todayApp(repository: repository));
      await settleQuietly(tester);

      await tester.pump(const Duration(seconds: 31));
      await settleQuietly(tester);

      expect(repository.loads, 2);
      expect(find.byType(HpStaleNotice), findsOneWidget);
      expect(find.byType(HpFreshNotice), findsNothing);

      await closeScreen(tester);
    });
  });
}
