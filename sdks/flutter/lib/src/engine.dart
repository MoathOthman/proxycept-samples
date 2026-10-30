import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'models.dart';
import 'storage.dart';
import 'transport.dart';

/// Actor state: used in a dedicated isolate by the public client. Injected fakes
/// allow deterministic tests without file/network access on the test caller.
class LoggingEngine {
  final LoggingConfiguration config;
  final SpoolStorage storage;
  final LogTransport transport;
  final DateTime Function() clock;
  final double Function() jitter;
  late Redactor _redactor;
  late String _credential, installationId, sessionId;
  int _sequence = 0, _revision = 0, _persistedRevision = -1, _generation = 0;
  int _accepted = 0,
      _duplicate = 0,
      _droppedOldest = 0,
      _expired = 0,
      _invalid = 0,
      _rejected = 0,
      _storageFailures = 0,
      _failures = 0;
  int _recordBytes = 0, _attempt = 0, _batchSize = 50;
  bool enabled = true, foreground = true, authStopped = false, _closed = false;
  DateTime? _nextAttempt;
  final List<StoredEvent> _queue = [];
  Future<bool>? _persisting;
  Future<void>? _flushing;
  Timer? _persistTimer;
  LoggingEngine(
    this.config,
    this.storage,
    this.transport, {
    DateTime Function()? clock,
    double Function()? jitter,
  }) : clock = clock ?? (() => DateTime.now().toUtc()),
       jitter = jitter ?? Random.secure().nextDouble {
    _credential = config.ingestToken;
    _redactor = Redactor(
      _credential,
      config.sensitiveKeys.map((s) => s.toLowerCase()).toSet(),
    );
    installationId = _redactor.text(config.installationId ?? uuid(), 128);
    sessionId = _redactor.text(config.debugSessionId ?? uuid(), 128);
  }

  DateTime get _now => clock().toUtc();
  Map<String, Object?> _event(
    LogLevel level,
    String category,
    String message,
    Map<String, Object?> attrs,
    String? correlation,
    String id,
    int sequence,
    String time,
  ) => {
    'event_id': id,
    'sequence': sequence,
    'client_time': time,
    'severity': level.name,
    'category': _redactor.text(category, 80),
    'message': _redactor.text(message, 4096),
    'attributes': _redactor.attributes(attrs),
    'correlation_id': correlation == null
        ? null
        : _redactor.text(correlation, 128),
  };

  bool enqueue(
    LogLevel level,
    String category,
    String message,
    Map<String, Object?> attributes,
    String? correlationId,
  ) {
    if (_closed || !enabled || authStopped) {
      _rejected++;
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
    final now = _now;
    final event = _event(
      level,
      category,
      message,
      attributes,
      correlationId,
      uuid(),
      _sequence++,
      now.toIso8601String(),
    );
    if (utf8.encode(jsonEncode(event)).length > 8192) {
      _invalid++;
      return false;
    }
    final record = StoredEvent(now, {
      'app_version': _redactor.text(config.appVersion, 80),
      'build': _redactor.text(config.build, 80),
      'installation_id': installationId,
      'debug_session_id': sessionId,
    }, event);
    _expire();
    _queue.add(record);
    _recordBytes += record.bytes;
    _revision++;
    _trim();
    _schedulePersist();
    return true;
  }

  Map<String, Object?> _header() => {
    'version': 1,
    'installation_id': installationId,
    'next_sequence': _sequence,
    'records': <Object?>[],
  };
  int get queueBytes =>
      utf8.encode(jsonEncode(_header())).length +
      _recordBytes +
      max(0, _queue.length - 1);
  String _snapshot() {
    final header = jsonEncode(_header());
    return header.substring(0, header.length - 2) +
        _queue.map((r) => r.encoded).join(',') +
        ']}';
  }

  void _trim() {
    while (_queue.isNotEmpty &&
        (_queue.length > config.queueEvents ||
            queueBytes > config.queueBytes)) {
      _recordBytes -= _queue.removeAt(0).bytes;
      _droppedOldest++;
      _revision++;
    }
  }

  void _expire() {
    final cutoff = _now.subtract(retention);
    final expired = _queue.where((r) => !r.queuedAt.isAfter(cutoff)).toList();
    if (expired.isEmpty) return;
    final ids = expired.map((r) => r.id).toSet();
    _queue.removeWhere((r) => ids.contains(r.id));
    _recordBytes -= expired.fold(0, (int n, r) => n + r.bytes);
    _expired += expired.length;
    _revision++;
  }

  void _schedulePersist() {
    _persistTimer ??= Timer(const Duration(milliseconds: 20), () {
      _persistTimer = null;
      if (!_closed) unawaited(persist());
    });
  }

  /// Corrupt legacy records are dropped individually; valid neighbors survive.
  Future<void> initialize() async {
    try {
      final raw = await storage.read();
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map ||
            decoded['version'] != 1 ||
            decoded['records'] is! List ||
            (decoded['records'] as List).length > maxQueueEvents ||
            decoded['installation_id'] is! String ||
            !validString(
              decoded['installation_id'] as String,
              128,
              nonempty: true,
            )) {
          throw const FormatException('Invalid spool');
        }
        if (config.installationId == null)
          installationId = _redactor.text(
            decoded['installation_id'] as String,
            128,
          );
        final sequence = decoded['next_sequence'];
        if (sequence is int && sequence >= 0) _sequence = sequence;
        final seen = <String>{};
        for (final item in decoded['records'] as List) {
          try {
            final record = _recover(item);
            if (!seen.add(record.id)) {
              _invalid++;
              continue;
            }
            _queue.add(record);
            _recordBytes += record.bytes;
            _sequence = max(_sequence, (record.event['sequence'] as int) + 1);
          } catch (_) {
            _invalid++;
          }
        }
      }
    } on FileSystemException {
      _storageFailures++;
    } catch (_) {
      _invalid++;
    }
    _revision++;
    _expire();
    _trim();
    // Scrub recovered records before allowing even their first subsequent upload.
    await persist();
  }

  StoredEvent _recover(dynamic input) {
    if (input is! Map ||
        input['metadata'] is! Map ||
        input['event'] is! Map ||
        input['queued_at'] is! String) {
      throw const FormatException('Invalid record');
    }
    final metadata = Map<String, Object?>.from(input['metadata'] as Map);
    final e = Map<String, Object?>.from(input['event'] as Map);
    final queuedAt = DateTime.parse(input['queued_at'] as String).toUtc();
    if (queuedAt.isAfter(_now.add(const Duration(minutes: 5))))
      throw const FormatException('Invalid age');
    for (final key in [
      'app_version',
      'build',
      'installation_id',
      'debug_session_id',
    ]) {
      final value = metadata[key];
      if (value is! String ||
          !validString(
            value,
            key == 'build' || key == 'app_version' ? 80 : 128,
            nonempty: key == 'installation_id' || key == 'debug_session_id',
          ))
        throw const FormatException('Invalid metadata');
    }
    if (e['event_id'] is! String ||
        !validString(e['event_id'] as String, 128, nonempty: true) ||
        e['sequence'] is! int ||
        (e['sequence'] as int) < 0 ||
        e['client_time'] is! String ||
        !validIso(e['client_time'] as String) ||
        e['category'] is! String ||
        e['message'] is! String ||
        !validString(e['category'] as String, 80) ||
        !validString(e['message'] as String, 4096) ||
        e['attributes'] is! Map) {
      throw const FormatException('Invalid event');
    }
    final attrs = Map<String, Object?>.from(e['attributes'] as Map);
    final correlation = e['correlation_id'];
    if (!validAttributes(attrs) ||
        (correlation != null &&
            (correlation is! String ||
                !validString(correlation, 128, nonempty: true)))) {
      throw const FormatException('Invalid attributes');
    }
    final level = LogLevel.values.byName(e['severity'] as String);
    final event = _event(
      level,
      e['category'] as String,
      e['message'] as String,
      attrs,
      correlation as String?,
      _redactor.text(e['event_id'] as String, 128),
      e['sequence'] as int,
      DateTime.parse(e['client_time'] as String).toUtc().toIso8601String(),
    );
    if (utf8.encode(jsonEncode(event)).length > 8192)
      throw const FormatException('Oversized event');
    return StoredEvent(queuedAt, {
      for (final key in [
        'app_version',
        'build',
        'installation_id',
        'debug_session_id',
      ])
        key: _redactor.text(
          metadata[key] as String,
          key == 'build' || key == 'app_version' ? 80 : 128,
        ),
    }, event);
  }

  Future<bool> persist() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    while (_persistedRevision != _revision) {
      final operation = _persisting ??= _persistLoop().whenComplete(() {
        _persisting = null;
      });
      if (!await operation) return false;
    }
    return true;
  }

  Future<bool> _persistLoop() async {
    _expire();
    while (_persistedRevision != _revision) {
      final revision = _revision;
      final snapshot = _snapshot();
      try {
        await storage.write(snapshot);
      } catch (_) {
        _storageFailures++;
        return false;
      }
      _persistedRevision = revision;
    }
    return true;
  }

  Future<void> flush() => _flushing ??= _flushLoop().whenComplete(() {
    _flushing = null;
  });
  Future<void> _flushLoop() async {
    for (var batch = 0; batch < 10; batch++) {
      _expire();
      if (_closed ||
          !enabled ||
          authStopped ||
          (_nextAttempt != null && _now.isBefore(_nextAttempt!)))
        return;
      final generation = _generation;
      if (!await persist() || generation != _generation || _queue.isEmpty)
        return;
      final first = jsonEncode(_queue.first.metadata);
      final records = _queue
          .takeWhile((r) => jsonEncode(r.metadata) == first)
          .take(_batchSize)
          .toList();
      List<int> payload() => utf8.encode(
        jsonEncode({
          'schema_version': 1,
          ...records.first.metadata,
          'events': records.map((r) => r.event).toList(),
        }),
      );
      var bytes = payload();
      while (bytes.length > maxBatchBytes && records.length > 1) {
        records.removeLast();
        bytes = payload();
      }
      if (bytes.length > maxBatchBytes) {
        _remove(records);
        _invalid += records.length;
        continue;
      }
      TransportResponse response;
      try {
        response = await transport.post(config.baseUrl, _credential, bytes);
      } catch (_) {
        if (generation == _generation) _backoff();
        return;
      }
      if (generation != _generation || _closed || !enabled) return;
      if (response.status == 200) {
        try {
          final ack = jsonDecode(response.body);
          if (ack is! Map ||
              ack['accepted'] is! int ||
              ack['duplicate'] is! int ||
              (ack['accepted'] as int) < 0 ||
              (ack['duplicate'] as int) < 0 ||
              (ack['accepted'] as int) + (ack['duplicate'] as int) !=
                  records.length ||
              ack['received_at'] is! String ||
              !validIso(ack['received_at'] as String)) {
            throw const FormatException('Invalid acknowledgement');
          }
          _accepted += ack['accepted'] as int;
          _duplicate += ack['duplicate'] as int;
          _remove(records);
          _attempt = 0;
          _nextAttempt = null;
          _batchSize = 50;
          await persist();
        } catch (_) {
          _backoff();
          return;
        }
      } else if (response.status == 401 || response.status == 403) {
        authStopped = true;
        _failures++;
        return;
      } else if (response.status == 429) {
        _backoff();
        final retry = retryAt(response.retryAfter, _now);
        if (retry != null &&
            (_nextAttempt == null || retry.isAfter(_nextAttempt!)))
          _nextAttempt = retry;
        return;
      } else if (response.status == 413) {
        if (records.length > 1) {
          _batchSize = max(1, records.length ~/ 2);
        } else {
          _remove(records);
          _rejected++;
        }
      } else if (response.status >= 500 || response.status == 408) {
        _backoff();
        return;
      } else {
        _remove(records);
        _rejected += records.length;
        await persist();
      }
    }
  }

  void _remove(List<StoredEvent> records) {
    final ids = records.map((r) => r.id).toSet();
    _queue.removeWhere((r) => ids.contains(r.id));
    _recordBytes = _queue.fold(0, (n, r) => n + r.bytes);
    _revision++;
  }

  void _backoff() {
    _failures++;
    _attempt = min(_attempt + 1, 10);
    final seconds =
        min(300, pow(2, _attempt).toInt()) * (0.5 + jitter().clamp(0, 1));
    _nextAttempt = _now.add(Duration(milliseconds: (seconds * 1000).round()));
  }

  Future<bool> disable({bool purge = true}) async {
    enabled = false;
    _generation++;
    if (purge) {
      _queue.clear();
      _recordBytes = 0;
      _revision++;
    }
    return await persist();
  }

  void reconfigure(String token) {
    if (_closed) throw StateError('Logger closed');
    validateToken(token);
    _credential = token;
    _redactor = Redactor(
      token,
      config.sensitiveKeys.map((k) => k.toLowerCase()).toSet(),
    );
    _generation++;
    enabled = true;
    authStopped = false;
    _attempt = 0;
    _nextAttempt = null;
  }

  void setForeground(bool active) {
    foreground = active;
    if (!active) _schedulePersist();
  }

  Future<void> tick() async {
    _expire();
    await persist();
    if (foreground) await flush();
  }

  Map<String, Object?> stats() {
    _expire();
    _schedulePersist();
    return {
      'queued': _queue.length,
      'queuedBytes': queueBytes,
      'accepted': _accepted,
      'duplicate': _duplicate,
      'droppedOldest': _droppedOldest,
      'expired': _expired,
      'invalid': _invalid,
      'rejected': _rejected,
      'storageFailures': _storageFailures,
      'failures': _failures,
      'authStopped': authStopped,
      'enabled': enabled,
      'foreground': foreground,
      'nextAttempt': _nextAttempt?.toIso8601String(),
      'admissionDropped': 0,
    };
  }

  Future<void> close() async {
    if (_closed) return;
    enabled = false;
    _generation++;
    _persistTimer?.cancel();
    _persistTimer = null;
    var persisted = false;
    try {
      persisted = await persist();
    } finally {
      _closed = true;
      try {
        transport.close();
      } finally {
        await storage.close();
      }
    }
    if (!persisted)
      throw StateError('Final queue snapshot could not be persisted');
  }
}

bool validIso(String value) =>
    value.length <= 64 &&
    value.contains('T') &&
    RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(value) &&
    DateTime.tryParse(value) != null;
DateTime? retryAt(String? value, DateTime now) {
  if (value == null || value.length > 128) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null)
    return now.add(Duration(seconds: seconds.clamp(0, 86400)));
  try {
    return HttpDate.parse(value).toUtc();
  } catch (_) {
    return null;
  }
}
