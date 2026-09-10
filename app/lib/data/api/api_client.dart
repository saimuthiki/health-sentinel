import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_failure.dart';
import 'api_status.dart';
import 'auth_token_provider.dart';

/// The one place this app talks to the network.
///
/// Three things make it more than a wrapper around [http.Client]:
///
/// **It knows the backend goes to sleep.** The health engine runs on Render's
/// free tier, which stops an instance after about fifteen minutes of quiet and
/// starts it again on the next request. That start takes roughly fifty seconds.
/// A normal twenty-second timeout turns every first-open-of-the-day into a
/// failure, and a sixty-second timeout on *every* request turns a genuinely
/// broken network into a minute of staring. So the client keeps track of whether
/// it believes the backend is awake, and when it does not, it wakes it with an
/// unauthenticated `GET /healthz` — cheap, safe to repeat, and safe to abandon —
/// on a long timeout, retried once, before the real request goes anywhere near
/// the wire. That is also what makes "waking up the health engine" an honest
/// thing to put on screen rather than a guess: [phases] emits [ApiPhase.waking]
/// only while a real wake-up is genuinely in progress.
///
/// Waking first, rather than retrying the real request, is deliberate. Retrying
/// a `POST /v1/chat/messages` that timed out can send the same message twice,
/// and the app cannot tell a request that never arrived from one that arrived
/// and answered slowly. A probe has no such problem.
///
/// **It knows tokens expire.** A 401 is refreshed once through
/// [AuthTokenProvider] and the request is replayed once. A second 401 is a real
/// sign-out, not a retry loop.
///
/// **It never repeats what the server said.** Errors become [ApiFailure], which
/// carries a sentence this app wrote. See `api_failure.dart` for why.
class ApiClient {
  ApiClient({
    required Uri baseUrl,
    required AuthTokenProvider tokens,
    http.Client? httpClient,
    this.warmTimeout = const Duration(seconds: 20),
    this.coldTimeout = const Duration(seconds: 60),
    this.uploadTimeout = const Duration(seconds: 120),
    this.generationTimeout = const Duration(seconds: 90),
    this.wakeNoticeAfter = const Duration(seconds: 2),
    this.staysWarmFor = const Duration(minutes: 10),
    DateTime Function()? clock,
  })  : _base = baseUrl,
        _tokens = tokens,
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _now = clock ?? DateTime.now;

  final Uri _base;
  final AuthTokenProvider _tokens;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;

  /// How long a request may take once we believe the backend is awake.
  final Duration warmTimeout;

  /// How long a wake-up probe may take. Render's cold start is around fifty
  /// seconds, so this has to be longer than that or it can never succeed.
  final Duration coldTimeout;

  /// Uploads carry up to twenty megabytes over a phone connection.
  final Duration uploadTimeout;

  /// For requests that run a model rather than read a row.
  ///
  /// GET /v1/plan/today generates the day's plan on first read: a Gemini call
  /// over the whole profile, then the safety pass, and a regeneration if that
  /// pass rejects the first answer. That is ordinary work measured in tens of
  /// seconds, and the twenty-second [warmTimeout] written for reading a row
  /// turned it into "The health engine did not answer in time" every time.
  final Duration generationTimeout;

  /// How long a wake-up has to be taking before the interface mentions it. A
  /// backend that was only briefly idle answers in a second and says nothing.
  final Duration wakeNoticeAfter;

  /// How long a success is taken as proof the instance is still up. Render's
  /// idle window is fifteen minutes; ten leaves room to be wrong.
  final Duration staysWarmFor;

  final StreamController<ApiPhase> _phases =
      StreamController<ApiPhase>.broadcast();

  ApiPhase _phase = ApiPhase.idle;
  DateTime? _lastReached;
  bool _closed = false;

  /// The current phase, for a widget built before the first event arrives.
  ApiPhase get phase => _phase;

  /// Changes to [phase]. Broadcast, so several screens may listen.
  Stream<ApiPhase> get phases => _phases.stream;

  /// True when a success is recent enough that the instance is probably still up.
  bool get believedAwake {
    final DateTime? last = _lastReached;
    return last != null && _now().difference(last) < staysWarmFor;
  }

  // --------------------------------------------------------------- requests

  Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, String>? query,
    /// Set for a request that runs a model. Defaults to reading-a-row speed.
    bool generates = false,
  }) async {
    return _asMap(await _json(() => http.Request('GET', _uri(path, query)),
        timeout: generates ? generationTimeout : warmTimeout,
        retryWhenCold: true));
  }

  Future<List<dynamic>> getList(
    String path, {
    Map<String, String>? query,
  }) async {
    return _asList(await _json(() => http.Request('GET', _uri(path, query)),
        timeout: warmTimeout, retryWhenCold: true));
  }

  /// A POST is **not** replayed on a timeout. See the class comment.
  Future<Map<String, dynamic>> postMap(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    return _asMap(await _json(() => _withBody('POST', _uri(path, query), body),
        timeout: warmTimeout, retryWhenCold: false));
  }

  /// A PUT replaces, so replaying one is safe.
  Future<Map<String, dynamic>> putMap(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    return _asMap(await _json(() => _withBody('PUT', _uri(path, query), body),
        timeout: warmTimeout, retryWhenCold: true));
  }

  Future<Map<String, dynamic>> patchMap(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    return _asMap(await _json(() => _withBody('PATCH', _uri(path, query), body),
        timeout: warmTimeout, retryWhenCold: true));
  }

  /// Send one file as `multipart/form-data`, reporting bytes handed to the
  /// socket as they go.
  ///
  /// [onProgress] is called with `(sent, total)` where `total` is the file
  /// itself, not the envelope around it — that is the number a person can
  /// recognise as their photo. It is progress *out of this phone*: the backend
  /// still has to read the report afterwards, which is why the upload screen
  /// says "sending" for this part and "reading it" for the wait after.
  ///
  /// Safe to replay on a cold start, unusually for a POST: `app/api/reports.py`
  /// hashes the bytes and answers a file it has already seen from the stored
  /// extraction instead of reading it a second time.
  Future<Map<String, dynamic>> uploadFile(
    String path, {
    required String field,
    required String filename,
    required String contentType,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    final Object? decoded = await _json(
      () => MultipartUpload(
        _uri(path),
        field: field,
        filename: filename,
        contentType: contentType,
        bytes: bytes,
        onProgress: onProgress,
      ),
      timeout: uploadTimeout,
      retryWhenCold: true,
    );
    return _asMap(decoded);
  }

  // ------------------------------------------------------------------ guts

  /// Wake if needed, send, refresh a 401 once, decode.
  Future<Object?> _json(
    http.BaseRequest Function() build, {
    required Duration timeout,
    required bool retryWhenCold,
  }) async {
    await _ensureAwake();
    _emit(ApiPhase.working);

    http.Response response;
    try {
      response = await _sendOnce(build(), timeout);
    } on ApiFailure catch (failure) {
      final bool couldBeSleep = failure.kind == ApiFailureKind.timeout ||
          failure.kind == ApiFailureKind.offline;
      if (!retryWhenCold || !couldBeSleep) {
        _emit(ApiPhase.unreachable);
        rethrow;
      }
      // It may have gone back to sleep between the probe and the request, or
      // the probe may never have run because we thought it was warm. Wake it
      // properly and give the request exactly one more go.
      _lastReached = null;
      await _ensureAwake();
      response = await _sendOnce(build(), timeout);
    }

    if (response.statusCode == 401) {
      final String? refreshed = await _tokens.refreshAccessToken();
      if (refreshed == null || refreshed.isEmpty) {
        _markReached();
        throw const ApiFailure(ApiFailureKind.signedOut, status: 401);
      }
      response = await _sendOnce(build(), timeout);
      if (response.statusCode == 401) {
        // A fresh token was rejected too. Refreshing again would be a loop.
        _markReached();
        throw const ApiFailure(ApiFailureKind.signedOut, status: 401);
      }
    }

    return _decode(response);
  }

  Future<http.Response> _sendOnce(
    http.BaseRequest request,
    Duration timeout,
  ) async {
    final String? token = await _tokens.accessToken();
    request.headers['accept'] = 'application/json';
    if (token != null && token.isNotEmpty) {
      request.headers['authorization'] = 'Bearer $token';
    }
    try {
      final http.StreamedResponse streamed =
          await _client.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const ApiFailure(ApiFailureKind.timeout);
    } on http.ClientException {
      throw const ApiFailure(ApiFailureKind.offline);
    } on ApiFailure {
      rethrow;
    } on Exception {
      // Anything else that came off a socket. We do not know what it was and we
      // are certainly not showing it to anybody.
      throw const ApiFailure(ApiFailureKind.offline);
    }
  }

  /// Bring the instance up before anything that matters is sent.
  Future<void> _ensureAwake() async {
    if (believedAwake) {
      return;
    }
    bool done = false;
    final Timer notice = Timer(wakeNoticeAfter, () {
      if (!done) {
        _emit(ApiPhase.waking);
      }
    });
    try {
      ApiFailure last = const ApiFailure(ApiFailureKind.wakingUpTimedOut);
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          final http.Response probe = await _client.get(
            _uri('/healthz'),
            headers: const <String, String>{'accept': 'application/json'},
          ).timeout(coldTimeout);
          if (probe.statusCode < 500) {
            _markReached();
            return;
          }
          // 502 and 503 are what a platform returns while it is still starting.
          last = const ApiFailure(ApiFailureKind.wakingUpTimedOut, status: 503);
        } on TimeoutException {
          last = const ApiFailure(ApiFailureKind.wakingUpTimedOut);
        } on Exception {
          last = const ApiFailure(ApiFailureKind.offline);
        }
      }
      _emit(ApiPhase.unreachable);
      throw last;
    } finally {
      done = true;
      notice.cancel();
    }
  }

  Object? _decode(http.Response response) {
    // We reached it either way: a 404 is not a connectivity problem, and saying
    // "you are offline" over one would be a lie.
    _markReached();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiFailure.fromResponse(
        response.statusCode,
        response.bodyBytes,
        retryAfterHeader: response.headers['retry-after'],
      );
    }
    if (response.bodyBytes.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw ApiFailure(
        ApiFailureKind.unreadableResponse,
        status: response.statusCode,
      );
    }
  }

  Map<String, dynamic> _asMap(Object? decoded) {
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    throw const ApiFailure(ApiFailureKind.unreadableResponse);
  }

  List<dynamic> _asList(Object? decoded) {
    if (decoded is List) {
      return decoded;
    }
    throw const ApiFailure(ApiFailureKind.unreadableResponse);
  }

  http.Request _withBody(String method, Uri url, Object? body) {
    final http.Request request = http.Request(method, url);
    if (body != null) {
      request.headers['content-type'] = 'application/json; charset=utf-8';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }
    return request;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final String basePath = _base.path.endsWith('/')
        ? _base.path.substring(0, _base.path.length - 1)
        : _base.path;
    final String tail = path.startsWith('/') ? path : '/$path';
    return _base.replace(
      path: '$basePath$tail',
      queryParameters:
          (query == null || query.isEmpty) ? null : query,
    );
  }

  void _markReached() {
    _lastReached = _now();
    _emit(ApiPhase.ready);
  }

  void _emit(ApiPhase next) {
    if (_closed || next == _phase) {
      return;
    }
    _phase = next;
    if (!_phases.isClosed) {
      _phases.add(next);
    }
  }

  /// Forget that the backend was ever reached, so the next request wakes it.
  /// Used after a long spell in the background.
  void assumeAsleep() {
    _lastReached = null;
  }

  void close() {
    _closed = true;
    if (_ownsClient) {
      _client.close();
    }
    _phases.close();
  }
}

/// One file as `multipart/form-data`, with the bytes counted on the way out.
///
/// Written by hand rather than with [http.MultipartRequest] for one reason:
/// `MultipartRequest` gives no way to observe the body being read, and a
/// twenty-megabyte upload from a phone with a bar of signal needs a progress
/// bar or it looks frozen. Everything else about it is the same wire format.
class MultipartUpload extends http.BaseRequest {
  MultipartUpload(
    Uri url, {
    required this.field,
    required this.filename,
    required this.contentType,
    required this.bytes,
    this.onProgress,
    String? boundary,
  })  : _boundary = boundary ?? _newBoundary(),
        super('POST', url) {
    headers['content-type'] = 'multipart/form-data; boundary=$_boundary';
    _head = utf8.encode(
      '--$_boundary\r\n'
      'content-disposition: form-data; name="$field"; '
      'filename="${_safeName(filename)}"\r\n'
      'content-type: $contentType\r\n'
      '\r\n',
    );
    _tail = utf8.encode('\r\n--$_boundary--\r\n');
    contentLength = _head.length + bytes.length + _tail.length;
  }

  /// The form field name. `app/api/reports.py` calls it `file`.
  final String field;
  final String filename;
  final String contentType;
  final Uint8List bytes;
  final void Function(int sent, int total)? onProgress;

  final String _boundary;
  late final List<int> _head;
  late final List<int> _tail;

  /// 64 KiB at a time: small enough that the bar moves on a slow connection,
  /// large enough that a 20 MB file is not 20 000 callbacks.
  static const int chunkSize = 64 * 1024;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body());
  }

  Stream<List<int>> _body() async* {
    final int total = bytes.length;
    onProgress?.call(0, total);
    yield _head;
    int offset = 0;
    while (offset < total) {
      final int end = offset + chunkSize < total ? offset + chunkSize : total;
      yield Uint8List.sublistView(bytes, offset, end);
      offset = end;
      onProgress?.call(offset, total);
    }
    yield _tail;
  }

  /// A filename is attacker-influenced text going into a header. Quotes and
  /// line breaks come out; the rest is the user's own file name.
  static String _safeName(String raw) {
    final String cleaned =
        raw.replaceAll(RegExp(r'[\r\n"\\]'), '').trim();
    return cleaned.isEmpty ? 'report' : cleaned;
  }

  static int _counter = 0;

  static String _newBoundary() {
    _counter += 1;
    final int stamp = DateTime.now().microsecondsSinceEpoch;
    return '----healthpulse$stamp$_counter';
  }
}
