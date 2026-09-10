import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/api_client.dart';
import 'package:healthpulse/data/api/auth_token_provider.dart';
import 'package:healthpulse/data/api/wire.dart';
import 'package:healthpulse/data/cache/cache_freshness.dart';
import 'package:healthpulse/data/cache/offline_cache.dart';
import 'package:healthpulse/data/models/models.dart';
import 'package:healthpulse/data/repository/health_repository.dart';
import 'package:healthpulse/data/repository/http_health_repository.dart';
import 'package:healthpulse/services/auth_service.dart';
import 'package:http/http.dart' as http;

import '../api/_fake_http.dart';

/// One report's detail is not the day.
///
/// `loadToday` fetches the latest report's detail so that a red flag over it can sit
/// above everything else. It used to `await` that call bare, so the day the backend
/// answered 500 for one report - a real thing, caused by our own curated copy tripping
/// our own medication rail - the person opened the app and was told Today could not be
/// loaded. The plan had loaded. The profile had loaded. The water figure had loaded.
///
/// Surviving it is not allowed to be a quiet all-clear: escalations are the one part of
/// the day where an empty list is a claim. So a failure becomes a card of its own, in
/// the place a real finding would be, saying it could not be checked.
void main() {
  const String today = '2026-09-10';
  const String reportId = 'r-1';
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

  Map<String, dynamic> planJson() => <String, dynamic>{
        'plan_date': today,
        'items': <dynamic>[],
        'rationale': 'A steady day.',
        'hydration_ml': 2500,
        'hydration_logged_ml': 1200,
        'hydration_target_ml': 2500,
        'hydration_target_sourced_ml': 2500,
        'hydration_target_source': 'EFSA 2010.',
      };

  Map<String, dynamic> reportsJson() => <String, dynamic>{
        'reports': <dynamic>[
          <String, dynamic>{
            'id': reportId,
            'status': 'extracted',
            'report_type': 'blood',
            'lab_name': 'Vijaya Diagnostic Centre',
            'collected_on': '2026-08-14',
            'file_hash': 'abc123',
          },
        ],
      };

  /// A day where everything answers, and the report detail answers with [detail].
  FakeHttpClient dayClient(
    http.StreamedResponse Function() detail,
  ) {
    return FakeHttpClient((http.BaseRequest request, int attempt) async {
      final String path = request.url.path;
      if (path == '/v1/reports/$reportId') {
        return detail();
      }
      switch (path) {
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
          return jsonResponse(200, reportsJson());
        default:
          return jsonResponse(200, <String, dynamic>{});
      }
    });
  }

  group('when the latest report will not open', () {
    test('the rest of the day still loads', () async {
      final FakeHttpClient client = dayClient(
        () => problemResponse(500, 'internal-error', 'Something went wrong.'),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final TodayBriefing briefing = await repository.loadToday(clock());

      expect(briefing.displayName, 'Sai Muthiki');
      expect(briefing.hydrationMl, 1200);
      expect(briefing.planRationale, 'A steady day.');
      expect(briefing.lastReportHeadline, contains('Vijaya'));
    });

    test('and says so, rather than showing nothing', () async {
      final FakeHttpClient client = dayClient(
        () => problemResponse(500, 'internal-error', 'Something went wrong.'),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final TodayBriefing briefing = await repository.loadToday(clock());

      // An empty escalation list reads as "nothing found". This is "not checked",
      // and it takes the same non-dismissible card a real finding would.
      expect(briefing.hasEscalation, isTrue);
      expect(briefing.escalations, hasLength(1));
      final EscalationNotice notice = briefing.escalations.single;
      expect(notice.id, 'report-findings-unchecked');
      expect(notice.title, Wire.uncheckedTitle);
      expect(notice.body, contains('not checked'));
      expect(notice.steps, isNotEmpty);
      // Nothing the server wrote is on the card.
      expect(notice.body, isNot(contains('Something went wrong')));
    });

    test('a timeout is treated the same way as a 500', () async {
      final FakeHttpClient client = dayClient(
        () => problemResponse(503, 'not-ready', 'Still starting up.'),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final TodayBriefing briefing = await repository.loadToday(clock());

      expect(briefing.escalations.single.title, Wire.uncheckedTitle);
    });

    test('the notice is never written to the cache', () async {
      final FakeHttpClient client = dayClient(
        () => problemResponse(500, 'internal-error', 'Something went wrong.'),
      );
      final MemoryOfflineCache cache = MemoryOfflineCache();
      final HttpHealthRepository repository = buildRepository(client, cache);

      await repository.loadToday(clock());

      final Cached<Map<String, dynamic>>? stored =
          await cache.read(OfflineCache.plan);
      expect(stored, isNotNull);
      // Same rule as a real red flag: a card about somebody's health now must not be
      // served tomorrow from a copy nobody rechecked.
      expect(asMapList(stored!.value['escalations']), isEmpty);
    });

    test('an expired sign-in is still an expired sign-in', () async {
      // The two failures this must not paper over. A 401 has to stop the app and send
      // the person back to signing in, not become a card about their report.
      final FakeHttpClient client = dayClient(
        () => problemResponse(401, 'not-authenticated', 'Token expired.'),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      await expectLater(
        repository.loadToday(clock()),
        throwsA(isA<HealthRepositoryException>()),
      );
    });
  });

  group('when the latest report opens', () {
    test('its red flags come through exactly as before', () async {
      final FakeHttpClient client = dayClient(
        () => jsonResponse(200, <String, dynamic>{
          'report': <String, dynamic>{
            'id': reportId,
            'status': 'extracted',
            'lab_name': 'Vijaya Diagnostic Centre',
            'file_hash': 'abc123',
          },
          'results': <dynamic>[],
          'red_flags': <dynamic>[
            <String, dynamic>{
              'code': 'CRITICAL_LOW_HB',
              'escalation': 'urgent',
              'message': 'Haemoglobin is 6.2 g/dL, far below our reference range.',
              'biomarker_code': 'HB',
            },
          ],
          'escalation': 'urgent',
        }),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final TodayBriefing briefing = await repository.loadToday(clock());

      expect(briefing.escalations, hasLength(1));
      final EscalationNotice notice = briefing.escalations.single;
      expect(notice.id, 'CRITICAL_LOW_HB');
      expect(notice.title, Wire.urgentTitle);
      expect(notice.body, contains('6.2 g/dL'));
    });

    test('a report with no findings leaves the day with no cards', () async {
      final FakeHttpClient client = dayClient(
        () => jsonResponse(200, <String, dynamic>{
          'report': <String, dynamic>{
            'id': reportId,
            'status': 'extracted',
            'file_hash': 'abc123',
          },
          'results': <dynamic>[],
          'red_flags': <dynamic>[],
        }),
      );
      final HttpHealthRepository repository =
          buildRepository(client, MemoryOfflineCache());

      final TodayBriefing briefing = await repository.loadToday(clock());

      expect(briefing.escalations, isEmpty);
      expect(briefing.hasEscalation, isFalse);
    });
  });
}

/// Signed in, and unable to renew: a 401 is a real sign-out here.
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
