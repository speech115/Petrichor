#!/bin/zsh
# Swap the playback journals of the Mac app and the iPhone app. Each app
# appends its own favorite/listen events to Sync/playback-journal.jsonl and
# applies Sync/peer-journal.jsonl when it comes to the foreground; this script
# copies each side's journal to the other side's peer file. Run by the
# LaunchAgent that install-phone-sync.sh sets up; quiet when no phone is near.
set -euo pipefail

app=org.Petrichor.ios
mac_sync="$HOME/Library/Containers/org.Petrichor/Data/Library/Application Support/org.Petrichor/Sync"
log() { print -r -- "$(date '+%F %T') $*"; }

device=$("${0:A:h}/device-id.sh" 2>/dev/null) || exit 0
mkdir -p "$mac_sync"

copy_from_phone() {
    xcrun devicectl device copy from --timeout 60 --device "$device" \
        --domain-type appDataContainer --domain-identifier "$app" \
        --source Documents/Sync/playback-journal.jsonl --destination "$1" >/dev/null 2>&1
}

tmp="$mac_sync/.peer-journal.jsonl.part"
rm -f "$tmp"
if copy_from_phone "$tmp"; then
    if cmp -s "$tmp" "$mac_sync/peer-journal.jsonl"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$mac_sync/peer-journal.jsonl"
        log "phone -> mac: $(wc -l < "$mac_sync/peer-journal.jsonl" | tr -d ' ') lines"
    fi
else
    rm -f "$tmp"
    log "phone -> mac failed (phone locked, asleep or out of reach)"
fi

outbox="$mac_sync/playback-journal.jsonl"
pushed="$mac_sync/.pushed-journal.jsonl"
if [[ -s "$outbox" ]] && ! cmp -s "$outbox" "$pushed"; then
    cp -f "$outbox" "$pushed.part"
    if xcrun devicectl device copy to --timeout 60 --device "$device" \
        --domain-type appDataContainer --domain-identifier "$app" \
        --source "$pushed.part" --destination Documents/Sync/peer-journal.jsonl >/dev/null 2>&1; then
        mv -f "$pushed.part" "$pushed"
        log "mac -> phone: $(wc -l < "$pushed" | tr -d ' ') lines"
    else
        rm -f "$pushed.part"
        log "mac -> phone failed"
    fi
fi
