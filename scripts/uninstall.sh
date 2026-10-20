#!/bin/bash
set -euo pipefail

# usage: uninstall.sh [--all]
# Default: stop the agent, remove it and the binary. --all also removes config and log.
LABEL="local.logitech-switcher.agent"
IDENT="local.logitech-switcher.logitech-switcher"
DEST="$HOME/.local/bin/logitech-switcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG="$HOME/.config/logitech-switcher"
LOG="$HOME/Library/Logs/logitech-switcher.log"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL" || echo "agent $LABEL was not running"
pkill -f "$DEST agent" 2>/dev/null || true
rm -f "$PLIST" "$DEST" && echo "removed $PLIST and $DEST"

if [ "${1:-}" = "--all" ]; then
    rm -rf "$CONFIG" "$LOG" && echo "removed $CONFIG and $LOG"
else
    echo "kept $CONFIG and $LOG, pass --all to remove them"
fi

if tccutil reset ListenEvent "$IDENT" >/dev/null 2>&1; then
    echo "reset Input Monitoring for $IDENT"
else
    echo "remove the logitech-switcher entry in System Settings > Privacy & Security > Input Monitoring by hand"
fi
