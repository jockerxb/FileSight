#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache -c release --product QianLiYan
swift build --disable-sandbox --cache-path .build/cache -c release --product ScanWorker
mkdir -p "$PWD/dist"
staging=$(mktemp -d "$PWD/.build/filesight-package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/千里眼.app"
signature=(--sign -)
case "${1:---preview}" in
    --preview) ;;
    --sign-for-distribution)
        identity=${FILESIGHT_SIGN_IDENTITY:-}
        if [[ "$identity" != 'Developer ID Application:'* ]]; then
            print -u2 '需要有效的 Developer ID Application 签名身份。'
            exit 1
        fi
        signature=(--sign "$identity" --options runtime --timestamp)
        ;;
    *) print -u2 '用法：build-app.sh [--preview|--sign-for-distribution]'; exit 1 ;;
esac
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
iconset="$staging/QianLiYan.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/branding/qianliyan-app-icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" assets/branding/qianliyan-app-icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/QianLiYan.icns"
cp .build/release/QianLiYan "$app/Contents/MacOS/QianLiYan"
cp .build/release/ScanWorker "$app/Contents/MacOS/ScanWorker"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QianLiYan</string>
<key>CFBundleIdentifier</key><string>local.qianliyan.search</string>
<key>CFBundleName</key><string>千里眼</string>
<key>CFBundleDisplayName</key><string>千里眼</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>QianLiYan.icns</string>
<key>CFBundleShortVersionString</key><string>2.2</string>
<key>CFBundleVersion</key><string>28</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force "${signature[@]}" --entitlements Security/Worker.entitlements "$app/Contents/MacOS/ScanWorker"
codesign --force "${signature[@]}" --entitlements Security/App.entitlements "$app"
python3 scripts/verify-entitlements.py "$app"
archive="$staging/FileSight.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
if [[ -e "$PWD/dist/千里眼.app" ]]; then
    mv "$PWD/dist/千里眼.app" "$staging/previous.app"
fi
if ! mv "$app" "$PWD/dist/千里眼.app"; then
    if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" "$PWD/dist/千里眼.app"; fi
    exit 1
fi
mv -f "$archive" "$PWD/dist/FileSight.zip"
print '已打包未公证的构建：dist/FileSight.zip'
