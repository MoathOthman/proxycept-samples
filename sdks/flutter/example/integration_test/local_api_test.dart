// Test-only runtime configuration: never embed credentials or pass them as defines.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:proxycept_logging/proxycept_logging_flutter.dart';
import 'package:proxycept_logging/src/storage_policy.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native private no-backup spool to committed local API', (
    tester,
  ) async {
    await tester.runAsync(() async {
      ProxyceptLogger? logger;
      var stage = 'runtime-config';
      try {
        const configurationUrl = String.fromEnvironment(
          'PROXYCEPT_TEST_CONFIG_URL',
          defaultValue: 'http://127.0.0.1:18881/sdk-test-config',
        );
        final uri = Uri.parse(configurationUrl);
        if (uri.scheme != 'http' ||
            !{'127.0.0.1', '::1', '[::1]'}.contains(uri.host) ||
            uri.port != 18881 ||
            uri.path != '/sdk-test-config' ||
            uri.hasQuery ||
            uri.hasFragment ||
            uri.userInfo.isNotEmpty) {
          throw StateError(
            'Only the local synthetic configuration endpoint is allowed',
          );
        }
        final client = HttpClient()..autoUncompress = false;
        Map<String, dynamic> config;
        try {
          final request = await client
              .getUrl(uri)
              .timeout(const Duration(seconds: 10));
          request.followRedirects = false;
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          if (response.statusCode != 200)
            throw StateError('Local configuration unavailable');
          final bytes = <int>[];
          await for (final chunk in response.timeout(
            const Duration(seconds: 10),
          )) {
            if (bytes.length + chunk.length > 4096)
              throw StateError('Local configuration too large');
            bytes.addAll(chunk);
          }
          config = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(bytes)) as Map,
          );
        } finally {
          client.close(force: true);
        }
        final base = Uri.parse(config['base_url'] as String);
        if (base.scheme != 'http' ||
            !{'127.0.0.1', '::1', '[::1]'}.contains(base.host) ||
            base.port != 18880) {
          throw StateError('Only the local synthetic API is allowed');
        }
        final key = config['ingest_key'] as String;
        final session = config['debug_session_id'] as String;
        final namespace =
            'integration-${DateTime.now().microsecondsSinceEpoch}';
        const channel = MethodChannel('com.proxycept.logging/private_spool');
        stage = 'native-private-spool';
        final path = await channel.invokeMethod<String>('prepareSpool', {
          'namespace': namespace,
        });
        if (path == null) throw StateError('Private spool unavailable');
        logger = await createMobileLogger(
          namespace: namespace,
          configuration: LoggingConfiguration(
            baseUrl: base,
            ingestToken: key,
            appVersion: 'flutter-native-smoke',
            build: '1',
            debugSessionId: session,
          ),
        );
        await logger.setForegroundActive(false);
        stage = 'redacted-private-persistence';
        if (!logger.log(
          level: LogLevel.info,
          category: 'flutter-integration',
          message: 'Cross-platform SDK smoke',
          attributes: {'password': 'must-be-redacted'},
        ))
          throw StateError('Admission failed');
        final file = File('$path/queue.json');
        var persisted = false;
        for (var i = 0; i < 100; i++) {
          if (await file.exists() && await file.length() <= 2 * 1024 * 1024) {
            final text = await file.readAsString();
            if (text.contains(key) || text.contains('must-be-redacted'))
              throw StateError('Private persistence scrub failed');
            if (text.contains('flutter-integration')) {
              persisted = true;
              break;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (!persisted) throw StateError('Persistence deadline exceeded');
        stage = 'native-storage-policy';
        final policy = await channel.invokeMapMethod<String, dynamic>(
          'verifySpool',
          {'namespace': namespace},
        );
        String policyClass(Object? value) =>
            const {
              'NSFileProtectionComplete',
              'NSFileProtectionCompleteUnlessOpen',
              'NSFileProtectionCompleteUntilFirstUserAuthentication',
              'NSFileProtectionNone',
            }.contains(value)
            ? value as String
            : 'unreported';
        stage =
            'native-storage-policy '
            '(backup=${policy?['backupExcluded'] == true}, directory=${policy?['directoryPrivate'] == true}, '
            'filePrivate=${policy?['filePrivate'] == true}, fileProtected=${policy?['fileProtected'] == true}, '
            'protection=${policyClass(policy?['protectionClass'])}, '
            'directoryProtection=${policyClass(policy?['directoryProtectionClass'])}, '
            'simulator=${policy?['isSimulator'] == true})';
        final evidence = evaluateStoragePolicy(policy);
        if (evidence == StoragePolicyEvidence.rejected) {
          throw StateError('Native storage policy verification failed');
        }
        if (evidence == StoragePolicyEvidence.simulatorProtectionUnverified) {
          stdout.writeln(
            'UNVERIFIED iOS Simulator Data Protection metadata; backup exclusion and private modes verified',
          );
        }
        stage = 'committed-acknowledgement';
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        var committed = false;
        while (DateTime.now().isBefore(deadline)) {
          await logger.flush();
          final stats = await logger.stats();
          if (stats.authStopped) throw StateError('Local credential rejected');
          if (stats.accepted + stats.duplicate == 1 && stats.queued == 0) {
            committed = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (!committed) throw StateError('Commit deadline exceeded');
        // No credential, session identifier, file path, or event content in test output.
      } catch (_) {
        throw StateError('Flutter native local smoke failed at $stage');
      } finally {
        await logger?.disable();
        await logger?.close();
      }
    });
  });
}
