import 'dart:async';

import 'package:flutter/material.dart';
import 'package:proxycept_logging/proxycept_logging_flutter.dart';

void main() {
  runApp(const LoggingExample());
}

class LoggingExample extends StatelessWidget {
  const LoggingExample({super.key});
  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: LoggingScreen());
}

class LoggingScreen extends StatefulWidget {
  const LoggingScreen({super.key});
  @override
  State<LoggingScreen> createState() => _LoggingScreenState();
}

class _LoggingScreenState extends State<LoggingScreen> {
  final _base = TextEditingController(text: 'http://127.0.0.1:18880');
  final _key = TextEditingController();
  ProxyceptLogger? _logger;
  ProxyceptLifecycleAdapter? _lifecycle;
  var _status =
      'Enter a disposable local ingest key. Nothing is sent automatically.';
  var _busy = false;
  Future<void> _start() async {
    setState(() {
      _busy = true;
    });
    try {
      final logger = await createMobileLogger(
        configuration: LoggingConfiguration(
          baseUrl: Uri.parse(_base.text),
          ingestToken: _key.text,
          appVersion: 'flutter-example',
          build: '1',
        ),
        namespace: 'example-dev',
      );
      _key.clear();
      if (!mounted) {
        await logger.close();
        return;
      }
      _logger = logger;
      _lifecycle = ProxyceptLifecycleAdapter(logger);
      setState(() {
        _status = 'Ready. Admission is not delivery.';
      });
    } catch (_) {
      if (mounted)
        setState(() {
          _status = 'Setup failed. Check origin, key, and private storage.';
        });
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
        });
    }
  }

  Future<void> _send() async {
    final logger = _logger;
    if (logger == null) return;
    final admitted = logger.log(
      level: LogLevel.info,
      category: 'flutter-integration',
      message: 'Cross-platform SDK smoke',
      attributes: {'password': 'must-be-redacted'},
    );
    await logger.flush();
    final stats = await logger.stats();
    if (mounted)
      setState(() {
        _status =
            'Admission: $admitted; committed: ${stats.accepted}; duplicates: ${stats.duplicate}; queued: ${stats.queued}; failures: ${stats.failures}';
      });
  }

  Future<void> _disable() async {
    final cleared = await _logger?.disable();
    if (mounted)
      setState(() {
        _status = 'Disabled. Purge persisted: $cleared';
      });
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    final logger = _logger;
    if (logger != null) unawaited(logger.close());
    _base.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Proxycept logging demo')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          TextField(
            controller: _base,
            decoration: const InputDecoration(labelText: 'Local API origin'),
            enabled: _logger == null,
          ),
          TextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Disposable ingest key',
            ),
            enabled: _logger == null,
          ),
          FilledButton(
            onPressed: _busy || _logger != null ? null : _start,
            child: const Text('Start private logger'),
          ),
          FilledButton(
            onPressed: _logger == null ? null : _send,
            child: const Text('Log and flush'),
          ),
          TextButton(
            onPressed: _logger == null ? null : _disable,
            child: const Text('Disable and purge'),
          ),
          Text(_status),
        ],
      ),
    ),
  );
}
