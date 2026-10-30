import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'posix.dart';

abstract interface class SpoolStorage {
  Future<String?> read();
  Future<void> write(String snapshot);
  Future<void> close();
}

/// Atomic same-directory rename, fsync of file contents, cross-isolate/process flock.
/// No fsync of the containing directory: not a power-loss durability guarantee.
class FileSpoolStorage implements SpoolStorage {
  final Directory directory;
  final PosixOwner _owner;
  FileSpoolStorage._(this.directory, this._owner);
  static Future<FileSpoolStorage> open(String path) async {
    final directory = Directory(path);
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Spool directory aliases/symlinks refused');
    }
    PosixOwner.protect(path, 448); // 0700
    for (final name in ['owner.lock', 'queue.json', 'queue.tmp']) {
      final type = await FileSystemEntity.type(
        '$path/$name',
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw StateError('Spool links/nonfiles refused');
      }
    }
    final lockPath = '$path/owner.lock';
    final lockFile = await File(lockPath).open(mode: FileMode.append);
    try {
      PosixOwner.protect(lockPath, 384);
    } finally {
      await lockFile.close();
    }
    final owner = PosixOwner.acquire(lockPath);
    try {
      final temp = File('$path/queue.tmp');
      if (await temp.exists()) await temp.delete();
      return FileSpoolStorage._(directory, owner);
    } catch (_) {
      owner.close();
      rethrow;
    }
  }

  String get _file => '${directory.path}/queue.json';
  @override
  Future<String?> read() async {
    final file = File(_file);
    if (!await file.exists()) return null;
    PosixOwner.protect(_file, 384);
    if (await file.length() > maxQueueBytes) return '!corrupt';
    final result = <int>[];
    await for (final chunk in file.openRead()) {
      if (result.length + chunk.length > maxQueueBytes) return '!corrupt';
      result.addAll(chunk);
    }
    return utf8.decode(result);
  }

  @override
  Future<void> write(String snapshot) async {
    final bytes = utf8.encode(snapshot);
    if (bytes.length > maxQueueBytes) throw StateError('Spool bound exceeded');
    final path = '${directory.path}/queue.tmp';
    final file = await File(path).open(mode: FileMode.write);
    try {
      PosixOwner.protect(path, 384);
      await file.writeFrom(bytes);
      await file.flush();
    } finally {
      await file.close();
    }
    await File(path).rename(_file);
  }

  @override
  Future<void> close() async {
    _owner.close();
  }
}
