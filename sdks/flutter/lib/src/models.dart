import 'dart:convert';
import 'dart:math';

enum LogLevel { debug, info, warning, error }

const maxQueueBytes = 2 * 1024 * 1024;
const maxQueueEvents = 2000;
const maxBatchBytes = 256 * 1024;
const retention = Duration(days: 3);

/// A host-supplied, dedicated app-private directory. Mobile apps should use the
/// Flutter helper, which obtains/protects an OS no-backup directory natively.
class PrivateSpool {
  final String path;
  PrivateSpool.hostProvided(this.path, {required bool protectionConfirmed}) {
    if (!protectionConfirmed || !path.startsWith('/') || path.length > 4096) {
      throw ArgumentError(
        'An absolute private, backup-excluded directory is required',
      );
    }
  }
}

class LoggingConfiguration {
  final Uri baseUrl;
  final String ingestToken, appVersion, build;
  final String? installationId, debugSessionId;
  final int queueBytes, queueEvents;
  final Set<String> sensitiveKeys;
  LoggingConfiguration({
    required this.baseUrl,
    required this.ingestToken,
    required this.appVersion,
    required this.build,
    this.installationId,
    this.debugSessionId,
    this.queueBytes = maxQueueBytes,
    this.queueEvents = maxQueueEvents,
    Set<String> sensitiveKeys = const {},
  }) : sensitiveKeys = Set.unmodifiable(sensitiveKeys) {
    validateOrigin(baseUrl);
    validateToken(ingestToken);
    if (!validString(appVersion, 80) ||
        !validString(build, 80) ||
        (installationId != null &&
            !validString(installationId!, 128, nonempty: true)) ||
        (debugSessionId != null &&
            !validString(debugSessionId!, 128, nonempty: true)) ||
        queueBytes < 1024 ||
        queueBytes > maxQueueBytes ||
        queueEvents < 1 ||
        queueEvents > maxQueueEvents ||
        sensitiveKeys.length > 32 ||
        sensitiveKeys.any((k) => !validString(k, 64, nonempty: true))) {
      throw ArgumentError('Invalid logging configuration');
    }
  }

  Map<String, Object?> toMap() => {
    'base': baseUrl.toString(),
    'token': ingestToken,
    'app': appVersion,
    'build': build,
    'installation': installationId,
    'session': debugSessionId,
    'bytes': queueBytes,
    'count': queueEvents,
    'sensitive': sensitiveKeys.toList(),
  };
  factory LoggingConfiguration.fromMap(Map m) => LoggingConfiguration(
    baseUrl: Uri.parse(m['base'] as String),
    ingestToken: m['token'] as String,
    appVersion: m['app'] as String,
    build: m['build'] as String,
    installationId: m['installation'] as String?,
    debugSessionId: m['session'] as String?,
    queueBytes: m['bytes'] as int,
    queueEvents: m['count'] as int,
    sensitiveKeys: Set<String>.from(m['sensitive'] as List),
  );
}

void validateOrigin(Uri uri) {
  final numericLoopback =
      uri.host == '127.0.0.1' || uri.host == '::1' || uri.host == '[::1]';
  if ((uri.scheme != 'https' && !(uri.scheme == 'http' && numericLoopback)) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      !uri.hasAuthority) {
    throw ArgumentError(
      'HTTPS origin required (numeric loopback is permitted for tests)',
    );
  }
}

void validateToken(String value) {
  if (value.length > 128 ||
      RegExp(r'plog_ingest_[A-Za-z0-9_-]+').matchAsPrefix(value)?.end !=
          value.length) {
    throw ArgumentError('An ingest-only credential is required');
  }
}

bool validString(String value, int limit, {bool nonempty = false}) {
  if (value.length > limit * 2 || (nonempty && value.isEmpty)) return false;
  final runes = value.runes.toList(growable: false);
  return runes.length <= limit && !runes.any((r) => r >= 0xd800 && r <= 0xdfff);
}

bool validAttributes(Map<String, Object?> attrs) =>
    attrs.length <= 16 &&
    attrs.entries.every(
      (e) =>
          validString(e.key, 64, nonempty: true) &&
          (e.value == null ||
              e.value is bool ||
              (e.value is String && validString(e.value as String, 512)) ||
              (e.value is num &&
                  (e.value as num).isFinite &&
                  (e.value as num).abs() <= 1e308)),
    );

String uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

class Redactor {
  final String credential;
  final Set<String> sensitive;
  Redactor(this.credential, this.sensitive);
  static final _key = RegExp(
    r'password|passwd|secret|token|authorization|cookie|api.?key|credential|email|phone',
    caseSensitive: false,
  );
  static final _token = RegExp(
    r'\b(?:plog_ingest_|prx_live_|sk-)[A-Za-z0-9_-]+|\bBearer\s+[^\s,;"'
    "'"
    r']+|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
    caseSensitive: false,
  );
  static final _assignment = RegExp(
    r'\b(password|passwd|secret|token|authorization|cookie|api.?key)\s*[:=]\s*[^\s,;]+',
    caseSensitive: false,
  );
  static final _email = RegExp(
    r'[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
  );
  String text(String value, int max) {
    var s = value
        .replaceAll('\u0000', '\ufffd')
        .replaceAll(credential, '[REDACTED]');
    s = s
        .replaceAll(_token, '[REDACTED]')
        .replaceAllMapped(_assignment, (m) => '${m[1]}=[REDACTED]')
        .replaceAll(_email, '[REDACTED]');
    return String.fromCharCodes(s.runes.take(max));
  }

  Map<String, Object?> attributes(Map<String, Object?> input) => {
    for (final e in input.entries)
      text(
        e.key,
        64,
      ): _key.hasMatch(e.key) || sensitive.contains(e.key.toLowerCase())
          ? '[REDACTED]'
          : e.value is String
          ? text(e.value as String, 512)
          : e.value,
  };
}

class StoredEvent {
  final DateTime queuedAt;
  final Map<String, Object?> metadata, event;
  late final String encoded = jsonEncode(toMap());
  late final int bytes = utf8.encode(encoded).length;
  StoredEvent(this.queuedAt, this.metadata, this.event);
  String get id => event['event_id'] as String;
  Map<String, Object?> toMap() => {
    'queued_at': queuedAt.toUtc().toIso8601String(),
    'metadata': metadata,
    'event': event,
  };
}

/// Counters never contain credentials or event content. Process-local totals.
class DeliveryStats {
  final Map<String, Object?> _values;
  DeliveryStats.fromMap(Map values)
    : _values = Map.unmodifiable(Map<String, Object?>.from(values));
  int get queued => _values['queued'] as int;
  int get queuedBytes => _values['queuedBytes'] as int;
  int get accepted => _values['accepted'] as int;
  int get duplicate => _values['duplicate'] as int;
  int get droppedOldest => _values['droppedOldest'] as int;
  int get expired => _values['expired'] as int;
  int get invalid => _values['invalid'] as int;
  int get rejected => _values['rejected'] as int;
  int get storageFailures => _values['storageFailures'] as int;
  int get failures => _values['failures'] as int;
  int get admissionDropped => _values['admissionDropped'] as int;
  bool get authStopped => _values['authStopped'] as bool;
  bool get enabled => _values['enabled'] as bool;
  bool get foreground => _values['foreground'] as bool;
  DateTime? get nextAttempt => _values['nextAttempt'] == null
      ? null
      : DateTime.parse(_values['nextAttempt'] as String);
}
