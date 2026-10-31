#!/bin/zsh
# Install the LaunchAgent that runs phone-sync.sh every 10 minutes. The scripts
# are copied out of the repository so a branch checkout cannot remove them.
set -euo pipefail

label=local.sereja.petrichor-phone-sync
dest="$HOME/bin/petrichor-phone-sync"
plist="$HOME/Library/LaunchAgents/$label.plist"

mkdir -p "$dest" "$HOME/Library/LaunchAgents"
cp -f "${0:A:h}/phone-sync.sh" "${0:A:h}/device-id.sh" "$dest/"
chmod +x "$dest"/*.sh

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$dest/phone-sync.sh</string></array>
    <key>StartInterval</key><integer>600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/petrichor-phone-sync.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/petrichor-phone-sync.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Installed $label; log: ~/Library/Logs/petrichor-phone-sync.log"
