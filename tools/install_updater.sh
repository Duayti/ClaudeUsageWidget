#!/bin/bash
# Installs (or reinstalls) the LaunchAgent that recomputes ~/.claude/usage-widget.json every 12 hours.
#
#   tools/install_updater.sh               install or update
#   tools/install_updater.sh --uninstall   remove the agent and the copy of the script
#
# The script is copied to ~/Library/Application Support/ClaudeUsageWidget/ because ~/Documents is
# protected by TCC and launchd could not read it from a checkout there.
#
# BUNDLE_PREFIX (optional) must match the value used with tools/generate_project.py; the agent label is
# "$BUNDLE_PREFIX.updater". Default: com.example.ClaudeUsageWidget
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${BUNDLE_PREFIX:-com.example.ClaudeUsageWidget}.updater"
DEST="$HOME/Library/Application Support/ClaudeUsageWidget"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$DEST/update_usage.py"
    rmdir "$DEST" 2>/dev/null || true
    echo "Uninstalled. ~/.claude/usage-widget.json and usage-widget-state.json remain (delete them and the widget falls back to stats-cache.json)."
    exit 0
fi

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 0644 "$ROOT/tools/update_usage.py" "$DEST/update_usage.py"
# The template carries placeholders; they are filled in with the current user's home folder.
# '|' is the sed delimiter: neither a home path nor a label contains it.
sed -e "s|__HOME__|$HOME|g" -e "s|__LABEL__|$LABEL|g" "$ROOT/tools/updater.plist.template" > "$PLIST"
chmod 0644 "$PLIST"
plutil -lint "$PLIST" >/dev/null

# If it was already loaded, unload it to pick up the new version. bootout is asynchronous: retry.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "$DOMAIN" "$PLIST"; then
        echo "Installed: $LABEL (every 12 hours). Log: ~/Library/Logs/ClaudeUsageWidget.log"
        exit 0
    fi
    sleep 1
done
echo "Could not load the agent; check: launchctl print $DOMAIN/$LABEL" >&2
exit 1
