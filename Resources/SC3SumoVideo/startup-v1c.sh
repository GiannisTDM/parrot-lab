#!/bin/sh
# Installed read-only at /usr/bin/sc3-native-sumo-start. Stock binary stays put.
# Init invokes this selector for the existing mppd service. /data is mounted
# during fs, before mpp.open / class mpp startup. Missing data defaults to stock.
set -eu
stock_sha=52398949fe32b46b0251b2c7f63942593c068d62
patch_sha=83874fd41722c8391b3e530c7fce0e2ff3bab461
patch_path=/data/lib/mppd/native-sumo/mppd.native-sumo-v1c
backup_path=/data/lib/mppd/native-sumo-backup/mppd.stock-1.8.1
enabled_path=/data/lib/mppd/native-sumo/enabled
target_path=/usr/bin/mppd
count_path=/tmp/sc3-native-sumo-start-count
result_path=/tmp/sc3-native-sumo-selection
sha() { sha1sum "$1" 2>/dev/null | cut -d ' ' -f 1; }
mounted() { grep -q ' /usr/bin/mppd ' /proc/mounts; }
mode=${1:---start}
case "$mode" in --start|--check|--prepare) ;; *) echo 'Usage: startup.sh --start|--check|--prepare' >&2; exit 2 ;; esac

reason=enabled
selection=native
current_sha=$(sha "$target_path")
attempts=0
if test -r "$count_path"; then
    attempts=$(cat "$count_path")
    case "$attempts" in 0|1|2|3) ;; *) attempts=3 ;; esac
fi
if test "$(gprop ro.parrot.build.version)" != 1.8.1; then reason=firmware-mismatch
elif ! test -f "$enabled_path"; then reason=disabled
elif ! test -x "$patch_path" || test "$(sha "$patch_path")" != "$patch_sha"; then reason=patch-mismatch
elif test "$(sha "$backup_path")" != "$stock_sha"; then reason=backup-mismatch
elif test "$current_sha" != "$stock_sha" && test "$current_sha" != "$patch_sha"; then reason=stock-mismatch
elif test "$attempts" -ge 3; then reason=launch-limit
fi
if test "$reason" != enabled; then selection=stock; fi
if test "$mode" = --check; then
    echo "selection=$selection reason=$reason attempts=$attempts"
    exit 0
fi

umask 077
if test "$selection" = native; then
    # Never stack mounts or replace an unrelated overlay.
    if mounted; then
        if test "$current_sha" != "$patch_sha"; then
            selection=stock; reason=foreign-overlay
        fi
    elif ! mount --bind "$patch_path" "$target_path"; then
        selection=stock; reason=mount-failed
    fi
fi
if test "$selection" = stock && mounted; then
    # Only our exact overlay may be removed automatically.
    if test "$(sha "$target_path")" = "$patch_sha"; then
        umount "$target_path"
    fi
fi
if test "$selection" = native; then
    if test "$(sha "$target_path")" != "$patch_sha"; then exit 1; fi
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$count_path"
fi
printf 'selection=%s reason=%s attempts=%s\n' "$selection" "$reason" "$attempts" > "$result_path"
if test "$mode" = --prepare; then cat "$result_path"; exit 0; fi
exec "$target_path"
