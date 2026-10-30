import 'dart:async';
import 'dart:convert';

import 'package:proxycept_logging/proxycept_logging.dart';
import 'package:proxycept_logging/src/engine.dart';
import 'package:proxycept_logging/src/storage.dart';
import 'package:proxycept_logging/src/transport.dart';

class FakeClock {
  DateTime now = DateTime.utc(2026, 10, 30, 12);
  void advance(Duration delta) {
    now = now.add(delta);
  }
}

class MemoryStorage implements SpoolStorage {
  String? value;
  bool fail = false, closed = false;
  Completer<void>? gate;
  final writes = <String>[];
  int active = 0, maxActive = 0;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String snapshot) async {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (fail) throw StateError('Storage unavailable');
      if (gate != null) await gate!.future;
      value = snapshot;
      writes.add(snapshot);
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class FakeTransport implements LogTransport {
  final requests = <Map<String, dynamic>>[];
  Future<TransportResponse> Function(Map<String, dynamic>)? handler;
  bool closed = false;
  TransportResponse ack(Map<String, dynamic> batch, {bool duplicate = false}) =>
      TransportResponse(
        200,
        jsonEncode({
          'accepted': duplicate ? 0 : (batch['events'] as List).length,
          'duplicate': duplicate ? (batch['events'] as List).length : 0,
          'received_at': '2026-10-30T12:00:00Z',
        }),
      );
  @override
  Future<TransportResponse> post(
    Uri origin,
    String credential,
    List<int> body,
  ) async {
    final batch = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(body)) as Map,
    );
    requests.add(batch);
    return handler == null ? ack(batch) : await handler!(batch);
  }

  @override
  void close() {
    closed = true;
  }
}

LoggingConfiguration configuration({
  int count = 2000,
  int bytes = 2 * 1024 * 1024,
  String token = 'plog_ingest_test_credential_never_persist',
  Uri? origin,
}) => LoggingConfiguration(
  baseUrl: origin ?? Uri.parse('https://logs.example.test'),
  ingestToken: token,
  appVersion: '1.0',
  build: '12',
  debugSessionId: 'session-test',
  queueEvents: count,
  queueBytes: bytes,
);

class Harness {
  final clock = FakeClock();
  final store = MemoryStorage();
  final transport = FakeTransport();
  late final LoggingEngine engine;
  Harness({int count = 2000, int bytes = 2 * 1024 * 1024}) {
    engine = LoggingEngine(
      configuration(count: count, bytes: bytes),
      store,
      transport,
      clock: () => clock.now,
      jitter: () => .5,
    );
  }
  Future<void> init() => engine.initialize();
  bool log({String message = 'Hello', Map<String, Object?> attrs = const {}}) =>
      engine.enqueue(LogLevel.info, 'checkout', message, attrs, null);
}
