import 'dart:ffi';

import 'package:ffi/ffi.dart';

// Free-space lookup via libc `statvfs` (no plugin needed). Android/arm64 only —
// the struct field offsets below assume 64-bit `unsigned long` / `fsblkcnt_t`.
//
//   struct statvfs { unsigned long f_bsize, f_frsize; fsblkcnt_t f_blocks,
//                    f_bfree, f_bavail; ... }
// As an array of 64-bit words: [0]=f_bsize [1]=f_frsize [2]=f_blocks
// [3]=f_bfree [4]=f_bavail. Free bytes available to us = f_bavail * f_frsize.

typedef _StatvfsNative = Int32 Function(Pointer<Utf8>, Pointer<Uint64>);
typedef _StatvfsDart = int Function(Pointer<Utf8>, Pointer<Uint64>);

/// Bytes free for new data at [path]'s filesystem, or null if it can't be
/// determined (caller should then not block on the check).
int? freeBytesForPath(String path) {
  try {
    final statvfs = DynamicLibrary.process()
        .lookupFunction<_StatvfsNative, _StatvfsDart>('statvfs');
    final p = path.toNativeUtf8();
    final buf = calloc<Uint64>(16); // 128 bytes — comfortably covers the struct
    try {
      if (statvfs(p, buf) != 0) return null;
      final frsize = buf[1];
      final bavail = buf[4];
      if (frsize == 0) return null;
      return bavail * frsize;
    } finally {
      malloc.free(p);
      calloc.free(buf);
    }
  } catch (_) {
    return null;
  }
}

/// Human-readable size, e.g. "937 MB" / "1.4 GB".
String formatBytes(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).round()} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).round()} KB';
  return '$bytes B';
}
