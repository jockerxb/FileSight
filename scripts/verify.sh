#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache --product ScanWorker
swift run --disable-sandbox --cache-path .build/cache SearchVerification
swift run --disable-sandbox --cache-path .build/cache -c release QuickSearchVerification
swift build --disable-sandbox --cache-path .build/cache -c release --product ScanWorker
swift run --disable-sandbox --cache-path .build/cache -c release DatabaseVerification
