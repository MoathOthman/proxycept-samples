/// Flutter iOS/Android helpers; no web or desktop plugin implementation.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'proxycept_logging.dart';
export 'proxycept_logging.dart';

const _channel = MethodChannel('com.proxycept.logging/private_spool');

/// Native setup performs filesystem work on a platform I/O queue, excludes
/// backup, and sets iOS protection before the worker creates any spool file.
Future<ProxyceptLogger> createMobileLogger({
  required LoggingConfiguration configuration,
  required String namespace,
}) async {
  if (!(Platform.isIOS || Platform.isAndroid))
    throw UnsupportedError('iOS/Android only');
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(namespace))
    throw ArgumentError('Invalid spool namespace');
  final path = await _channel.invokeMethod<String>('prepareSpool', {
    'namespace': namespace,
  });
  if (path == null) throw StateError('Protected spool unavailable');
  return ProxyceptLogger.open(
    configuration,
    spool: PrivateSpool.hostProvided(path, protectionConfirmed: true),
  );
}

/// No background execution is requested. Hosts must dispose this listener and
/// explicitly await logger.close() on a normal shutdown when time is available.
class ProxyceptLifecycleAdapter with WidgetsBindingObserver {
  final ProxyceptLogger logger;
  bool _disposed = false;
  ProxyceptLifecycleAdapter(this.logger) {
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null) didChangeAppLifecycleState(state);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_disposed) {
      // Do not leak errors into the host framework after the host closes a logger.
      logger
          .setForegroundActive(state == AppLifecycleState.resumed)
          .catchError((Object _) {});
    }
  }

  void dispose() {
    if (!_disposed) {
      _disposed = true;
      WidgetsBinding.instance.removeObserver(this);
    }
  }
}
