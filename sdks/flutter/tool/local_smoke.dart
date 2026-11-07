// Core/isolate integration only. Does not claim Flutter/native bridge coverage.
import 'dart:async';
import 'dart:io';

import 'package:proxycept_logging/proxycept_logging.dart';

Future<void> main() async {
  ProxyceptLogger? logger;
  try {
    final env = Platform.environment;
    final base = Uri.parse(env['PROXYCEPT_TEST_BASE_URL'] ?? '');
    if (base.scheme != 'http' ||
        !{'127.0.0.1', '::1', '[::1]'}.contains(base.host)) {
      throw StateError('Local numeric loopback API required');
    }
    final key = env['PROXYCEPT_TEST_INGEST_KEY'];
    final session = env['PROXYCEPT_TEST_DEBUG_SESSION'];
    final directory = env['PROXYCEPT_TEST_SPOOL_DIR'];
    if (key == null || session == null || directory == null)
      throw StateError('Missing local test configuration');
    logger = await ProxyceptLogger.open(
      LoggingConfiguration(
        baseUrl: base,
        ingestToken: key,
        appVersion: 'flutter-smoke',
        build: '1',
        debugSessionId: session,
      ),
      spool: PrivateSpool.hostProvided(directory, protectionConfirmed: true),
    );
    if (!logger.log(
      level: LogLevel.info,
      category: 'flutter-integration',
      message: 'Cross-platform SDK smoke',
      attributes: {'password': 'must-be-redacted'},
    )) {
      throw StateError('Admission failed');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      await logger.flush();
      final stats = await logger.stats();
      if (stats.accepted + stats.duplicate >= 1 && stats.queued == 0) {
        stdout.writeln(
          'PASS Flutter Dart core: committed acknowledgement and queue drained',
        );
        return;
      }
      if (stats.authStopped) throw StateError('Authentication stopped');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('Committed delivery deadline exceeded');
  } catch (_) {
    stderr.writeln(
      'FAIL Flutter Dart core local smoke; inspect nonsecret configuration and delivery stats',
    );
    exitCode = 1;
  } finally {
    await logger?.close();
  }
}
