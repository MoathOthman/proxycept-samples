import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxycept_logging/proxycept_logging.dart';

void main() {
  test('public isolated client admits bounded work, redacts, commits, and releases spool', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = await Directory.systemTemp.createTemp(
      'proxycept-isolate-test-',
    );
    final bodies = <Map>[];
    final subscription = server.listen((request) async {
      final batch = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      bodies.add(batch);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'accepted': (batch['events'] as List).length,
          'duplicate': 0,
          'received_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await request.response.close();
    });
    final config = LoggingConfiguration(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      ingestToken: 'plog_ingest_isolated_test_key',
      appVersion: '1',
      build: '1',
    );
    final spool = PrivateSpool.hostProvided(
      directory.path,
      protectionConfirmed: true,
    );
    ProxyceptLogger? logger;
    try {
      logger = await ProxyceptLogger.open(config, spool: spool);
      await expectLater(
        ProxyceptLogger.open(config, spool: spool),
        throwsStateError,
      );
      var admitted = 0;
      for (var i = 0; i < 100; i++) {
        if (logger.log(
          level: LogLevel.info,
          category: 'test',
          message: 'event-$i',
          attributes: {'password': 'never-on-disk'},
        ))
          admitted++;
      }
      expect(admitted, 32);
      await logger.flush();
      final stats = await logger.stats();
      expect(stats.accepted, 32);
      expect(stats.admissionDropped, 68);
      expect(stats.queued, 0);
      expect(jsonEncode(bodies), isNot(contains('never-on-disk')));
      expect(
        await File('${directory.path}/queue.json').readAsString(),
        isNot(contains(config.ingestToken)),
      );
      await logger.disable();
      expect(
        logger.log(level: LogLevel.info, category: 'test', message: 'disabled'),
        isFalse,
      );
      await logger.close();
      logger = await ProxyceptLogger.open(config, spool: spool);
      expect((await logger.stats()).queued, 0);
    } finally {
      await logger?.close();
      await server.close(force: true);
      await subscription.cancel();
      await directory.delete(recursive: true);
    }
  });
  for (final purge in [false, true]) {
    test(
      'eight saturated controls cannot reject ${purge ? "privacy purge" : "shutdown"}; spool reopens',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'proxycept-saturation-',
        );
        final config = LoggingConfiguration(
          baseUrl: Uri.parse('http://127.0.0.1:1'),
          ingestToken: 'plog_ingest_saturation',
          appVersion: '1',
          build: '1',
        );
        final spool = PrivateSpool.hostProvided(
          directory.path,
          protectionConfirmed: true,
        );
        ProxyceptLogger? logger;
        try {
          logger = await ProxyceptLogger.open(config, spool: spool);
          await logger.setForegroundActive(false);
          expect(
            logger.log(
              level: LogLevel.info,
              category: 'close',
              message: 'persist-before-release',
            ),
            isTrue,
          );
          // No await: all eight RPCs occupy their slots until the UI event loop yields.
          final saturated = List.generate(8, (_) => logger!.stats());
          Future<bool>? purged;
          if (purge) purged = logger.disable();
          final closed = logger.close();
          expect(
            logger.log(
              level: LogLevel.info,
              category: 'close',
              message: 'too-late',
            ),
            isFalse,
          );
          await expectLater(logger.stats(), throwsStateError);
          await Future.wait(saturated);
          if (purged != null) expect(await purged, isTrue);
          await closed;
          logger = await ProxyceptLogger.open(config, spool: spool);
          await logger.setForegroundActive(false);
          expect((await logger.stats()).queued, purge ? 0 : 1);
        } finally {
          await logger?.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test(
    'retaining disable can be upgraded to coalesced purge under saturation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'proxycept-disable-reserve-',
      );
      final config = LoggingConfiguration(
        baseUrl: Uri.parse('http://127.0.0.1:1'),
        ingestToken: 'plog_ingest_disable',
        appVersion: '1',
        build: '1',
      );
      final spool = PrivateSpool.hostProvided(
        directory.path,
        protectionConfirmed: true,
      );
      final logger = await ProxyceptLogger.open(config, spool: spool);
      try {
        await logger.setForegroundActive(false);
        logger.log(
          level: LogLevel.info,
          category: 'privacy',
          message: 'remove-me',
        );
        final ordinary = List.generate(8, (_) => logger.stats());
        final retained = logger.disable(purge: false);
        final purgeOne = logger.disable();
        final purgeTwo = logger.disable();
        expect(identical(purgeOne, purgeTwo), isTrue);
        await Future.wait(ordinary);
        expect(await retained, isTrue);
        expect(await purgeOne, isTrue);
        final snapshot = jsonDecode(
          await File('${directory.path}/queue.json').readAsString(),
        ) as Map;
        expect(snapshot['records'], isEmpty);
        await logger.close();
        await expectLater(logger.disable(), throwsStateError);
      } finally {
        await logger.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
