import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/api_client.dart';
import 'package:healthpulse/data/api/auth_token_provider.dart';
import 'package:healthpulse/data/cache/cache_freshness.dart';
import 'package:healthpulse/data/cache/offline_cache.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/services/auth_service.dart';
import 'package:http/http.dart' as http;

import '../api/_fake_http.dart';

/// Water, from the tap in the app to the server and back.
///
/// `logHydration` used to add the millilitres to this phone's cache and call
/// nothing at all: the glass was lost on reinstall, invisible on a second
/// device, and the backend had never seen a drop. These tests are about the two
/// halves of the fix, and the second half is the one that is easy to get wrong.
///
/// * The glass goes to the server, and the total on screen is the server's.
/// * The cache is still the offline path. A glass tapped with no signal is
///   **queued**, counted straight away, and sent when the signal comes back.
///   Only a refusal that replaying could never fix is reported as not saved,
///   and then nothing is kept - because keeping it quietly on the phone while
///   the screen says it was saved is exactly the bug being fixed.
void main() {
  const String today = '2026-09-10';
  DateTime clock() => DateTime(2026, 9, 10, 8, 30);

  HttpHealthRepository buildRepository(
    FakeHttpClient client,
    MemoryOfflineCache cache,
  ) {
    return HttpHealthRepository(
      api: ApiClient(
        baseUrl: Uri.parse('https://healthpulse.test'),
        tokens: _StubTokens(),
        httpClient: client,
        warmTimeout: const Duration(milliseconds: 400),
        coldTimeout: const Duration(milliseconds: 400),
        generationTimeout: const Duration(milliseconds: 800),
        wakeNoticeAfter: const Duration(milliseconds: 20),
      ),
      auth: _StubAuth(),
      cache: cache,
      clock: clock,
    );
  }

  /// The body of the nth request to [path], decoded.
  Map<String, dynamic> bodyOf(FakeHttpClient client, String path, {int nth = 0}) {
    int seen = 0;
    for (int i = 0; i < client.paths.length; i++) {
      if (client.paths[i] != path) {
        continue;
      }
      if (seen == nth) {
        return jsonDecode(utf8.decode(client.bodies[i])) as Map<String, dynamic>;
      }
      seen += 1;
    }
    fail('no request $nth to $path; sent ${client.paths}');
  }

  /// Every millilitre figure sent to [path], in order, attempts included.
  List<int> amountsSentTo(FakeHttpClient client, String path) {
    final List<int> amounts = <int>[];
    for (int i = 0; i < client.paths.length; i++) {
      if (client.paths[i] != path) {
        continue;
      }
      final Map<String, dynamic> body =
          jsonDecode(utf8.decode(client.bodies[i])) as Map<String, dynamic>;
      amounts.add((body['millilitres'] as num).toInt());
    }
    return amounts;
  }

  http.StreamedResponse ok() => jsonResponse(200, <String, dynamic>{});

  group('one glass', () {
    test('is posted to the backend, and the total that comes back is the '
        "server's", () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/v1/feedback/hydration') {
            return jsonResponse(201, <String, dynamic>{
              'on': today,
              'millilitres': 250,
              'day_total_ml': 1150,
            });
          }
          return ok();
        },
      );
      final MemoryOfflineCache cache = MemoryOfflineCache();
      final HttpHealthRepository repository = buildRepository(client, cache);

      expect(await repository.logHydration(250), 1150);

      expect(client.callsTo('/v1/feedback/hydration'), 1);
      expect(
        bodyOf(client, '/v1/feedback/hydration'),
        <String, dynamic>{'millilitres': 250, 'on': today},
      );
    });

    test('leaves the server figure in the cache, not a tally of its own',
        () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/v1/feedback/hydration') {
            return jsonResponse(201, <String, dynamic>{'day_total_ml': 900});
          }
          return ok();
        },
      );
      final MemoryOfflineCache cache = MemoryOfflineCache();
      final HttpHealthRepository repository = buildRepository(client, cache);

      await repository.logHydration(250);

      final Cached<Map<String, dynamic>>? stored =
          await cache.read(OfflineCache.hydrationFor(clock()));
      // 900, the whole day as the server holds it - and not 250, which is all
      // this phone would know if it were keeping the count itself.
      expect(stored?.value['ml'], 900);
    });
  });

  group('with no signal', () {
    test('the glass is queued and counted, not lost and not called a failure',
        () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/v1/feedback/hydration') {
            return problemResponse(503, 'not-ready', 'Still starting up.');
          }
          return ok();
        },
      );
      final MemoryOfflineCache cache = MemoryOfflineCache();
      final HttpHealthRepository repository = buildRepository(client, cache);

      expect(await repository.logHydration(250), 250);
      expect(await repository.logHydration(500), 750);

      final Cached<Map<String, dynamic>>? pending =
          await cache.read(OfflineCache.pendingHydration);
      expect(pending, isNotNull);
      final List<Map<String, dynamic>> drinks =
          asMapList(pending!.value['drinks']);
      expect(drinks.length, 2);
      expect(drinks.first['ml'], 250);
      expect(drinks.first['on'], today);
      expect(drinks.last['ml'], 500);
    });

    test('everything queued is sent when the signal comes back, oldest first',
        () async {
      bool offline = true;
      // The totals the server would answer with, in the order the three glasses
      // reach it. Fixed rather than added up in the responder, because the fake
      // client has already drained the request body by the time it is called.
      final List<int> totals = <int>[250, 750, 850];
      int accepted = 0;
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path != '/v1/feedback/hydration') {
            return ok();
          }
          if (offline) {
            return problemResponse(503, 'not-ready', 'Still starting up.');
          }
          final int total = totals[accepted];
          accepted += 1;
          return jsonResponse(201, <String, dynamic>{'day_total_ml': total});
        },
      );
      final MemoryOfflineCache cache = MemoryOfflineCache();
      final HttpHealthRepository repository = buildRepository(client, cache);

      await repository.logHydration(250);
      await repository.logHydration(500);
      offline = false;

      // The third glass carries the first two with it, in the order they were
      // drunk rather than the order the network came back.
      expect(await repository.logHydration(100), 850);

      final List<int> sent = amountsSentTo(client, '/v1/feedback/hydration');
      // The attempts that were refused while the signal was gone come first;
      // what matters is the three that got through, and their order.
      expect(sent.sublist(sent.length - 3), <int>[250, 500, 100]);

      final Cached<Map<String, dynamic>>? pending =
          await cache.read(OfflineCache.pendingHydration);
      expect(asMapList(pending?.value['drinks']), isEmpty);
    });
  });

  group('a refusal replaying could never fix', () {
    test('is reported, and the glass is not quietly kept on the phone',
        () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/v1/feedback/hydration') {
            return problemResponse(401, 'not-authenticated', 'Sign in again.');
          }
          return ok();
        },
      );
      final MemoryOfflineCache cache = MemoryOfflineCache();
      final HttpHealthRepository repository = buildRepository(client, cache);

      await expectLater(
        repository.logHydration(250),
        throwsA(isA<HealthRepositoryException>()),
      );

      final Cached<Map<String, dynamic>>? pending =
          await cache.read(OfflineCache.pendingHydration);
      expect(
        asMapList(pending?.value['drinks']),
        isEmpty,
        reason: 'silently keeping it on the phone is the bug being fixed',
      );
    });
  });

  group("today's total and today's goal", () {
    Map<String, dynamic> planJson() => <String, dynamic>{
          'plan_date': today,
          'items': <dynamic>[],
          'rationale': 'A steady day.',
          'hydration_ml': 2500,
          'hydration_logged_ml': 1200,
          'hydration_target_ml': 5000,
          'hydration_target_sourced_ml': 2000,
          'hydration_target_chosen_by_user': true,
          'hydration_target_source': 'You set this goal yourself: 5000 ml.',
          'hydration_target_caution': 'Sample caution, as the server wrote it.',
        };

    FakeHttpClient dayClient() {
      return FakeHttpClient((http.BaseRequest request, int attempt) async {
        switch (request.url.path) {
          case '/v1/me':
            return jsonResponse(200, <String, dynamic>{
              'user_id': 'u1',
              'display_name': 'Sai Muthiki',
              'has_health_profile': true,
              'consent_current': true,
            });
          case '/v1/me/profile':
            return jsonResponse(200, <String, dynamic>{
              'user_id': 'u1',
              'wake_time': '06:30',
              'sleep_time': '22:30',
            });
          case '/v1/plan/today':
            return jsonResponse(200, planJson());
          case '/v1/reports':
            return jsonResponse(200, <String, dynamic>{'reports': <dynamic>[]});
          case '/v1/feedback/hydration':
            return jsonResponse(201, <String, dynamic>{'day_total_ml': 400});
          default:
            return ok();
        }
      });
    }

    test('come from the server, not from the phone', () async {
      final FakeHttpClient client = dayClient();
      final MemoryOfflineCache cache = MemoryOfflineCache();
      // A stale number of this phone's own, which must not win.
      await cache.write(
        OfflineCache.hydrationFor(clock()),
        <String, dynamic>{'ml': 9999},
      );
      final HttpHealthRepository repository = buildRepository(client, cache);

      final TodayBriefing briefing = await repository.loadToday(clock());

      expect(briefing.hydrationMl, 1200);
      expect(briefing.hydrationTargetMl, 5000);
      expect(briefing.hydrationTargetSourcedMl, 2000);
      expect(briefing.hydrationTargetChosenByUser, isTrue);
      expect(
        briefing.hydrationTargetCaution,
        'Sample caution, as the server wrote it.',
      );
      expect(briefing.hydrationTargetSource, contains('5000 ml'));
    });

    test('a glass queued last night is sent when the day is opened', () async {
      final FakeHttpClient client = dayClient();
      final MemoryOfflineCache cache = MemoryOfflineCache();
      await cache.write(
        OfflineCache.pendingHydration,
        <String, dynamic>{
          'drinks': <Map<String, dynamic>>[
            <String, dynamic>{'on': '2026-09-09', 'ml': 400},
          ],
        },
      );
      final HttpHealthRepository repository = buildRepository(client, cache);

      await repository.loadToday(clock());

      expect(client.callsTo('/v1/feedback/hydration'), 1);
      // Sent against the day it was drunk, not the day it was sent.
      expect(bodyOf(client, '/v1/feedback/hydration')['on'], '2026-09-09');
    });

    test('a glass that still cannot be sent is counted anyway and kept',
        () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          switch (request.url.path) {
            case '/v1/me':
              return jsonResponse(200, <String, dynamic>{
                'user_id': 'u1',
                'has_health_profile': true,
              });
            case '/v1/me/profile':
              return jsonResponse(200, <String, dynamic>{'user_id': 'u1'});
            case '/v1/plan/today':
              return jsonResponse(200, planJson());
            case '/v1/reports':
              return jsonResponse(
                  200, <String, dynamic>{'reports': <dynamic>[]});
            case '/v1/feedback/hydration':
              return problemResponse(503, 'not-ready', 'Still starting up.');
            default:
              return ok();
          }
        },
      );
      final MemoryOfflineCache cache = MemoryOfflineCache();
      await cache.write(
        OfflineCache.pendingHydration,
        <String, dynamic>{
          'drinks': <Map<String, dynamic>>[
            <String, dynamic>{'on': today, 'ml': 300},
          ],
        },
      );
      final HttpHealthRepository repository = buildRepository(client, cache);

      final TodayBriefing briefing = await repository.loadToday(clock());

      // The server's 1200 plus the 300 this phone still owes it. The day is
      // not broken by a failure nobody asked for.
      expect(briefing.hydrationMl, 1500);
      final Cached<Map<String, dynamic>>? pending =
          await cache.read(OfflineCache.pendingHydration);
      expect(asMapList(pending?.value['drinks']).length, 1);
    });
  });

  group('the water goal', () {
    test('sends the number exactly as typed and returns what came back',
        () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/v1/plan/hydration-target') {
            return jsonResponse(200, <String, dynamic>{
              'hydration_target_ml': 5000,
              'hydration_target_sourced_ml': 2000,
              'hydration_target_chosen_by_user': true,
              'hydration_target_source': 'You set this goal yourself.',
              'hydration_target_caution': 'A warning with a citation in it.',
            });
          }
          return ok();
        },
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final HydrationGoal goal = await repository.setHydrationTarget(5000);

      expect(
        bodyOf(client, '/v1/plan/hydration-target'),
        <String, dynamic>{'millilitres': 5000},
      );
      expect(goal.millilitres, 5000);
      expect(goal.sourcedMillilitres, 2000);
      expect(goal.chosenByUser, isTrue);
      // Verbatim. Nothing on this side rewrote it or decided it was due.
      expect(goal.caution, 'A warning with a citation in it.');
    });

    test('clears the goal with a null that is actually sent', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async => jsonResponse(
          200,
          <String, dynamic>{
            'hydration_target_ml': 2000,
            'hydration_target_sourced_ml': 2000,
            'hydration_target_source': 'EFSA 2010.',
          },
        ),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final HydrationGoal goal = await repository.setHydrationTarget(null);

      final Map<String, dynamic> body =
          bodyOf(client, '/v1/plan/hydration-target');
      expect(body.containsKey('millilitres'), isTrue);
      expect(body['millilitres'], isNull);
      expect(goal.chosenByUser, isFalse);
      expect(goal.millilitres, 2000);
    });

    test('no target at all comes through as null rather than as a default',
        () async {
      const String reason =
          'How much to drink is set by a doctor when a condition on your '
          'profile affects fluid balance, so we do not show a water goal here.';
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async => jsonResponse(
          200,
          <String, dynamic>{
            'hydration_target_ml': null,
            'hydration_target_source': reason,
          },
        ),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final HydrationGoal goal = await repository.setHydrationTarget(2000);

      expect(goal.millilitres, isNull);
      expect(goal.hasTarget, isFalse);
      expect(goal.source, reason);
    });

    test("a 422 reaches the screen carrying the server's own reason", () async {
      const String refusal =
          '6500 ml a day is more than we will set a goal for. Our limit is '
          '6000 ml, which across a normal waking day is about 375 ml an hour.';
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async =>
            problemResponse(422, 'invalid-request', refusal),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      await expectLater(
        repository.setHydrationTarget(6500),
        throwsA(
          isA<HealthRepositoryException>()
              .having((HealthRepositoryException e) => e.message, 'message',
                  refusal),
        ),
      );
    });

    test('anything else still gets our own copy, never the server prose',
        () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async => problemResponse(
          503,
          'not-ready',
          'A sentence written on the server that must not reach a screen.',
        ),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      await expectLater(
        repository.setHydrationTarget(2000),
        throwsA(
          isA<HealthRepositoryException>().having(
            (HealthRepositoryException e) => e.message,
            'message',
            isNot(contains('must not reach a screen')),
          ),
        ),
      );
    });
  });
}

/// A token provider that is signed in and cannot renew. A 401 is a real
/// sign-out here, which is what the "not quietly kept" test needs.
class _StubTokens implements AuthTokenProvider {
  @override
  Future<String?> accessToken() async => 'a-token';

  @override
  Future<String?> refreshAccessToken() async => null;
}

/// The repository needs a gateway; none of these tests touch identity.
class _StubAuth implements AuthGateway {
  @override
  AuthUser? get currentUser =>
      const AuthUser(id: 'u1', email: 'sai@example.com');

  @override
  Stream<AuthLifecycle> get lifecycle => const Stream<AuthLifecycle>.empty();

  @override
  Future<String?> accessToken() async => 'a-token';

  @override
  Future<String?> refreshAccessToken() async => null;

  @override
  Future<AuthUser> signIn({
    required String email,
    required String password,
  }) async =>
      throw UnimplementedError();

  @override
  Future<AuthUser> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> signOut() async {}
}
