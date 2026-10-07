#!/bin/zsh
set -eu
prototype_root="${0:A:h:h}"
cd "$prototype_root"
verify_originals=0
if [[ -f original-hashes.json ]]; then
  verify_originals=1
  python3 scripts/verify_originals.py --snapshot original-test-baseline.json
  python3 scripts/verify_originals.py --baseline original-test-baseline.json > original-check-before-tests.json
fi
export CLANG_MODULE_CACHE_PATH="$prototype_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$prototype_root/.build/module-cache"
# The native backend avoids file-provider FinderInfo on SwiftBuild's signed
# XCTest bundle on this Mac. No dependencies are downloaded by this package.
test_status=0
swift test --build-system native --disable-sandbox --scratch-path .build-native --cache-path .build/cache --config-path .build/config --security-path .build/security || test_status=$?
if [[ "$verify_originals" == 1 ]]; then
  python3 scripts/verify_originals.py --baseline original-test-baseline.json > original-check-after-tests.json
fi
exit "$test_status"
