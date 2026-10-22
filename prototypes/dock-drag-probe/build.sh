#!/bin/bash
set -euo pipefail

# 构建产物和编译缓存都留在本探针目录，不安装或启动应用。
probe_root="$(cd "$(dirname "$0")" && pwd)"
probe_build="$probe_root/build"
mkdir -p "$probe_build/module-cache" "$probe_build/clang-cache" "$probe_root/logs"
export CLANG_MODULE_CACHE_PATH="$probe_build/clang-cache"
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
  -module-cache-path "$probe_build/module-cache" \
  -framework AppKit -framework UniformTypeIdentifiers \
  "$probe_root/Sources/main.swift" -o "$probe_build/DockDragProbe"

for probe_kind in Source Target; do
  if [ "$probe_kind" = Source ]; then
    probe_role="拖拽源 A"
    probe_id="io.daliang.dockdragprobe.source"
  else
    probe_role="拖拽目标 B"
    probe_id="io.daliang.dockdragprobe.target"
  fi
  probe_app="$probe_build/DockProbe$probe_kind.app"
  mkdir -p "$probe_app/Contents/MacOS"
  cp "$probe_build/DockDragProbe" "$probe_app/Contents/MacOS/DockDragProbe"
  cat > "$probe_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DockDragProbe</string>
<key>CFBundleIdentifier</key><string>$probe_id</string>
<key>CFBundleName</key><string>DockProbe$probe_kind</string>
<key>CFBundleDisplayName</key><string>DockProbe$probe_kind</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>ProbeRole</key><string>$probe_role</string>
<key>ProbeRoot</key><string>$probe_root</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>仅记录应用拖放事件</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>com.apple.application-bundle</string></array>
</dict></array>
</dict></plist>
EOF
  plutil -lint "$probe_app/Contents/Info.plist"
  # 只给本地构建产物做临时签名，不使用开发者证书或系统密钥。
  codesign --force --sign - "$probe_app"
  codesign --verify --deep "$probe_app"
done
printf '编译完成，未安装或运行应用。\n%s\n%s\n' \
  "$probe_build/DockProbeSource.app" "$probe_build/DockProbeTarget.app"
