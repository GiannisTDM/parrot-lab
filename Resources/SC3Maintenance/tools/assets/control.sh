#!/bin/sh
# On-controller mppd overlay control. Stock init remains the supervisor.
# With the optional startup selector installed, enabled also survives reboot.
set -eu
stock_sha=52398949fe32b46b0251b2c7f63942593c068d62
patch_sha=83874fd41722c8391b3e530c7fce0e2ff3bab461
patch_path=/data/lib/mppd/native-sumo/mppd.native-sumo-v1c
backup_path=/data/lib/mppd/native-sumo-backup/mppd.stock-1.8.1
enabled_path=/data/lib/mppd/native-sumo/enabled
sha() { sha1sum "$1" | cut -d ' ' -f 1; }
mounted() { grep -q ' /usr/bin/mppd ' /proc/mounts; }
stopped() {
    pstop mppd
    for delay in 1 2 3 4 5; do
        if test "$(gprop init.svc.mppd)" = stopped; then return 0; fi
        sleep 1
    done
    echo 'mppd did not stop; no overlay was changed' >&2
    return 1
}
restore_after_failure() {
    trap - EXIT HUP INT TERM
    pstop mppd || true
    sleep 1
    if mounted; then umount /usr/bin/mppd; fi
    pstart mppd
}
test "$(id -u)" = 0
test "$(gprop ro.parrot.build.version)" = 1.8.1
test "$(sha "$backup_path")" = "$stock_sha"
case "${1:-status}" in
    activate)
        test "$(sha "$patch_path")" = "$patch_sha"
        if mounted; then
            test "$(sha /usr/bin/mppd)" = "$patch_sha"
            echo 'Native Sumo overlay is already active.'
            exit 0
        fi
        test "$(sha /usr/bin/mppd)" = "$stock_sha"
        stopped
        if ! mount --bind "$patch_path" /usr/bin/mppd; then
            pstart mppd
            exit 1
        fi
        trap restore_after_failure EXIT HUP INT TERM
        test "$(sha /usr/bin/mppd)" = "$patch_sha"
        pstart mppd
        sleep 3
        test "$(gprop init.svc.mppd)" = running
        trap - EXIT HUP INT TERM
        echo 'Native Sumo overlay active for this boot only. No drive/jump test was sent.'
        ;;
    stock)
        # Disable future selection before restarting the stock service.
        if test -e "$enabled_path"; then rm "$enabled_path"; fi
        if mounted; then
            test "$(sha /usr/bin/mppd)" = "$patch_sha"
            stopped
            umount /usr/bin/mppd
            test "$(sha /usr/bin/mppd)" = "$stock_sha"
            pstart mppd
        fi
        test "$(sha /usr/bin/mppd)" = "$stock_sha"
        echo 'Stock executable visible; native startup disabled.'
        ;;
    enable)
        test -x /usr/bin/sc3-native-sumo-start
        test "$(sha "$patch_path")" = "$patch_sha"
        umask 077
        touch "$enabled_path"
        chmod 600 "$enabled_path"
        printf '0\n' > /tmp/sc3-native-sumo-start-count
        echo 'Native startup enabled; no service was restarted.'
        ;;
    disable)
        if test -e "$enabled_path"; then rm "$enabled_path"; fi
        echo 'Native startup disabled; current session unchanged. Use stock to restore now.'
        ;;
    status)
        echo "mppd service: $(gprop init.svc.mppd)"
        if mounted; then echo 'Overlay: active'; else echo 'Overlay: absent'; fi
        if test -e "$enabled_path"; then echo 'Native startup: enabled'; else echo 'Native startup: disabled'; fi
        if test -r /tmp/sc3-native-sumo-selection; then cat /tmp/sc3-native-sumo-selection; fi
        sha1sum /usr/bin/mppd "$backup_path"
        ;;
    *) echo 'Usage: sh control.sh activate|stock|enable|disable|status' >&2; exit 2 ;;
esac
