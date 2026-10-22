#!/bin/bash
set -euo pipefail
bug_fixture_root="$(cd "$(dirname "$0")/../.." && pwd)"
bug_fixture_app="$bug_fixture_root/build/DockBugFixture.app"
mkdir -p "$bug_fixture_app/Contents/MacOS"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target arm64-apple-macosx14.0 -module-cache-path "$bug_fixture_root/build/module-cache" \
  -framework AppKit -framework CoreGraphics "$bug_fixture_root/Tools/DockBugFixture/main.swift" \
  -o "$bug_fixture_app/Contents/MacOS/DockBugFixture"
python3 - "$bug_fixture_app" "$bug_fixture_root" <<'PY'
from pathlib import Path
import os, plistlib, sys
app, root = Path(sys.argv[1]), Path(sys.argv[2])
info = {
    'CFBundleExecutable': 'DockBugFixture',
    'CFBundleIdentifier': 'io.daliang.dockfolders.bugfixture',
    'CFBundleName': 'DockBugFixture',
    'CFBundleDisplayName': 'Dock 五项修复夹具',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'CFBundleShortVersionString': '0.1.0',
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': False,
    'NSHighResolutionCapable': True,
    'BugFixtureDiagnosticsRoot': os.environ.get('DOCKFOLDERS_DIAGNOSTICS_ROOT',str(root / 'Data/Diagnostics/五项修复-fixture')),
}
with (app / 'Contents/Info.plist').open('wb') as destination:
    plistlib.dump(info, destination, sort_keys=False)
PY
bug_fixture_identity="${DOCKFOLDERS_SIGN_IDENTITY:--}"
if [ "$bug_fixture_identity" = - ] && security find-identity -v -p codesigning | grep -q '"Muse Local"'; then
  bug_fixture_identity="Muse Local"
fi
codesign --force --sign "$bug_fixture_identity" --identifier io.daliang.dockfolders.bugfixture "$bug_fixture_app"
codesign --verify --strict "$bug_fixture_app"
plutil -lint "$bug_fixture_app/Contents/Info.plist"
printf '已构建，尚未启动：%s\n' "$bug_fixture_app"
