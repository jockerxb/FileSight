#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source_app="$PWD/dist/千里眼.app"
destination="/Applications/千里眼.app"
registrar="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if pgrep -x QianLiYan >/dev/null; then
    print -u2 '请先退出千里眼，再安装更新。'
    exit 1
fi
python3 scripts/verify-entitlements.py "$source_app"
if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" ]] ||
       [[ "$(plutil -extract CFBundleIdentifier raw "$destination/Contents/Info.plist")" != 'local.qianliyan.search' ]]; then
        print -u2 '安装位置不是千里眼应用包，已停止。'
        exit 1
    fi
fi
stage=$(mktemp -d '/Applications/.filesight-install.XXXXXX')
trap 'rm -rf "$stage"' EXIT
ditto "$source_app" "$stage/千里眼.app"
python3 scripts/verify-entitlements.py "$stage/千里眼.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$stage/previous.app"
fi
if ! mv "$stage/千里眼.app" "$destination"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$destination"; fi
    exit 1
fi
# ditto preserves the old directory date; explicitly invalidate app metadata.
touch "$destination"
"$registrar" -u "$source_app" >/dev/null 2>&1 || true
"$registrar" -f "$destination"
codesign --verify --deep --strict "$destination"
print '已安装并刷新千里眼图标注册。启动器若仍显示旧缓存，关闭后重新打开。'
