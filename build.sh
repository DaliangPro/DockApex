#!/bin/bash
set -euo pipefail
dockfolders_root="$(cd "$(dirname "$0")" && pwd)"
dockfolders_build="$dockfolders_root/build"
dockfolders_version="$(tr -d '[:space:]' < "$dockfolders_root/VERSION")"
# DOCKFOLDERS_RELEASE=1 构建安装包里的应用（由 package.sh 调用，输出位置由 DOCKFOLDERS_RELEASE_APP 指定）：
# 不写项目路径，数据放在“应用支持”。平时的开发版仍是 build/DockFolders.app，数据在项目的 Data/。
if [ "${DOCKFOLDERS_RELEASE:-0}" = 1 ]; then
  dockfolders_app="${DOCKFOLDERS_RELEASE_APP:?需要 DOCKFOLDERS_RELEASE_APP 指定安装版的输出位置，请用 package.sh 打包}"
  dockfolders_workspace=""
else
  dockfolders_app="$dockfolders_build/DockFolders.app"
  dockfolders_workspace="$dockfolders_root"
fi
mkdir -p "$dockfolders_build/module-cache" "$dockfolders_build/clang-cache" "$dockfolders_app/Contents/MacOS" "$dockfolders_app/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$dockfolders_build/clang-cache"

cp "$dockfolders_root/Resources/DockFolders.icns" "$dockfolders_app/Contents/Resources/DockFolders.icns"

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -target arm64-apple-macosx14.0 \
  -module-cache-path "$dockfolders_build/module-cache" \
  -framework AppKit "$dockfolders_root"/Sources/GroupEntry/*.swift \
  -o "$dockfolders_app/Contents/Resources/GroupEntry"

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -target arm64-apple-macosx14.0 \
  -module-cache-path "$dockfolders_build/module-cache" \
  -framework AppKit "$dockfolders_root"/Sources/DockTileHost/*.swift \
  -o "$dockfolders_app/Contents/Resources/DockTileHost"

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -target arm64-apple-macosx14.0 \
  -module-cache-path "$dockfolders_build/module-cache" -framework AppKit \
  "$dockfolders_root/Sources/DockFolders/NativeDockCoordinator.swift" \
  "$dockfolders_root/Sources/DockFolders/DockStopGuard.swift" \
  "$dockfolders_root/Sources/DockFolders/DockSystemRegion.swift" \
  "$dockfolders_root/Sources/DockRestoreAgent/main.swift" \
  -o "$dockfolders_app/Contents/Resources/DockRestoreAgent"

xcrun swiftc -O -whole-module-optimization -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macosx14.0 \
  -module-cache-path "$dockfolders_build/module-cache" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework CoreGraphics -framework Carbon -framework ScreenCaptureKit \
  "$dockfolders_root"/Sources/DockFolders/*.swift "$dockfolders_root"/Sources/DockLayoutCore/*.swift \
  -o "$dockfolders_app/Contents/MacOS/DockFolders"

python3 - "$dockfolders_app" "$dockfolders_workspace" "$dockfolders_version" <<'PY'
import plistlib, sys
from pathlib import Path
app, root, version = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
info = {
    'CFBundleExecutable': 'DockFolders',
    'CFBundleIdentifier': 'io.daliang.dockfolders',
    'CFBundleDevelopmentRegion': 'zh-Hans',
    # 显示名 DockApex 写在本地化文件里；这里的原始名称要与开发版文件名 DockFolders.app 一致，
    # 访达和系统搜索才采用本地化名称，否则当作文件被改过名、直接显示文件名。
    'CFBundleName': 'DockFolders',
    'CFBundleDisplayName': 'DockFolders',
    'LSHasLocalizedDisplayName': True,
    'CFBundleIconFile': 'DockFolders',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': version,
    'CFBundleShortVersionString': version,
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
    'NSHumanReadableCopyright': '© 2026 DaliangPro. All rights reserved.',
    'NSAppleEventsUsageDescription': '清倒废纸篓时要请访达执行，与系统 Dock 相同。',
    'CFBundleURLTypes': [{'CFBundleURLName': 'DockApex 分组', 'CFBundleURLSchemes': ['dockfolders']}]
}
if root:
    info['WorkspaceRoot'] = root
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f, sort_keys=False)
for language in ('zh-Hans', 'en'):
    strings = app / 'Contents/Resources' / f'{language}.lproj'
    strings.mkdir(parents=True, exist_ok=True)
    (strings / 'InfoPlist.strings').write_text('"CFBundleDisplayName" = "DockApex";\n"CFBundleName" = "DockApex";\n', encoding='utf-8')
PY
plutil -lint "$dockfolders_app/Contents/Info.plist"
dockfolders_identity="${DOCKFOLDERS_SIGN_IDENTITY:--}"
if [ "$dockfolders_identity" = - ] && security find-identity -v -p codesigning | grep -q '"Muse Local"'; then
  dockfolders_identity="Muse Local"
fi
# 辅助程序先用同一身份签名，再签应用包。
for dockfolders_helper in GroupEntry DockTileHost DockRestoreAgent; do
  codesign --force --sign "$dockfolders_identity" "$dockfolders_app/Contents/Resources/$dockfolders_helper"
done
codesign --force --sign "$dockfolders_identity" --identifier io.daliang.dockfolders "$dockfolders_app"
codesign --verify --deep "$dockfolders_app"
printf '已构建并校验：%s\n' "$dockfolders_app"
