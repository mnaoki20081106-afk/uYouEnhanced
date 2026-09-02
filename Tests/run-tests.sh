#!/bin/bash
# Off-device tests for the Learning Mode filter.
#
#   Tests/run-tests.sh
#
# LearningFilterScan.m is pure C, so it runs anywhere. The store and decision
# layer need a Foundation: on macOS the system one is used, on Linux GNUstep
# (apt install gnustep-base-runtime libgnustep-base-dev libblocksruntime-dev).
# Neither test needs an iOS device or a built tweak.
set -u
cd "$(dirname "$0")/.." || exit 1
BUILD=${BUILD_DIR:-/tmp/uye-learning-filter-tests}
mkdir -p "$BUILD"
status=0

echo "== scanner (pure C) =="
clang -std=c11 -Wall -Wextra -I Sources -x c \
    Tests/LearningFilterScanTests.c Sources/LearningFilterScan.m -o "$BUILD/scan" || exit 1
"$BUILD/scan" || status=1

echo "== store and decision layer =="
if [ "$(uname)" = "Darwin" ]; then
    clang -fobjc-arc -fblocks -I Sources \
        Tests/LearningFilterLogicTests.m Sources/LearningFilterCore.m Sources/LearningFilterScan.m \
        -framework Foundation -o "$BUILD/logic" || exit 1
else
    command -v gnustep-config >/dev/null || { echo "SKIP: GNUstep not installed"; exit $status; }
    GCC_INC=$(ls -d /usr/lib/gcc/x86_64-linux-gnu/*/include 2>/dev/null | tail -1)
    # GNUstep here uses the GCC runtime, which has no ARC; the tests only
    # exercise logic, so running without ARC (and leaking) is fine.
    clang -fblocks -fno-objc-arc -fobjc-runtime=gcc $(gnustep-config --objc-flags) \
        -Wno-unused-parameter -Wno-deprecated-declarations \
        -I "$GCC_INC" -I Sources -I Tests/hostinc -include Tests/hostinc/hostshim.h \
        Tests/LearningFilterLogicTests.m Sources/LearningFilterCore.m Sources/LearningFilterScan.m \
        -o "$BUILD/logic" $(gnustep-config --base-libs) -lBlocksRuntime || exit 1
fi
"$BUILD/logic" || status=1

exit $status
