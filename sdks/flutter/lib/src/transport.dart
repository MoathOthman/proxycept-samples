import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

class TransportResponse {
  final int status;
  final String body;
  final String? retryAfter;
  TransportResponse(this.status, this.body, {this.retryAfter});
}

abstract interface class LogTransport {
  Future<TransportResponse> post(Uri origin, String credential, List<int> body);
  void close();
}

/// One request at a time; no redirects/cookies/proxy credentials, bounded response.
class IoLogTransport implements LogTransport {
  final Duration timeout;
  HttpClient? _active;
  bool _closed = false;
  IoLogTransport({this.timeout = const Duration(seconds: 30)});
  @override
  Future<TransportResponse> post(
    Uri origin,
    String credential,
    List<int> body,
  ) async {
    validateOrigin(origin);
    validateToken(credential);
    if (_closed || body.length > maxBatchBytes)
      throw StateError('Transport unavailable');
    final client = HttpClient()..autoUncompress = false;
    client.connectionTimeout = timeout;
    client.findProxy = (_) => 'DIRECT';
    _active = client;
    Future<TransportResponse> send() async {
      final request = await client.postUrl(origin.resolve('/api/logs/ingest'));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $credential',
      );
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding.toLowerCase() != 'identity')
        throw const FormatException('Encoded response refused');
      if (response.contentLength > 65536)
        throw const FormatException('Response too large');
      final result = BytesBuilder(copy: false);
      await for (final chunk in response) {
        if (result.length + chunk.length > 65536)
          throw const FormatException('Response too large');
        result.add(chunk);
      }
      return TransportResponse(
        response.statusCode,
        utf8.decode(result.takeBytes()),
        retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
      );
    }

    try {
      return await send().timeout(timeout);
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  @override
  void close() {
    _closed = true;
    _active?.close(force: true);
  }
}
