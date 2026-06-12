import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Minimal Dart FFI bindings for the usearch C API (HNSW approximate nearest
/// neighbour search), compiled into `libcactus.so`. Used as the scalable vector
/// index for document retrieval: an in-memory index is built and `save`d into
/// the corpus pack, then queried via a memory-mapped `view` (so even a very
/// large index isn't loaded fully into RAM).
///
/// Vectors are passed in as float32; the index stores them quantized (f16 by
/// default) to halve disk size.

// scalar_kind enum values (from usearch.h).
const int _scalarF32 = 1;
const int _scalarI8 = 4; // int8 quantization: ~lossless for cosine, 1 byte/dim.

// metric_kind enum values.
const int _metricCos = 1;

final class _UsearchInitOptions extends Struct {
  @Int32()
  external int metricKind;
  external Pointer<Void> metric;
  @Int32()
  external int quantization;
  @Size()
  external int dimensions;
  @Size()
  external int connectivity;
  @Size()
  external int expansionAdd;
  @Size()
  external int expansionSearch;
  @Bool()
  external bool multi;
}

typedef _InitNative = Pointer<Void> Function(
    Pointer<_UsearchInitOptions>, Pointer<Pointer<Utf8>>);
typedef _FreeNative = Void Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _FreeDart = void Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _ReserveNative = Void Function(
    Pointer<Void>, Size, Pointer<Pointer<Utf8>>);
typedef _ReserveDart = void Function(Pointer<Void>, int, Pointer<Pointer<Utf8>>);
typedef _AddNative = Void Function(Pointer<Void>, Uint64, Pointer<Void>, Int32,
    Pointer<Pointer<Utf8>>);
typedef _AddDart = void Function(
    Pointer<Void>, int, Pointer<Void>, int, Pointer<Pointer<Utf8>>);
typedef _SearchNative = Size Function(Pointer<Void>, Pointer<Void>, Int32, Size,
    Pointer<Uint64>, Pointer<Float>, Pointer<Pointer<Utf8>>);
typedef _SearchDart = int Function(Pointer<Void>, Pointer<Void>, int, int,
    Pointer<Uint64>, Pointer<Float>, Pointer<Pointer<Utf8>>);
typedef _PathNative = Void Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _PathDart = void Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _SizeNative = Size Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _SizeDart = int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);

DynamicLibrary _open() {
  if (Platform.isAndroid) return DynamicLibrary.open('libcactus.so');
  return DynamicLibrary.process();
}

final DynamicLibrary _lib = _open();

final _init = _lib.lookupFunction<_InitNative, _InitNative>('usearch_init');
final _free = _lib.lookupFunction<_FreeNative, _FreeDart>('usearch_free');
final _reserve =
    _lib.lookupFunction<_ReserveNative, _ReserveDart>('usearch_reserve');
final _add = _lib.lookupFunction<_AddNative, _AddDart>('usearch_add');
final _search = _lib.lookupFunction<_SearchNative, _SearchDart>('usearch_search');
final _save = _lib.lookupFunction<_PathNative, _PathDart>('usearch_save');
final _view = _lib.lookupFunction<_PathNative, _PathDart>('usearch_view');
final _load = _lib.lookupFunction<_PathNative, _PathDart>('usearch_load');
final _size = _lib.lookupFunction<_SizeNative, _SizeDart>('usearch_size');

/// One ANN result: the stored key and its cosine distance (0 = identical).
class UsearchHit {
  UsearchHit(this.key, this.distance);
  final int key;
  final double distance;
}

/// A usearch HNSW index over [dimensions]-dim vectors using cosine distance.
class UsearchIndex {
  UsearchIndex._(this._handle, this.dimensions);
  final Pointer<Void> _handle;
  final int dimensions;
  bool _closed = false;

  static Pointer<Pointer<Utf8>> _err() {
    final p = calloc<Pointer<Utf8>>();
    p.value = nullptr;
    return p;
  }

  static void _check(Pointer<Pointer<Utf8>> err, String op) {
    final msg = err.value;
    if (msg != nullptr) {
      final s = msg.toDartString();
      calloc.free(err);
      throw Exception('usearch $op failed: $s');
    }
    calloc.free(err);
  }

  static Pointer<Void> _make(int dimensions) {
    final opts = calloc<_UsearchInitOptions>();
    opts.ref
      ..metricKind = _metricCos
      ..metric = nullptr
      ..quantization = _scalarI8
      ..dimensions = dimensions
      ..connectivity = 0
      ..expansionAdd = 0
      ..expansionSearch = 0
      ..multi = false;
    final err = _err();
    final handle = _init(opts, err);
    calloc.free(opts);
    _check(err, 'init');
    return handle;
  }

  /// Creates a fresh in-memory index (for building, then [save]).
  factory UsearchIndex.create(int dimensions, {int capacity = 0}) {
    final idx = UsearchIndex._(_make(dimensions), dimensions);
    if (capacity > 0) idx.reserve(capacity);
    return idx;
  }

  /// Opens an existing index file memory-mapped (large indexes are NOT loaded
  /// fully into RAM) for querying.
  factory UsearchIndex.viewFile(String path, int dimensions) {
    final idx = UsearchIndex._(_make(dimensions), dimensions);
    final err = _err();
    final p = path.toNativeUtf8();
    _view(idx._handle, p, err);
    calloc.free(p);
    _check(err, 'view');
    return idx;
  }

  /// Loads an existing index file fully into RAM (for appending more vectors).
  factory UsearchIndex.loadFile(String path, int dimensions) {
    final idx = UsearchIndex._(_make(dimensions), dimensions);
    final err = _err();
    final p = path.toNativeUtf8();
    _load(idx._handle, p, err);
    calloc.free(p);
    _check(err, 'load');
    return idx;
  }

  void reserve(int capacity) {
    final err = _err();
    _reserve(_handle, capacity, err);
    _check(err, 'reserve');
  }

  void add(int key, Float32List vector) {
    assert(vector.length == dimensions);
    final buf = calloc<Float>(vector.length);
    buf.asTypedList(vector.length).setAll(0, vector);
    final err = _err();
    _add(_handle, key, buf.cast(), _scalarF32, err);
    calloc.free(buf);
    _check(err, 'add');
  }

  /// Returns up to [count] nearest neighbours to [query].
  List<UsearchHit> search(Float32List query, int count) {
    final qbuf = calloc<Float>(query.length);
    qbuf.asTypedList(query.length).setAll(0, query);
    final keys = calloc<Uint64>(count);
    final dists = calloc<Float>(count);
    final err = _err();
    final n = _search(_handle, qbuf.cast(), _scalarF32, count, keys, dists, err);
    final hits = <UsearchHit>[];
    final msg = err.value;
    if (msg == nullptr) {
      for (var i = 0; i < n; i++) {
        hits.add(UsearchHit(keys[i], dists[i]));
      }
    }
    calloc.free(qbuf);
    calloc.free(keys);
    calloc.free(dists);
    _check(err, 'search');
    return hits;
  }

  void save(String path) {
    final err = _err();
    final p = path.toNativeUtf8();
    _save(_handle, p, err);
    calloc.free(p);
    _check(err, 'save');
  }

  int get length {
    final err = _err();
    final n = _size(_handle, err);
    _check(err, 'size');
    return n;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final err = _err();
    _free(_handle, err);
    _check(err, 'free');
  }
}
