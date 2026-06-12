#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building and testing cactus-graph..."

rm -rf build
mkdir -p build
cd build

cmake .. -DCACTUS_BUILD_TESTS=ON -DCMAKE_RULE_MESSAGES=OFF -DCMAKE_VERBOSE_MAKEFILE=OFF > /dev/null 2>&1
make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

echo ""
FAILED=0
for test_bin in test_*; do
    [ -x "$test_bin" ] && ./"$test_bin" || FAILED=1
done

exit $FAILED
