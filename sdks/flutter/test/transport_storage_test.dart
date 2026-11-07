import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxycept_logging/proxycept_logging.dart';
import 'package:proxycept_logging/src/storage.dart';
import 'package:proxycept_logging/src/transport.dart';

void main() {
  test('origin/token security accepts numeric loopback only for cleartext', () {
    for (final address in [
      'http://localhost:18880',
      'http://10.0.2.2:18880',
      'https://user:pass@example.com',
      'https://example.com/path',
      'https://example.com?x=1',
      'https://example.com#fragment',
    ]) {
      expect(
        () => LoggingConfiguration(
          baseUrl: Uri.parse(address),
          ingestToken: 'plog_ingest_test',
          appVersion: '1',
          build: '1',
        ),
        throwsArgumentError,
      );
    }
    for (final address in [
      'http://127.0.0.1:18880',
      'http://[::1]:18880',
      'https://example.com',
    ]) {
      expect(
        LoggingConfiguration(
          baseUrl: Uri.parse(address),
          ingestToken: 'plog_ingest_test',
          appVersion: '1',
          build: '1',
        ),
        isNotNull,
      );
    }
  });
  test('real loopback POST and both same/cross-origin redirects never forward token', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var targetHits = 0, originHits = 0, code = 200;
    final seen = <String>[];
    final subTarget = target.listen((r) async {
      targetHits++;
      r.response.statusCode = 200;
      await r.response.close();
    });
    final subOrigin = origin.listen((r) async {
      originHits++;
      seen.add(r.headers.value(HttpHeaders.authorizationHeader) ?? '');
      expect(r.uri.path, '/api/logs/ingest');
      expect(r.method, 'POST');
      final json = jsonDecode(await utf8.decoder.bind(r).join());
      expect(json['events'], isEmpty);
      r.response.statusCode = code;
      if (code != 200)
        r.response.headers.set(
          HttpHeaders.locationHeader,
          code == 307
              ? 'http://127.0.0.1:${target.port}/stolen'
              : '/same-origin-stolen',
        );
      r.response.write(
        '{"accepted":0,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}',
      );
      await r.response.close();
    });
    final transport = IoLogTransport();
    try {
      for (final status in [200, 307, 302]) {
        code = status;
        final response = await transport.post(
          Uri.parse('http://127.0.0.1:${origin.port}'),
          'plog_ingest_test',
          utf8.encode('{"events":[]}'),
        );
        expect(response.status, status);
      }
      expect(originHits, 3);
      expect(targetHits, 0);
      expect(seen.toSet(), {'Bearer plog_ingest_test'});
    } finally {
      transport.close();
      await origin.close(force: true);
      await target.close(force: true);
      await subOrigin.cancel();
      await subTarget.cancel();
    }
  });
  test(
    'real loopback streamed responses are capped and timeout closes requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((r) async {
        await r.drain<void>();
        r.response.headers.chunkedTransferEncoding = true;
        r.response.write('x' * 65537);
        await r.response.close();
      });
      final transport = IoLogTransport(timeout: const Duration(seconds: 2));
      try {
        await expectLater(
          transport.post(
            Uri.parse('http://127.0.0.1:${server.port}'),
            'plog_ingest_test',
            [],
          ),
          throwsFormatException,
        );
      } finally {
        transport.close();
        await server.close(force: true);
        await subscription.cancel();
      }
    },
  );
  test(
    'real private storage atomic recovery and exclusive ownership across opens',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'proxycept-dart-test-',
      );
      FileSpoolStorage? storage;
      try {
        storage = await FileSpoolStorage.open(directory.path);
        await storage.write('{"version":1}');
        expect(await storage.read(), '{"version":1}');
        await expectLater(
          FileSpoolStorage.open(directory.path),
          throwsStateError,
        );
        expect(await storage.read(), '{"version":1}');
        await storage.close();
        storage = await FileSpoolStorage.open(directory.path);
        expect(await storage.read(), '{"version":1}');
        expect(await File('${directory.path}/queue.tmp').exists(), isFalse);
        expect(
          (await File('${directory.path}/queue.json').stat()).mode & 511,
          384,
        );
        expect((await directory.stat()).mode & 511, 448);
      } finally {
        await storage?.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'storage rejects symlink queue and oversized corrupt file is bounded',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'proxycept-dart-link-',
      );
      final outside = await File('${directory.path}/outside')
          .writeAsString('sensitive');
      try {
        final link = Link('${directory.path}/queue.json');
        await link.create(outside.path);
        await expectLater(
          FileSpoolStorage.open(directory.path),
          throwsStateError,
        );
        await link.delete();
        final file = await File('${directory.path}/queue.json')
            .open(mode: FileMode.write);
        await file.truncate(2 * 1024 * 1024 + 1);
        await file.close();
        final storage = await FileSpoolStorage.open(directory.path);
        expect(await storage.read(), '!corrupt');
        await storage.close();
        expect(await outside.readAsString(), 'sensitive');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test('transport absolute deadline aborts a stalled response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((r) {
      unawaited(r.drain<void>().catchError((Object _) {}));
    });
    final transport = IoLogTransport(timeout: const Duration(milliseconds: 50));
    try {
      await expectLater(
        transport.post(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'plog_ingest_test',
          [],
        ),
        throwsA(isA<TimeoutException>()),
      );
    } finally {
      transport.close();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
  test('transport refuses compressed replies before decompression', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((r) async {
      await r.drain<void>();
      r.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      r.response.add(gzip.encode(utf8.encode('x' * 1000000)));
      await r.response.close();
    });
    final transport = IoLogTransport();
    try {
      await expectLater(
        transport.post(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'plog_ingest_test',
          [],
        ),
        throwsFormatException,
      );
    } finally {
      transport.close();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}
