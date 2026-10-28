#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox -c release --arch arm64
/bin/zsh scripts/build-icon.sh
app="${1:-$PWD/dist/CC登录器.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binary_dir="$(swift build --disable-sandbox -c release --arch arm64 --show-bin-path)"
cp "$binary_dir/CCGuard" "$app/Contents/MacOS/CCGuard"
cp Resources/extract-detection.js "$app/Contents/Resources/"
cp Resources/background-probe.js "$app/Contents/Resources/"
cp .build/AppIcon.icns "$app/Contents/Resources/"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --identifier org.ccguard.launcher "$app"
codesign --verify --strict "$app"
print "$app"
