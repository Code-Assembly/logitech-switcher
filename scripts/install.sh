#!/bin/bash
set -euo pipefail

# usage: install.sh [binary]
# Default binary: ./logitech-switcher next to this script (a package), else this repo's release build.
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.logitech-switcher.agent"
DEST="$HOME/.local/bin/logitech-switcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/logitech-switcher.log"

src="${1:-}"
if [ -z "$src" ]; then
    for candidate in "$HERE/logitech-switcher" "$HERE/../.build/release/logitech-switcher"; do
        [ -x "$candidate" ] && src="$candidate" && break
    done
fi
if [ -z "$src" ] || [ ! -x "$src" ]; then
    echo "install: no logitech-switcher binary found, run scripts/build.sh or pass its path" >&2
    exit 31
fi
if ! codesign --verify "$src" 2>/dev/null; then
    echo "install: $src is not signed, run scripts/build.sh" >&2
    exit 32
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# Before the rename this installed as logi-switch; remove that and keep its config.
if launchctl bootout "gui/$(id -u)/local.logi-switch.agent" 2>/dev/null; then
    echo "stopped old agent local.logi-switch.agent"
fi
rm -f "$HOME/Library/LaunchAgents/local.logi-switch.agent.plist" "$HOME/.local/bin/logi-switch"
if [ -d "$HOME/.config/logi-switch" ] && [ ! -e "$HOME/.config/logitech-switcher" ]; then
    mv "$HOME/.config/logi-switch" "$HOME/.config/logitech-switcher"
    echo "moved config to ~/.config/logitech-switcher"
fi

mkdir -p "$(dirname "$DEST")" "$(dirname "$PLIST")" "$(dirname "$LOG")"
cp -f "$src" "$DEST"
xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DEST</string><string>agent</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardErrorPath</key><string>$LOG</string>
    <key>StandardOutPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
granted=$(grep '"agent_ready"' "$LOG" 2>/dev/null | tail -1 | grep -c '"inputMonitoring":"granted"' || true)

echo "installed $DEST, agent $LABEL, log $LOG"
echo "the agent renames this Mac's slot on each device to the computer name ($(scutil --get ComputerName)) when they connect"
if [ "$granted" = "1" ]; then
    echo "Input Monitoring already granted"
else
    cat <<MSG
Allow Input Monitoring for logitech-switcher: macOS should prompt. If not, add
$DEST in the pane opening now. The agent restarts itself once it is granted.
The grant is tied to this path and the signing certificate, so reinstalling
here keeps it.
MSG
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
fi
