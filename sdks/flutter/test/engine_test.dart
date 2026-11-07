import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxycept_logging/src/models.dart';
import 'package:proxycept_logging/src/transport.dart';

import 'helpers.dart';

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.init();
  });
  tearDown(() async {
    await h.engine.close();
  });

  final fixture = jsonDecode(
    File('../conformance/attribute-vectors.json').readAsStringSync(),
  ) as Map;
  for (final value in fixture['cases'] as List) {
    final vector = value as Map;
    test('shared scalar vector ${vector['name']}', () async {
      expect(
        h.log(attrs: Map<String, Object?>.from(vector['attributes'] as Map)),
        vector['accepted'],
      );
      await h.engine.persist();
      expect(h.store.value, isNot(contains('fixture-secret-do-not-store')));
      expect(h.store.value, isNot(contains('fixture@example.com')));
    });
  }
  test('mixed valid neighbors survive invalid scalar admission', () async {
    var expected = 0;
    for (final raw in fixture['cases'] as List) {
      final vector = raw as Map;
      if (h.log(attrs: Map<String, Object?>.from(vector['attributes'] as Map)))
        expected++;
      expect(h.log(message: 'valid-neighbor'), isTrue);
      expected++;
    }
    await h.engine.flush();
    expect(h.engine.stats()['accepted'], expected);
    expect(h.engine.stats()['invalid'], 5);
    expect(h.engine.stats()['queued'], 0);
    for (final batch in h.transport.requests) {
      for (final event in batch['events'] as List) {
        expect(
          validAttributes(
            Map<String, Object?>.from(event['attributes'] as Map),
          ),
          isTrue,
        );
      }
    }
  });
  test(
    'legacy spool rejects records individually and rescrubs valid neighbors',
    () async {
      await h.engine.close();
      h = Harness();
      final records = <Map>[];
      var sequence = 0;
      for (final raw in fixture['cases'] as List) {
        for (final attrs in [
          (raw as Map)['attributes'],
          {'screen': 'neighbor'},
        ]) {
          records.add({
            'queued_at': h.clock.now.toIso8601String(),
            'metadata': {
              'app_version': 'old',
              'build': '9',
              'installation_id': 'saved-install',
              'debug_session_id': 'saved-session',
            },
            'event': {
              'event_id': 'saved-${sequence++}',
              'sequence': sequence,
              'client_time': h.clock.now.toIso8601String(),
              'severity': 'info',
              'category': 'legacy',
              'message': 'restored',
              'attributes': attrs,
              'correlation_id': null,
            },
          });
        }
      }
      h.store.value = jsonEncode({
        'version': 1,
        'installation_id': 'saved-install',
        'next_sequence': sequence,
        'records': records,
      });
      await h.init();
      expect(h.engine.stats()['queued'], 15);
      expect(h.engine.stats()['invalid'], 5);
      expect(h.store.value, isNot(contains('fixture-secret-do-not-store')));
      await h.engine.flush();
      expect(h.engine.stats()['accepted'], 15);
      expect(h.transport.requests.first['app_version'], 'old');
      expect(h.transport.requests.first['debug_session_id'], 'saved-session');
    },
  );
  test(
    'redacts credential metadata category values and keys before every write',
    () async {
      final token = configuration().ingestToken;
      expect(
        h.engine.enqueue(
          LogLevel.error,
          token,
          'Bearer private-value user@example.com password=secret $token',
          {'password': 'secret', 'screen': token, 'safe': true},
          token,
        ),
        isTrue,
      );
      await h.engine.persist();
      for (final snapshot in h.store.writes) {
        expect(snapshot, isNot(contains(token)));
        expect(snapshot, isNot(contains('private-value')));
        expect(snapshot, isNot(contains('user@example.com')));
        expect(snapshot, isNot(contains('password=secret')));
      }
    },
  );
  test('unicode scalar limits and bounded UTF8 event bytes', () async {
    expect(h.log(attrs: {'😀' * 64: '😀' * 512}), isTrue);
    expect(h.log(attrs: {'😀' * 65: 'no'}), isFalse);
    expect(h.log(message: '界' * 4096), isFalse);
    expect(h.log(attrs: {'n': double.nan}), isFalse);
    expect(h.log(attrs: {'n': double.infinity}), isFalse);
    expect(h.log(attrs: {'n': 1.00001e308}), isFalse);
    expect(h.log(message: 'normal'), isTrue);
    await h.engine.flush();
    expect(h.engine.stats()['accepted'], 2);
  });
  test(
    'unpaired UTF16 never poisons valid batch neighbors or recovered spool',
    () async {
      final malformed = String.fromCharCode(0xd800);
      expect(h.log(message: malformed), isFalse);
      expect(h.log(attrs: {malformed: 'no'}), isFalse);
      expect(h.log(attrs: {'value': malformed}), isFalse);
      expect(
        h.engine.enqueue(LogLevel.info, malformed, 'no', {}, null),
        isFalse,
      );
      expect(
        h.engine.enqueue(LogLevel.info, 'safe', 'no', {}, malformed),
        isFalse,
      );
      expect(
        () => LoggingConfiguration(
          baseUrl: Uri.parse('https://logs.example.test'),
          ingestToken: 'plog_ingest_test',
          appVersion: malformed,
          build: '1',
        ),
        throwsArgumentError,
      );
      expect(h.log(message: 'valid 😀 neighbor'), isTrue);
      await h.engine.flush();
      expect(h.engine.stats()['accepted'], 1);
      expect(h.store.value, isNot(contains(r'\ud800')));
      expect(h.transport.requests.single['events'], hasLength(1));
    },
  );
  test(
    'count and byte queues drop oldest without exceeding serialized bounds',
    () async {
      await h.engine.close();
      h = Harness(count: 3, bytes: 2048);
      await h.init();
      for (var i = 0; i < 10; i++) {
        h.log(message: 'event-$i');
      }
      await h.engine.persist();
      expect(h.engine.stats()['queued'], lessThanOrEqualTo(3));
      expect(h.engine.stats()['droppedOldest'], greaterThan(0));
      expect(
        utf8.encode(h.store.value!).length,
        h.engine.stats()['queuedBytes'],
      );
      expect(utf8.encode(h.store.value!).length, lessThanOrEqualTo(2048));
      expect(h.store.value, contains('event-9'));
    },
  );
  test('batch count <=50, UTC timestamps and committed drain', () async {
    for (var i = 0; i < 120; i++) {
      expect(h.log(), isTrue);
    }
    await h.engine.flush();
    expect(h.transport.requests.map((b) => (b['events'] as List).length), [
      50,
      50,
      20,
    ]);
    expect(h.engine.stats()['accepted'], 120);
    for (final b in h.transport.requests) {
      expect(
        utf8.encode(jsonEncode(b)).length,
        lessThanOrEqualTo(maxBatchBytes),
      );
      expect(b['schema_version'], 1);
      expect((b['events'] as List).first['client_time'], endsWith('Z'));
    }
  });
  test(
    'lost response stable ID sequence persists through retry and restart',
    () async {
      h.log();
      h.transport.handler = (_) async => throw const SocketException('Offline');
      await h.engine.flush();
      final first = (h.transport.requests.first['events'] as List).first;
      expect(h.engine.stats()['queued'], 1);
      h.clock.advance(const Duration(seconds: 3));
      h.transport.handler = (b) async => h.transport.ack(b, duplicate: true);
      await h.engine.flush();
      final second = (h.transport.requests.last['events'] as List).first;
      expect(second['event_id'], first['event_id']);
      expect(second['sequence'], first['sequence']);
      expect(h.engine.stats()['duplicate'], 1);
    },
  );
  for (final body in [
    '{}',
    '{"accepted":1,"duplicate":0,"received_at":"no"}',
    '{"accepted":1.0,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}',
    '{"accepted":0,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}',
    '{"accepted":1,"duplicate":0,"received_at":"2026-10-30T12:00:00"}',
  ]) {
    test('malformed acknowledgement retains atomic batch $body', () async {
      h.log();
      h.transport.handler = (_) async => TransportResponse(200, body);
      await h.engine.flush();
      expect(h.engine.stats()['queued'], 1);
      expect(h.engine.stats()['failures'], 1);
    });
  }
  test('Retry-After seconds and HTTP date; transient backoff with deterministic jitter', () async {
    h.log();
    h.transport.handler = (_) async =>
        TransportResponse(429, '', retryAfter: '60');
    await h.engine.flush();
    expect(
      h.engine.stats()['nextAttempt'],
      h.clock.now.add(const Duration(seconds: 60)).toIso8601String(),
    );
    await h.engine.flush();
    expect(h.transport.requests.length, 1);
    h.clock.advance(const Duration(seconds: 60));
    final deadline = h.clock.now.add(const Duration(minutes: 2));
    h.transport.handler = (_) async =>
        TransportResponse(429, '', retryAfter: HttpDate.format(deadline));
    await h.engine.flush();
    expect(h.engine.stats()['nextAttempt'], deadline.toIso8601String());
  });
  for (final status in [401, 403]) {
    test('auth $status stops until explicit reconfiguration', () async {
      h.log();
      h.transport.handler = (_) async => TransportResponse(status, '');
      await h.engine.flush();
      expect(h.engine.stats()['authStopped'], isTrue);
      h.clock.advance(const Duration(hours: 1));
      await h.engine.tick();
      expect(h.transport.requests.length, 1);
      expect(h.log(), isFalse);
      h.engine.reconfigure('plog_ingest_replacement');
      h.transport.handler = null;
      await h.engine.flush();
      expect(h.engine.stats()['queued'], 0);
    });
  }
  test('413 splits batch and discards a singly rejected event', () async {
    for (var i = 0; i < 3; i++) {
      h.log();
    }
    h.transport.handler = (b) async => (b['events'] as List).length > 1
        ? TransportResponse(413, '')
        : h.transport.ack(b);
    await h.engine.flush();
    expect(h.engine.stats()['accepted'], 3);
    h.log();
    h.transport.handler = (_) async => TransportResponse(413, '');
    await h.engine.flush();
    expect(h.engine.stats()['rejected'], 1);
    expect(h.engine.stats()['queued'], 0);
  });
  test(
    'storage failure prevents send and remains observable/retryable',
    () async {
      h.store.fail = true;
      h.log();
      await h.engine.flush();
      expect(h.transport.requests, isEmpty);
      expect(h.engine.stats()['storageFailures'], greaterThan(0));
      h.store.fail = false;
      await h.engine.flush();
      expect(h.engine.stats()['accepted'], 1);
    },
  );
  test(
    'expiry works during auth suspension and background without delivery',
    () async {
      h.log();
      h.transport.handler = (_) async => TransportResponse(401, '');
      await h.engine.flush();
      h.engine.setForeground(false);
      h.clock.advance(const Duration(days: 3));
      await h.engine.tick();
      expect(h.engine.stats()['queued'], 0);
      expect(h.engine.stats()['expired'], 1);
      expect(h.transport.requests.length, 1);
    },
  );
  test(
    'disable barrier beats blocked older storage and stale network completion',
    () async {
      h.log();
      final entered = Completer<void>(),
          response = Completer<TransportResponse>();
      h.transport.handler = (_) {
        entered.complete();
        return response.future;
      };
      final sending = h.engine.flush();
      await entered.future;
      h.store.gate = Completer<void>();
      final clearing = h.engine.disable();
      await Future<void>.delayed(Duration.zero);
      expect(h.store.active, 1);
      h.store.gate!.complete();
      await clearing;
      expect((jsonDecode(h.store.value!)['records'] as List), isEmpty);
      h.engine.reconfigure('plog_ingest_rotated');
      h.log(message: 'new-generation');
      await h.engine.persist();
      response.complete(
        TransportResponse(
          200,
          '{"accepted":1,"duplicate":0,"received_at":"2026-10-30T12:00:00Z"}',
        ),
      );
      await sending;
      expect(h.engine.stats()['queued'], 1);
      expect(h.store.value, contains('new-generation'));
      expect(h.store.maxActive, 1);
      h.transport.handler = null;
      await h.engine.flush();
      expect(h.engine.stats()['accepted'], 1);
    },
  );
  test('corrupt spool resets safely and recovery expires old data', () async {
    await h.engine.close();
    h = Harness();
    h.store.value = '{broken';
    await h.init();
    expect(h.engine.stats()['invalid'], 1);
    expect(h.engine.stats()['queued'], 0);
    h.log();
    await h.engine.persist();
    final snapshot = h.store.value;
    await h.engine.close();
    h = Harness();
    h.store.value = snapshot;
    h.clock.advance(const Duration(days: 4));
    await h.init();
    expect(h.engine.stats()['expired'], 1);
    expect(h.engine.stats()['queued'], 0);
  });
  test(
    'foreground controls automatic ticks; explicit flush is available inactive',
    () async {
      h.engine.setForeground(false);
      h.log();
      await h.engine.tick();
      expect(h.transport.requests, isEmpty);
      await h.engine.flush();
      expect(h.engine.stats()['accepted'], 1);
    },
  );
  for (final field in [
    'message',
    'category',
    'event_id',
    'correlation_id',
    'attribute-key',
    'attribute-value',
    'app_version',
    'debug_session_id',
  ]) {
    test(
      'legacy malformed UTF16 $field leaves a valid neighbor deliverable',
      () async {
        await h.engine.close();
        h = Harness();
        final malformed = String.fromCharCode(0xd800);
        Map<String, Object?> record(String id) => {
          'queued_at': h.clock.now.toIso8601String(),
          'metadata': {
            'app_version': '1',
            'build': '1',
            'installation_id': 'saved-install',
            'debug_session_id': 'saved-session',
          },
          'event': {
            'event_id': id,
            'sequence': 1,
            'client_time': h.clock.now.toIso8601String(),
            'severity': 'info',
            'category': 'legacy',
            'message': 'neighbor',
            'attributes': <String, Object?>{},
            'correlation_id': null,
          },
        };
        final bad = record('bad'), good = record('good');
        final malformedEvent = bad['event'] as Map;
        if (field == 'attribute-key') {
          malformedEvent['attributes'] = {malformed: 'no'};
        } else if (field == 'attribute-value') {
          malformedEvent['attributes'] = {'value': malformed};
        } else if (field == 'app_version' || field == 'debug_session_id') {
          (bad['metadata'] as Map)[field] = malformed;
        } else {
          malformedEvent[field] = malformed;
        }
        h.store.value = jsonEncode({
          'version': 1,
          'installation_id': 'saved-install',
          'next_sequence': 2,
          'records': [bad, good],
        });
        await h.init();
        expect(h.engine.stats()['invalid'], 1);
        expect(h.engine.stats()['queued'], 1);
        await h.engine.flush();
        expect(h.engine.stats()['accepted'], 1);
        expect(jsonEncode(h.transport.requests), isNot(contains(r'\ud800')));
      },
    );
  }
  test('failed final persistence is observable but still closes transport and storage', () async {
    h.log();
    h.store.fail = true;
    await expectLater(h.engine.close(), throwsStateError);
    expect(h.store.closed, isTrue);
    expect(h.transport.closed, isTrue);
  });
}
