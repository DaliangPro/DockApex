#!/bin/bash
# 生成发布用的安装包：构建安装版应用（数据放在“应用支持”，不依赖项目目录），签名后做成 DMG。
# 输出 build/release/DockApex-<版本>.dmg；版本号取自 VERSION。
# 安装版在临时目录里构建、直接放进映像，项目里只留 DMG：留在项目里的应用包会被系统搜索收录，
# 和开发版包名相同，系统还可能启动它而不是开发版。
set -euo pipefail
dockfolders_root="$(cd "$(dirname "$0")" && pwd)"
dockfolders_version="$(tr -d '[:space:]' < "$dockfolders_root/VERSION")"
dockfolders_release="$dockfolders_root/build/release"
dockfolders_dmg="$dockfolders_release/DockApex-$dockfolders_version.dmg"
mkdir -p "$dockfolders_release"

# 映像里放应用和指向“应用程序”文件夹的替身，打开后把应用拖过去即可安装。
dockfolders_staging="$(mktemp -d)/DockApex $dockfolders_version"
dockfolders_app="$dockfolders_staging/DockApex.app"
DOCKFOLDERS_RELEASE=1 DOCKFOLDERS_RELEASE_APP="$dockfolders_app" bash "$dockfolders_root/build.sh"

# 安装版不能带项目路径，版本号要与 VERSION 一致。
if /usr/libexec/PlistBuddy -c 'Print :WorkspaceRoot' "$dockfolders_app/Contents/Info.plist" >/dev/null 2>&1; then
  printf '安装版不应带 WorkspaceRoot：%s\n' "$dockfolders_app" >&2; exit 1
fi
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dockfolders_app/Contents/Info.plist")" = "$dockfolders_version" ]

ln -s /Applications "$dockfolders_staging/Applications"
hdiutil create -quiet -ov -volname "DockApex $dockfolders_version" -srcfolder "$dockfolders_staging" \
  -fs HFS+ -format UDZO "$dockfolders_dmg"

dockfolders_identity="${DOCKFOLDERS_SIGN_IDENTITY:--}"
if [ "$dockfolders_identity" = - ] && security find-identity -v -p codesigning | grep -q '"Muse Local"'; then
  dockfolders_identity="Muse Local"
fi
codesign --force --sign "$dockfolders_identity" "$dockfolders_dmg"
codesign --verify "$dockfolders_dmg"
hdiutil verify -quiet "$dockfolders_dmg"
printf '已生成安装包：%s\nSHA-256：%s\n' "$dockfolders_dmg" "$(shasum -a 256 "$dockfolders_dmg" | cut -d' ' -f1)"
