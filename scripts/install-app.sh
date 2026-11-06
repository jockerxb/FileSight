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
codesign --verify --deep --strict "$source_app"
python3 scripts/verify-entitlements.py "$source_app"
ditto "$source_app" "$destination"
# ditto preserves the old directory date; explicitly invalidate app metadata.
touch "$destination"
# A build artifact may already be unregistered on a repeat install.
"$registrar" -u "$source_app" >/dev/null 2>&1 || true
"$registrar" -f "$destination"
codesign --verify --deep --strict "$destination"
print '已安装并刷新千里眼图标注册。启动器若仍显示旧缓存，关闭后重新打开。'
