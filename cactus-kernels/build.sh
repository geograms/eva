#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building cactus-kernels..."

rm -rf build
mkdir -p build
cd build

cmake .. -DCMAKE_RULE_MESSAGES=OFF -DCMAKE_VERBOSE_MAKEFILE=OFF > /dev/null 2>&1
make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

echo "cactus-kernels built successfully!"
echo "Library: $(pwd)/libcactus_kernels.a"
