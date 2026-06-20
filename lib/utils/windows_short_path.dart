import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _GetShortPathNameC = Uint32 Function(
    Pointer<Utf16> lpszLongPath, Pointer<Utf16> lpszShortPath, Uint32 cchBuffer);
typedef _GetShortPathNameDart = int Function(
    Pointer<Utf16> lpszLongPath, Pointer<Utf16> lpszShortPath, int cchBuffer);

/// Returns the Windows 8.3 short path for [path] (ASCII-only), or [path]
/// unchanged when conversion isn't possible.
///
/// The bundled CLI fails to start when its path contains non-ASCII characters
/// (e.g. a Cyrillic install directory). Short paths sidestep that because they
/// are always ASCII. The file/dir must already exist for Windows to return one.
///
/// ponytail: 8.3 short names. If they're disabled on the volume, or the path
/// doesn't exist, GetShortPathNameW returns 0 and we fall back to the original
/// path — no worse than before.
String toShortPathName(String path) {
  if (!Platform.isWindows) return path;

  final lib = DynamicLibrary.open('kernel32.dll');
  final getShortPathName = lib
      .lookupFunction<_GetShortPathNameC, _GetShortPathNameDart>('GetShortPathNameW');

  final longPtr = path.toNativeUtf16();
  Pointer<Uint16> bufPtr = nullptr;
  try {
    // First call with a null buffer returns the required length (incl. null).
    final needed = getShortPathName(longPtr, nullptr, 0);
    if (needed == 0) return path;

    bufPtr = malloc<Uint16>(needed);
    final written = getShortPathName(longPtr, bufPtr.cast<Utf16>(), needed);
    if (written == 0 || written >= needed) return path;

    return bufPtr.cast<Utf16>().toDartString();
  } catch (_) {
    return path;
  } finally {
    malloc.free(longPtr);
    if (bufPtr != nullptr) malloc.free(bufPtr);
  }
}
