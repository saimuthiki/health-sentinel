import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// An [http.Client] that answers from a function and remembers everything.
///
/// No test in this suite touches a socket. This is the only thing standing in
/// for one, and it is deliberately a real [http.BaseClient] rather than a mock
/// object so that the code under test goes through the same `send`, the same
/// `finalize()` and the same streamed response it will in production — which is
/// what makes the multipart and progress assertions worth anything.
typedef Responder = FutureOr<http.StreamedResponse> Function(
  http.BaseRequest request,
  int attempt,
);

class FakeHttpClient extends http.BaseClient {
  FakeHttpClient(this.responder);

  final Responder responder;

  final List<String> paths = <String>[];
  final List<String> methods = <String>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];
  final List<List<int>> bodies = <List<int>>[];

  int get callCount => paths.length;

  int callsTo(String path) => paths.where((String p) => p == path).length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Draining the body is what a real client does, and it is what makes the
    // upload progress callbacks fire.
    final List<int> body = await request.finalize().toBytes();
    final int attempt = paths.length;
    paths.add(request.url.path);
    methods.add(request.method);
    headers.add(Map<String, String>.from(request.headers));
    bodies.add(body);
    return responder(request, attempt);
  }
}

http.StreamedResponse jsonResponse(
  int status,
  Object body, {
  Map<String, String> extraHeaders = const <String, String>{},
}) {
  final List<int> bytes = utf8.encode(jsonEncode(body));
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    contentLength: bytes.length,
    headers: <String, String>{
      'content-type': 'application/json',
      ...extraHeaders,
    },
  );
}

http.StreamedResponse problemResponse(
  int status,
  String code,
  String detail, {
  Map<String, String> extraHeaders = const <String, String>{},
}) {
  final List<int> bytes = utf8.encode(
    jsonEncode(<String, dynamic>{
      'type': 'https://healthpulse.app/problems/$code',
      'title': 'Something',
      'status': status,
      'detail': detail,
      'instance': '/v1/thing',
      'request_id': '01JTESTREQUESTID',
    }),
  );
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    contentLength: bytes.length,
    headers: <String, String>{
      'content-type': 'application/problem+json',
      ...extraHeaders,
    },
  );
}

http.StreamedResponse rawResponse(
  int status,
  String body, {
  String contentType = 'text/html',
}) {
  final List<int> bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    status,
    contentLength: bytes.length,
    headers: <String, String>{'content-type': contentType},
  );
}
