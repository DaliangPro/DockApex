#!/bin/bash
set -euo pipefail
dockfolders_root="$(cd "$(dirname "$0")" && pwd)"
dockfolders_build="$dockfolders_root/build"
dockfolders_app="$dockfolders_build/DockFolders.app"
mkdir -p "$dockfolders_build/module-cache" "$dockfolders_build/clang-cache" "$dockfolders_app/Contents/MacOS" "$dockfolders_app/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$dockfolders_build/clang-cache"

xcrun swift -swift-version 6 -module-cache-path "$dockfolders_build/module-cache" \
  "$dockfolders_root/Tools/GenerateAppIcon.swift" "$dockfolders_build/app-icon"
cp "$dockfolders_build/app-icon/DockFolders.icns" "$dockfolders_app/Contents/Resources/DockFolders.icns"

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

python3 - "$dockfolders_app" "$dockfolders_root" <<'PY'
import plistlib, sys
from pathlib import Path
app, root = Path(sys.argv[1]), sys.argv[2]
info = {
    'CFBundleExecutable': 'DockFolders',
    'CFBundleIdentifier': 'io.daliang.dockfolders',
    'CFBundleName': 'DockFolders',
    'CFBundleDisplayName': 'Dock 文件夹',
    'CFBundleIconFile': 'DockFolders',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '9',
    'CFBundleShortVersionString': '0.9.0',
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
    'WorkspaceRoot': root,
    'NSHumanReadableCopyright': '本机个人使用版本',
    'NSAppleEventsUsageDescription': '清倒废纸篓时要请访达执行，与系统 Dock 相同。',
    'CFBundleURLTypes': [{'CFBundleURLName': 'Dock 文件夹分组', 'CFBundleURLSchemes': ['dockfolders']}]
}
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f, sort_keys=False)
PY
plutil -lint "$dockfolders_app/Contents/Info.plist"
dockfolders_identity="${DOCKFOLDERS_SIGN_IDENTITY:--}"
if [ "$dockfolders_identity" = - ] && security find-identity -v -p codesigning | grep -q '"Muse Local"'; then
  dockfolders_identity="Muse Local"
fi
codesign --force --sign "$dockfolders_identity" --identifier io.daliang.dockfolders "$dockfolders_app"
codesign --verify --deep "$dockfolders_app"
printf '已构建并校验：%s\n' "$dockfolders_app"
