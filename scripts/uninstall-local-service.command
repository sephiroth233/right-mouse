#!/bin/bash
set -euo pipefail
LABEL=cn.rightmouse.local-bridge
DOMAIN="gui/$(id -u)"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then launchctl bootout "$DOMAIN/$LABEL"; fi
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [[ -e "$PLIST" ]]; then rm "$PLIST"; fi
# Stop an already running host from re-registering until explicitly re-enabled.
defaults write cn.rightmouse.RightMouse RightMouseLocalServiceDisabled -bool true
printf '%s\n' 'RightMouse Finder 连接服务已移除。请退出 RightMouse；设置、异常恢复现场和用户文件均已保留。'
