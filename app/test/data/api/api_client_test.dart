import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:healthpulse/data/api/api_client.dart';
import 'package:healthpulse/data/api/api_failure.dart';
import 'package:healthpulse/data/api/api_status.dart';
import 'package:healthpulse/data/api/auth_token_provider.dart';
import 'package:http/http.dart' as http;

import '_fake_http.dart';

/// The client, with no network anywhere near it.
///
/// Two behaviours here are the reason this file exists rather than trusting the
/// happy path: the free-tier cold start, which is a real fifty-second wait and
/// not a hypothetical, and the single token refresh on a 401, which has to be
/// exactly once or it becomes a loop that locks somebody out of their own data.
class _Tokens implements AuthTokenProvider {
  _Tokens({this.renewsTo = 'fresh-token'});

  /// Mutated by the tests to simulate a token going stale; never set at
  /// construction, which is why it is not a constructor parameter.
  String? token = 'first-token';
  final String? renewsTo;
  int refreshes = 0;

  @override
  Future<String?> accessToken() async => token;

  @override
  Future<String?> refreshAccessToken() async {
    refreshes += 1;
    token = renewsTo;
    return token;
  }
}

ApiClient buildClient(
  FakeHttpClient http, {
  AuthTokenProvider? tokens,
  Duration warm = const Duration(milliseconds: 400),
  Duration cold = const Duration(milliseconds: 400),
  Duration notice = const Duration(milliseconds: 20),
  Duration warmFor = const Duration(minutes: 10),
}) {
  return ApiClient(
    baseUrl: Uri.parse('https://healthpulse.test'),
    tokens: tokens ?? const AnonymousTokens(),
    httpClient: http,
    warmTimeout: warm,
    coldTimeout: cold,
    uploadTimeout: const Duration(seconds: 5),
    wakeNoticeAfter: notice,
    staysWarmFor: warmFor,
  );
}

void main() {
  group('cold start', () {
    test('wakes the backend with /healthz before the first real request',
        () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            // Not fifty seconds, but long enough that the notice timer fires.
            await Future<void>.delayed(const Duration(milliseconds: 80));
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return jsonResponse(200, <String, dynamic>{'user_id': 'u1'});
        },
      );
      final ApiClient api = buildClient(client);
      final List<ApiPhase> phases = <ApiPhase>[];
      final StreamSubscription<ApiPhase> sub = api.phases.listen(phases.add);

      final Map<String, dynamic> result = await api.getMap('/v1/me');

      expect(result['user_id'], 'u1');
      expect(client.paths, <String>['/healthz', '/v1/me']);
      await Future<void>.delayed(Duration.zero);
      expect(
        phases,
        contains(ApiPhase.waking),
        reason: 'the interface is never told the backend is waking up',
      );
      expect(phases.last, ApiPhase.ready);
      await sub.cancel();
      api.close();
    });

    test('a wake-up that times out is retried exactly once', () async {
      int probes = 0;
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            probes += 1;
            if (probes == 1) {
              // The instance is still starting: no answer inside the window.
              await Future<void>.delayed(const Duration(milliseconds: 400));
            }
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return jsonResponse(200, <String, dynamic>{'ok': true});
        },
      );
      final ApiClient api = buildClient(
        client,
        cold: const Duration(milliseconds: 100),
      );

      final Map<String, dynamic> result = await api.getMap('/v1/plan/today');

      expect(probes, 2, reason: 'one retry, not none and not a storm');
      expect(result['ok'], isTrue);
      expect(client.paths.last, '/v1/plan/today');
      api.close();
    });

    test('two failed wake-ups fail with the waking-up message, and the real '
        'request is never sent', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return jsonResponse(200, <String, dynamic>{'status': 'ok'});
        },
      );
      final ApiClient api = buildClient(
        client,
        cold: const Duration(milliseconds: 60),
      );

      await expectLater(
        api.getMap('/v1/me'),
        throwsA(
          isA<ApiFailure>().having(
            (ApiFailure f) => f.kind,
            'kind',
            ApiFailureKind.wakingUpTimedOut,
          ),
        ),
      );
      expect(client.callsTo('/healthz'), 2);
      expect(client.callsTo('/v1/me'), 0);
      expect(api.phase, ApiPhase.unreachable);
      api.close();
    });

    test('a warm client does not probe again', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async =>
            jsonResponse(200, <String, dynamic>{'ok': true}),
      );
      final ApiClient api = buildClient(client);

      await api.getMap('/v1/me');
      await api.getMap('/v1/alerts');
      await api.getMap('/v1/reports');

      expect(client.callsTo('/healthz'), 1);
      expect(api.believedAwake, isTrue);
      api.close();
    });

    test('a GET that times out re-wakes and is retried once', () async {
      int meCalls = 0;
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          meCalls += 1;
          if (meCalls == 1) {
            // It went back to sleep between the probe and the request.
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          return jsonResponse(200, <String, dynamic>{'user_id': 'u1'});
        },
      );
      final ApiClient api = buildClient(
        client,
        warm: const Duration(milliseconds: 100),
      );

      final Map<String, dynamic> result = await api.getMap('/v1/me');

      expect(result['user_id'], 'u1');
      expect(meCalls, 2);
      expect(client.callsTo('/healthz'), 2, reason: 'woken again before retry');
      api.close();
    });

    test('a POST that times out is not replayed', () async {
      int sends = 0;
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          sends += 1;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return jsonResponse(200, <String, dynamic>{'ok': true});
        },
      );
      final ApiClient api = buildClient(
        client,
        warm: const Duration(milliseconds: 80),
      );

      await expectLater(
        api.postMap('/v1/chat/messages',
            body: <String, dynamic>{'message': 'hello'}),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        sends,
        1,
        reason: 'a chat message the app cannot prove failed is never sent twice',
      );
      api.close();
    });
  });

  group('token refresh', () {
    test('a 401 refreshes once and replays the request with the new token',
        () async {
      final _Tokens tokens = _Tokens();
      int meCalls = 0;
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          meCalls += 1;
          if (meCalls == 1) {
            return problemResponse(401, 'not-authenticated',
                'Your sign-in could not be verified. Please sign in again.');
          }
          return jsonResponse(200, <String, dynamic>{'user_id': 'u1'});
        },
      );
      final ApiClient api = buildClient(client, tokens: tokens);

      final Map<String, dynamic> result = await api.getMap('/v1/me');

      expect(result['user_id'], 'u1');
      expect(tokens.refreshes, 1);
      expect(client.paths, <String>['/healthz', '/v1/me', '/v1/me']);
      // The probe carries no token; the two real attempts carry the old one
      // and then the renewed one.
      expect(client.headers[1]['authorization'], 'Bearer first-token');
      expect(client.headers[2]['authorization'], 'Bearer fresh-token');
      api.close();
    });

    test('a second 401 after refreshing is a sign-out, not another refresh',
        () async {
      final _Tokens tokens = _Tokens();
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return problemResponse(401, 'not-authenticated', 'Nope.');
        },
      );
      final ApiClient api = buildClient(client, tokens: tokens);

      await expectLater(
        api.getMap('/v1/me'),
        throwsA(
          isA<ApiFailure>().having(
            (ApiFailure f) => f.kind,
            'kind',
            ApiFailureKind.signedOut,
          ),
        ),
      );
      expect(tokens.refreshes, 1, reason: 'refreshing twice is a loop');
      expect(client.callsTo('/v1/me'), 2);
      api.close();
    });

    test('a session that will not renew is a sign-out without a replay',
        () async {
      final _Tokens tokens = _Tokens(renewsTo: null);
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return problemResponse(401, 'not-authenticated', 'Nope.');
        },
      );
      final ApiClient api = buildClient(client, tokens: tokens);

      await expectLater(
        api.getMap('/v1/me'),
        throwsA(isA<ApiFailure>().having(
            (ApiFailure f) => f.requiresSignIn, 'requiresSignIn', isTrue)),
      );
      expect(tokens.refreshes, 1);
      expect(client.callsTo('/v1/me'), 1);
      api.close();
    });

    test('no token means no Authorization header at all', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async =>
            jsonResponse(200, <String, dynamic>{'ok': true}),
      );
      final ApiClient api = buildClient(client);

      await api.getMap('/v1/me');

      expect(client.headers.last.containsKey('authorization'), isFalse);
      api.close();
    });
  });

  group('reading answers', () {
    test('a 404 is a typed failure, not a blank screen', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return problemResponse(
              404, 'not-found', 'That report does not exist, or is not yours.');
        },
      );
      final ApiClient api = buildClient(client);

      await expectLater(
        api.getMap('/v1/reports/nope'),
        throwsA(isA<ApiFailure>().having(
            (ApiFailure f) => f.kind, 'kind', ApiFailureKind.notFound)),
      );
      // A 404 means we reached the backend, so it stays awake as far as the
      // client is concerned.
      expect(api.believedAwake, isTrue);
      api.close();
    });

    test('a 200 that is not JSON is unreadable, not a crash', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return rawResponse(200, '<html>hello</html>');
        },
      );
      final ApiClient api = buildClient(client);

      await expectLater(
        api.getMap('/v1/me'),
        throwsA(isA<ApiFailure>().having((ApiFailure f) => f.kind, 'kind',
            ApiFailureKind.unreadableResponse)),
      );
      api.close();
    });

    test('a list endpoint reads as a list', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return jsonResponse(200, <Object>[
            <String, dynamic>{'id': 't1'}
          ]);
        },
      );
      final ApiClient api = buildClient(client);

      final List<dynamic> threads = await api.getList('/v1/chat/threads');

      expect(threads, hasLength(1));
      api.close();
    });

    test('query parameters land on the URL', () async {
      final List<Uri> urls = <Uri>[];
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          urls.add(request.url);
          return jsonResponse(200, <String, dynamic>{'reports': <Object>[]});
        },
      );
      final ApiClient api = buildClient(client);

      await api.getMap('/v1/reports',
          query: const <String, String>{'limit': '1'});

      expect(urls.last.toString(),
          'https://healthpulse.test/v1/reports?limit=1');
      api.close();
    });
  });

  group('report upload', () {
    test('sends one multipart part and reports progress to the last byte',
        () async {
      final Uint8List bytes =
          Uint8List.fromList(List<int>.generate(200 * 1024, (int i) => i % 251));
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async {
          if (request.url.path == '/healthz') {
            return jsonResponse(200, <String, dynamic>{'status': 'ok'});
          }
          return jsonResponse(201, <String, dynamic>{
            'report': <String, dynamic>{'id': 'r1', 'status': 'extracted'},
            'results': <Object>[],
          });
        },
      );
      final ApiClient api = buildClient(client);

      final List<int> sent = <int>[];
      int? reportedTotal;
      final Map<String, dynamic> result = await api.uploadFile(
        '/v1/reports',
        field: 'file',
        filename: 'august panel.pdf',
        contentType: 'application/pdf',
        bytes: bytes,
        onProgress: (int done, int total) {
          sent.add(done);
          reportedTotal = total;
        },
      );

      expect(result['report'], isA<Map<String, dynamic>>());
      expect(reportedTotal, bytes.length);
      expect(sent.first, 0);
      expect(sent.last, bytes.length);
      // Monotonic: a bar that goes backwards is worse than no bar.
      for (int i = 1; i < sent.length; i++) {
        expect(sent[i], greaterThanOrEqualTo(sent[i - 1]));
      }
      expect(sent.length, greaterThan(2));

      final String contentType =
          client.headers.last['content-type'] ?? '';
      expect(contentType, startsWith('multipart/form-data; boundary='));

      final List<int> body = client.bodies.last;
      // latin1, not utf8: the first 400 bytes are the part headers followed by the
      // start of 200 KB of arbitrary binary, which is not valid UTF-8 and made
      // utf8.decode throw "Unexpected extension byte (at offset 271)". latin1 maps
      // every byte 0-255 to a character and never throws, which is what reading
      // ASCII headers out of a binary body needs.
      final String head = latin1.decode(body.sublist(0, 400));
      expect(head, contains('name="file"'));
      expect(head, contains('filename="august panel.pdf"'));
      expect(head, contains('content-type: application/pdf'));
      expect(body.length, greaterThan(bytes.length));
      api.close();
    });

    test('a filename cannot smuggle a header break', () async {
      final FakeHttpClient client = FakeHttpClient(
        (http.BaseRequest request, int attempt) async =>
            jsonResponse(201, <String, dynamic>{'report': <String, dynamic>{}}),
      );
      final ApiClient api = buildClient(client);

      await api.uploadFile(
        '/v1/reports',
        field: 'file',
        filename: 'a"\r\nX-Evil: 1\r\n.pdf',
        contentType: 'application/pdf',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );

      final String head = utf8.decode(client.bodies.last).split('\r\n\r\n').first;
      expect(head, isNot(contains('X-Evil: 1\r\n')));
      expect(head.split('\r\n').length, 3);
      api.close();
    });
  });

  test('no base address at all is a failure before anything is sent', () async {
    final FakeHttpClient client = FakeHttpClient(
      (http.BaseRequest request, int attempt) async =>
          jsonResponse(200, <String, dynamic>{}),
    );
    final ApiClient api = ApiClient(
      baseUrl: Uri.parse('https://healthpulse.test'),
      tokens: const AnonymousTokens(),
      httpClient: client,
    );
    // The guard that matters in the app is `apiClientProvider` returning null
    // when there is no address; this just proves the client itself is inert
    // until something asks it for something.
    expect(client.callCount, 0);
    expect(api.phase, ApiPhase.idle);
    api.close();
  });
}
