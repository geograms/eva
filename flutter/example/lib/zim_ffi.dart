import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Low-level dart:ffi bindings to libzimffi.so (our C shim over libzim). See
// native_zim/zimffi.cpp. Search/suggest return JSON; content returns raw bytes.

typedef _SetIcuNative = Void Function(Pointer<Utf8>);
typedef _SetIcuDart = void Function(Pointer<Utf8>);
typedef _OpenNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _OpenDart = Pointer<Void> Function(Pointer<Utf8>);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _HasFtNative = Int32 Function(Pointer<Void>);
typedef _HasFtDart = int Function(Pointer<Void>);
typedef _StrQueryNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _StrQueryDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _MainPathNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _MainPathDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _GetNative = Pointer<Uint8> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Int32>);
typedef _GetDart = Pointer<Uint8> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>, Pointer<Int32>);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

/// A full-text/title hit from a ZIM archive.
class ZimHit {
  ZimHit({required this.path, required this.title, this.score = 0, this.snippet = ''});
  final String path;
  final String title;
  final int score;
  final String snippet;
}

/// Fetched ZIM entry: raw bytes + mimetype (for the WebView/reader).
class ZimContent {
  ZimContent(this.bytes, this.mimetype);
  final Uint8List bytes;
  final String mimetype;
}

/// Thin wrapper over the libzimffi shim. Loads the library lazily; [available]
/// is false when the native lib couldn't be loaded (e.g. unsupported build).
class ZimFfi {
  ZimFfi._(this._lib);

  final DynamicLibrary _lib;
  static ZimFfi? _instance;
  static bool _triedLoad = false;

  /// Singleton accessor; returns null if the native library isn't loadable.
  static ZimFfi? instance() {
    if (_triedLoad) return _instance;
    _triedLoad = true;
    try {
      final lib = Platform.isAndroid
          ? DynamicLibrary.open('libzimffi.so')
          : DynamicLibrary.process();
      _instance = ZimFfi._(lib);
    } catch (_) {
      _instance = null;
    }
    return _instance;
  }

  static bool get available => instance() != null;

  late final _setIcu =
      _lib.lookupFunction<_SetIcuNative, _SetIcuDart>('zimffi_set_icu_data');
  late final _open =
      _lib.lookupFunction<_OpenNative, _OpenDart>('zimffi_open');
  late final _close =
      _lib.lookupFunction<_CloseNative, _CloseDart>('zimffi_close');
  late final _hasFt =
      _lib.lookupFunction<_HasFtNative, _HasFtDart>('zimffi_has_fulltext');
  late final _search =
      _lib.lookupFunction<_StrQueryNative, _StrQueryDart>('zimffi_search');
  late final _suggest =
      _lib.lookupFunction<_StrQueryNative, _StrQueryDart>('zimffi_suggest');
  late final _mainPath =
      _lib.lookupFunction<_MainPathNative, _MainPathDart>('zimffi_main_path');
  late final _get = _lib.lookupFunction<_GetNative, _GetDart>('zimffi_get');
  late final _free =
      _lib.lookupFunction<_FreeNative, _FreeDart>('zimffi_free');

  /// Points libzim's ICU at its data directory (Android ships icudt*.dat
  /// separately). Call once before opening archives.
  void setIcuDataDir(String dir) {
    final p = dir.toNativeUtf8();
    try {
      _setIcu(p);
    } finally {
      malloc.free(p);
    }
  }

  /// Opens a `.zim`; returns an opaque handle, or null on failure.
  Pointer<Void>? open(String path) {
    final p = path.toNativeUtf8();
    try {
      final h = _open(p);
      return h == nullptr ? null : h;
    } finally {
      malloc.free(p);
    }
  }

  void close(Pointer<Void> handle) => _close(handle);

  bool hasFulltext(Pointer<Void> handle) => _hasFt(handle) != 0;

  String mainPath(Pointer<Void> handle) => _takeString(_mainPath(handle));

  List<ZimHit> search(Pointer<Void> handle, String query, {int k = 5}) =>
      _hits(_callStrQuery(_search, handle, query, k), withScore: true);

  List<ZimHit> suggest(Pointer<Void> handle, String query, {int k = 5}) =>
      _hits(_callStrQuery(_suggest, handle, query, k), withScore: false);

  /// Fetches an entry's bytes + mimetype, or null when missing.
  ZimContent? get(Pointer<Void> handle, String path) {
    final p = path.toNativeUtf8();
    final outMime = malloc<Pointer<Utf8>>();
    final outLen = malloc<Int32>();
    try {
      final ptr = _get(handle, p, outMime, outLen);
      if (ptr == nullptr) return null;
      final len = outLen.value;
      final bytes = Uint8List.fromList(ptr.asTypedList(len));
      _free(ptr.cast());
      final mime = _takeString(outMime.value);
      return ZimContent(bytes, mime);
    } finally {
      malloc.free(p);
      malloc.free(outMime);
      malloc.free(outLen);
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  String _callStrQuery(
      _StrQueryDart fn, Pointer<Void> handle, String query, int k) {
    final q = query.toNativeUtf8();
    try {
      return _takeString(fn(handle, q, k));
    } finally {
      malloc.free(q);
    }
  }

  /// Reads a malloc'd C string, frees it, returns Dart string ('' if null).
  String _takeString(Pointer<Utf8> ptr) {
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString();
    } finally {
      _free(ptr.cast());
    }
  }

  List<ZimHit> _hits(String json, {required bool withScore}) {
    if (json.isEmpty) return const [];
    try {
      final list = jsonDecode(json) as List;
      return [
        for (final e in list)
          ZimHit(
            path: e['path'] as String? ?? '',
            title: e['title'] as String? ?? '',
            score: withScore ? (e['score'] as num?)?.toInt() ?? 0 : 0,
            snippet: e['snippet'] as String? ?? '',
          ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
