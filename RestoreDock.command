#!/bin/bash
set -u

# 从 Finder 双击即可使用；恢复不依赖主应用界面或辅助功能权限。
dockfolders_root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
dockfolders_main="$dockfolders_root/build/DockFolders.app/Contents/MacOS/DockFolders"
dockfolders_restore_agent="$dockfolders_root/build/DockFolders.app/Contents/Resources/DockRestoreAgent"
dockfolders_host_status=69
dockfolders_legacy_status=69
dockfolders_region_status=69

printf '\n第一步：正常退出主应用，并条件恢复原生 Dock 分组……\n'
if [[ -x "$dockfolders_main" ]]; then
  # 旧主程序不识别 CLI 时会直接打开应用；先核对命令标记，避免误启动旧版本。
  if /usr/bin/strings "$dockfolders_main" | /usr/bin/grep -F -- '--restore-native-host' >/dev/null; then
    "$dockfolders_main" --restore-native-host --data-directory "$dockfolders_root/Data"
    dockfolders_host_status=$?
  else
    printf '当前主程序没有原生分组恢复命令。请先在项目目录运行 bash build.sh。\n'
  fi
else
  printf '找不到可执行的主程序：\n%s\n请先在项目目录运行 bash build.sh。\n' "$dockfolders_main"
fi

printf '\n第二步：条件恢复本工具登记的系统预留区……\n'
if [[ -x "$dockfolders_restore_agent" ]]; then
  "$dockfolders_restore_agent" --restore-region --data-directory "$dockfolders_root/Data"
  dockfolders_region_status=$?
fi

printf '\n第三步：检查系统 Dock 隐藏配置……\n'
if [[ -x "$dockfolders_restore_agent" ]]; then
  "$dockfolders_restore_agent" --restore --data-directory "$dockfolders_root/Data"
  dockfolders_legacy_status=$?
else
  printf '找不到可执行的旧配置恢复程序：\n%s\n' "$dockfolders_restore_agent"
fi

if [[ "$dockfolders_host_status" -eq 0 && "$dockfolders_region_status" -eq 0 && "$dockfolders_legacy_status" -eq 0 ]]; then
  dockfolders_restore_status=0
  printf '\n三项恢复检查均已完成；具体恢复结果以上方核对为准。\n'
else
  dockfolders_restore_status="$dockfolders_host_status"
  if [[ "$dockfolders_restore_status" -eq 0 ]]; then dockfolders_restore_status="$dockfolders_legacy_status"; fi
  if [[ "$dockfolders_restore_status" -eq 0 ]]; then dockfolders_restore_status="$dockfolders_region_status"; fi
  printf '\n恢复尚未全部完成：原生分组 %s；系统预留区 %s；隐藏配置 %s。\n' "$dockfolders_host_status" "$dockfolders_region_status" "$dockfolders_legacy_status"
fi
printf '\n原生分组记录：%s\n原生布局备份：%s\n旧隐藏配置备份：%s\n' \
  "$dockfolders_root/Data/native-host-session.plist" \
  "$dockfolders_root/Data/Backups" \
  "$dockfolders_root/Data/NativeDockRecovery"
printf '恢复记录和备份均会保留，不会删除分组数据。\n'

if [[ -t 0 ]]; then
  printf '\n按回车键关闭此恢复入口。'
  IFS= read -r dockfolders_restore_enter || true
fi
exit "$dockfolders_restore_status"
