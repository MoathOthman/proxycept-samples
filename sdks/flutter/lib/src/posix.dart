// Executed exclusively in the storage worker isolate. Mobile POSIX platforms only.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _AllocC = Pointer<Void> Function(IntPtr);
typedef _Alloc = Pointer<Void> Function(int);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
typedef _OpenC = Int32 Function(Pointer<Uint8>, Int32);
typedef _Open = int Function(Pointer<Uint8>, int);
typedef _FlockC = Int32 Function(Int32, Int32);
typedef _Flock = int Function(int, int);
typedef _CloseC = Int32 Function(Int32);
typedef _Close = int Function(int);
typedef _ChmodC = Int32 Function(Pointer<Uint8>, Uint32);
typedef _Chmod = int Function(Pointer<Uint8>, int);

class PosixOwner {
  static final _lib = DynamicLibrary.process();
  static final _malloc = _lib.lookupFunction<_AllocC, _Alloc>('malloc');
  static final _free = _lib.lookupFunction<_FreeC, _Free>('free');
  static final _open = _lib.lookupFunction<_OpenC, _Open>('open');
  static final _flock = _lib.lookupFunction<_FlockC, _Flock>('flock');
  static final _close = _lib.lookupFunction<_CloseC, _Close>('close');
  static final _chmod = _lib.lookupFunction<_ChmodC, _Chmod>('chmod');
  final int _fd;
  bool _closed = false;
  PosixOwner._(this._fd);
  static T _path<T>(String path, T Function(Pointer<Uint8>) use) {
    final bytes = utf8.encode(path);
    final pointer = _malloc(bytes.length + 1).cast<Uint8>();
    if (pointer.address == 0) throw StateError('Private storage unavailable');
    try {
      pointer.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
      return use(pointer);
    } finally {
      _free(pointer.cast());
    }
  }

  static void protect(String path, int mode) {
    if (_path(path, (p) => _chmod(p, mode)) != 0)
      throw StateError('Private storage permissions unavailable');
  }

  static PosixOwner acquire(String path) {
    if (!(Platform.isIOS ||
        Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isLinux)) {
      throw UnsupportedError('Mobile POSIX storage required');
    }
    // Open an already-created file: avoiding open(O_CREAT, mode...) also avoids
    // Darwin ARM64's distinct variadic ABI. flock is per open-file description.
    final fd = _path(path, (p) => _open(p, 2));
    if (fd < 0) throw StateError('Private spool lock unavailable');
    if (_flock(fd, 2 | 4) != 0) {
      _close(fd);
      throw StateError('Spool already owned');
    }
    return PosixOwner._(fd);
  }

  void close() {
    if (!_closed) {
      _closed = true;
      _close(_fd);
    }
  }
}
