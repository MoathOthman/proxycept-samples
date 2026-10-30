import 'dart:async';
import 'dart:isolate';

import 'models.dart';
import 'engine.dart';
import 'storage.dart';
import 'transport.dart';

class ProxyceptLogger {
  final SendPort _worker;
  final ReceivePort _responses, _errors;
  final Isolate _isolate;
  late final StreamSubscription<dynamic> _subscription, _errorSubscription;
  final Map<int, Completer<Object?>> _pending = {};
  final Redactor _redactor;
  int _next = 0, _admitted = 0, _admissionDropped = 0, _invalid = 0;
  bool _closed = false,
      _enabled = true,
      _authStopped = false,
      _closingRequested = false;
  Future<void>? _flush, _closing;
  Future<bool>? _disablePurging, _disableRetaining;
  ProxyceptLogger._(
    this._worker,
    this._responses,
    this._errors,
    this._isolate,
    this._redactor,
  ) {
    _subscription = _responses.listen((dynamic m) {
      final message = m as List;
      if (message[0] == 'admitted') {
        _admitted--;
        _authStopped = message[1] as bool;
        return;
      }
      final completer = _pending.remove(message[0]);
      if (completer == null) return;
      if (message[1] == true) {
        completer.complete(message[2]);
      } else {
        completer.completeError(StateError('Logging worker operation failed'));
      }
    });
    _errorSubscription = _errors.listen((_) {
      _closed = true;
      for (final pending in _pending.values) {
        pending.completeError(StateError('Logging worker unavailable'));
      }
      _pending.clear();
      _admitted = 0;
    });
  }
  static Future<ProxyceptLogger> open(
    LoggingConfiguration config, {
    required PrivateSpool spool,
  }) async {
    final startup = ReceivePort(),
        responses = ReceivePort(),
        errors = ReceivePort();
    final isolate = await Isolate.spawn(
      _startWorker,
      [startup.sendPort, responses.sendPort, config.toMap(), spool.path],
      onError: errors.sendPort,
      debugName: 'Proxycept logging',
    );
    try {
      final ready = await startup.first.timeout(const Duration(seconds: 30));
      if (ready is! SendPort)
        throw StateError('Private logging storage unavailable');
      return ProxyceptLogger._(
        ready,
        responses,
        errors,
        isolate,
        Redactor(config.ingestToken, config.sensitiveKeys),
      );
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      errors.close();
      rethrow;
    } finally {
      startup.close();
    }
  }

  /// True only means bounded admission, not successful persistence/delivery.
  /// No file or network I/O; at most 32 unacknowledged worker admissions.
  bool log({
    required LogLevel level,
    required String category,
    required String message,
    Map<String, Object?> attributes = const {},
    String? correlationId,
  }) {
    if (_closed || _closingRequested || !_enabled || _authStopped) return false;
    if (_admitted >= 32) {
      _admissionDropped++;
      return false;
    }
    if (!validString(category, 80) ||
        !validString(message, 4096) ||
        !validAttributes(attributes) ||
        (correlationId != null &&
            !validString(correlationId, 128, nonempty: true))) {
      _invalid++;
      return false;
    }
    _admitted++;
    _worker.send([
      'log',
      level.name,
      _redactor.text(category, 80),
      _redactor.text(message, 4096),
      _redactor.attributes(Map<String, Object?>.from(attributes)),
      correlationId == null ? null : _redactor.text(correlationId, 128),
    ]);
    return true;
  }

  Future<Object?> _call(
    String operation, [
    Object? value,
    bool reserved = false,
  ]) {
    if (_closed) return Future.error(StateError('Logger closed'));
    if (_closingRequested && operation != 'close') {
      return Future.error(StateError('Logger closing'));
    }
    // Eight ordinary controls, plus at most two coalesced privacy operations and
    // one coalesced shutdown. Reserved lifecycle calls can never be saturated out.
    if (!reserved && _pending.length >= 8)
      return Future.error(StateError('Too many pending logging operations'));
    final id = _next++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _worker.send([operation, id, value]);
    return completer.future;
  }

  Future<void> flush() =>
      _flush ??= _call('flush').then((_) {}).whenComplete(() {
        _flush = null;
      });
  Future<DeliveryStats> stats() async {
    final values = Map<String, Object?>.from(await _call('stats') as Map);
    _authStopped = values['authStopped'] as bool;
    values['admissionDropped'] = _admissionDropped;
    values['invalid'] = (values['invalid'] as int) + _invalid;
    return DeliveryStats.fromMap(values);
  }

  Future<void> setForegroundActive(bool active) async {
    await _call('foreground', active);
  }

  Future<bool> disable({bool purge = true}) {
    _enabled = false;
    if (purge) {
      return _disablePurging ??= _call('disable', true, true)
          .then((value) => value as bool)
          .whenComplete(() {
            _disablePurging = null;
          });
    }
    // Separate retain/purge lanes allow a later purge request to upgrade privacy
    // even while a retaining disable is waiting behind an older storage write.
    return _disableRetaining ??= _call('disable', false, true)
        .then((value) => value as bool)
        .whenComplete(() {
          _disableRetaining = null;
        });
  }

  Future<void> reconfigure({required String ingestToken}) async {
    validateToken(ingestToken);
    await _call('reconfigure', ingestToken);
    _enabled = true;
    _authStopped = false;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closingRequested = true;
    _enabled = false;
    try {
      // ACK (including an error ACK) is sent only after worker resource cleanup.
      if (!_closed) await _call('close', null, true);
    } finally {
      _closed = true;
      _isolate.kill(priority: Isolate.immediate);
      for (final operation in _pending.values) {
        operation.completeError(StateError('Logger closed'));
      }
      _pending.clear();
      await _subscription.cancel();
      await _errorSubscription.cancel();
      _responses.close();
      _errors.close();
    }
  }
}

@pragma('vm:entry-point')
void _startWorker(List<Object?> arguments) async {
  final startup = arguments[0] as SendPort,
      responses = arguments[1] as SendPort;
  LoggingEngine engine;
  try {
    final config = LoggingConfiguration.fromMap(arguments[2] as Map);
    final storage = await FileSpoolStorage.open(arguments[3] as String);
    engine = LoggingEngine(config, storage, IoLogTransport());
    await engine.initialize();
  } catch (_) {
    startup.send(false);
    return;
  }
  final commands = ReceivePort();
  final timer = Timer.periodic(const Duration(seconds: 2), (_) {
    unawaited(engine.tick());
  });
  startup.send(commands.sendPort);
  commands.listen((dynamic raw) async {
    final m = raw as List;
    if (m[0] == 'log') {
      engine.enqueue(
        LogLevel.values.byName(m[1] as String),
        m[2] as String,
        m[3] as String,
        Map<String, Object?>.from(m[4] as Map),
        m[5] as String?,
      );
      responses.send(['admitted', engine.authStopped]);
      return;
    }
    try {
      Object? result;
      switch (m[0]) {
        case 'flush':
          await engine.flush();
        case 'stats':
          result = engine.stats();
        case 'foreground':
          engine.setForeground(m[2] as bool);
        case 'disable':
          result = await engine.disable(purge: m[2] as bool);
        case 'reconfigure':
          engine.reconfigure(m[2] as String);
        case 'close':
          timer.cancel();
          try {
            await engine.close();
          } finally {
            commands.close();
          }
        default:
          throw StateError('Unknown logging operation');
      }
      responses.send([m[1], true, result]);
    } catch (_) {
      responses.send([m[1], false, null]);
    }
  });
}
