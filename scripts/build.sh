#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
# Release builds require an explicitly selected, stable signing identity.
# Community source builds may deliberately opt into ad-hoc signing.
signing_identity="${TS_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    if [ "${TS_ALLOW_ADHOC:-0}" = "1" ]; then
        signing_identity="-"
        echo "Local ad-hoc build: macOS privacy grants may need renewal after updates." >&2
    else
        echo "Set TS_SIGNING_IDENTITY to your Apple certificate, or TS_ALLOW_ADHOC=1 for a local source build." >&2
        exit 1
    fi
fi
if [ "$signing_identity" = "-" ] && [ "${TS_ALLOW_ADHOC:-0}" != "1" ]; then
    echo "Ad-hoc signing requires explicit TS_ALLOW_ADHOC=1." >&2
    exit 1
fi
# Do not embed the builder's home directory in the distributed executable.
swift build -c release --arch arm64 --arch x86_64 --disable-sandbox \
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=." \
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=." \
    -Xswiftc -file-compilation-dir -Xswiftc .
release_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
output_dir="${TS_OUTPUT_DIR:-$PWD/dist/$release_version}"
app="$output_dir/T&S.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binary_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path --disable-sandbox)"
cp "$binary_dir/TSApp" "$app/Contents/MacOS/TSApp"
# Mach-O debug-map entries can retain absolute object/module paths even after
# Swift's prefix mapping. Remove those entries before signing the final binary.
/usr/bin/strip -S "$app/Contents/MacOS/TSApp"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
cp LICENSE "$app/Contents/Resources/LICENSE"
/usr/bin/codesign --force --options runtime --sign "$signing_identity" "$app"
/usr/bin/codesign --verify --strict --verbose=2 "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/TandS-macOS.zip"
cp README.md "$output_dir/TandS-Setup.md"
cp "docs/UPDATE-$release_version.md" "$output_dir/Update-instructions.md"
echo "Built: $app"
