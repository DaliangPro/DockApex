#!/bin/bash
set -euo pipefail
parity_root="$(cd "$(dirname "$0")/../.." && pwd)"
parity_build="$parity_root/build"
parity_app="$parity_build/DockParityFixture.app"
mkdir -p "$parity_app/Contents/MacOS" "$parity_app/Contents/Resources"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  "$parity_root/Tools/NativeParityProbe.swift" -o "$parity_build/NativeParityProbe"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -D PARITY_FIXTURE \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  "$parity_root/Tools/NativeParityProbe.swift" "$parity_root/Tools/ParityFixture/main.swift" \
  -o "$parity_app/Contents/MacOS/DockParityFixture"
python3 - "$parity_app" "$parity_root" <<'PY'
from pathlib import Path
import os,plistlib,sys
app=Path(sys.argv[1])
info={
 'CFBundleExecutable':'DockParityFixture',
 'CFBundleIdentifier':'io.daliang.dockfolders.parityfixture',
 'CFBundleName':'DockParityFixture',
 'CFBundleDisplayName':'DockParityFixture',
 'CFBundlePackageType':'APPL',
 'CFBundleVersion':'1',
 'CFBundleShortVersionString':'0.1.0',
 'LSMinimumSystemVersion':'14.0',
 'LSUIElement':False,
 'NSHighResolutionCapable':True,
 'ParityDiagnosticsRoot':os.environ.get('DOCKFOLDERS_DIAGNOSTICS_ROOT',str(Path(sys.argv[2])/'Data/Diagnostics/ParityFixture')),
}
with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump(info,f)
PY
parity_identity="${DOCKFOLDERS_SIGN_IDENTITY:--}"
if [ "$parity_identity" = - ] && security find-identity -v -p codesigning | grep -q '"Muse Local"'; then
  parity_identity="Muse Local"
fi
codesign --force --sign "$parity_identity" --identifier io.daliang.dockfolders.parityfixture "$parity_app"
codesign --verify --strict "$parity_app"
plutil -lint "$parity_app/Contents/Info.plist"
printf '已构建，尚未启动可见夹具：%s\n' "$parity_app"
