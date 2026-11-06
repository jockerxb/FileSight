#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path .build/cache -c release --product QianLiYan
swift build --disable-sandbox --cache-path .build/cache -c release --product ScanWorker
app="$PWD/dist/千里眼.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
iconset="$PWD/.build/QianLiYan.iconset"
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
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSDocumentsFolderUsageDescription</key><string>扫描文稿目录中的文件名以提供搜索。</string>
<key>NSDesktopFolderUsageDescription</key><string>扫描桌面上的文件名以提供搜索。</string>
<key>NSDownloadsFolderUsageDescription</key><string>扫描下载目录中的文件名以提供搜索。</string>
<key>NSRemovableVolumesUsageDescription</key><string>搜索已挂载磁盘中的文件名。</string>
</dict></plist>
PLIST
codesign --force --sign - --entitlements Security/Worker.entitlements "$app/Contents/MacOS/ScanWorker"
codesign --force --sign - --entitlements Security/App.entitlements "$app"
codesign --verify --strict "$app"
python3 scripts/verify-entitlements.py "$app"
archive="$PWD/dist/FileSight.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
print "已打包：$archive（内含千里眼.app）"
