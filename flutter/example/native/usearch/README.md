# Vendored: usearch

Source: https://github.com/unum-cloud/usearch (tag v2.25.3), Apache-2.0 (see LICENSE).

Vendored files: the C binding (`usearch.h`, `lib.cpp`) and the header-only core
(`include/usearch/`). Compiled into `libcactus.so` (see ../CMakeLists.txt) with
`USEARCH_USE_SIMSIMD=0 USEARCH_USE_FP16LIB=0`. Exposes the `usearch_*` C symbols
used by `lib/usearch.dart` for on-device ANN (HNSW) vector search.
