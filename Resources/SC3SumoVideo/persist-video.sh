#!/bin/sh
# Explicit install/restore only. Never restarts services, resets pairing, or
# changes the existing native enable marker, init service, or launch counters.
set -eu
task_mode=${1:-status}
task_stage=${2:-}
task_wrapper_sha=${3:-}
task_original_sha=0be1f74b8829fb66d07a8401fd7330b4a5016d87
task_video_sha=e18ff6ef07d172e53886e02a4f23118da7e0a1a5
task_selector=/usr/bin/sc3-native-sumo-start
task_original=/usr/bin/sc3-native-sumo-start-v1c
task_video_dir=/data/lib/mppd/native-sumo/video
task_library=$task_video_dir/libsc3-sumo-native-v2f.so
task_enabled=$task_video_dir/enabled
sha() { sha1sum "$1" 2>/dev/null | cut -d ' ' -f 1; }
fail() { echo "$*" >&2; exit 1; }
case "$task_mode" in status|check|install|restore) ;; *) fail 'Unknown video operation' ;; esac
test "$(id -u)" = 0 || fail 'SC3 maintenance requires its existing root connection'
test "$(gprop ro.parrot.build.version)" = 1.8.1 || fail 'Only the verified SC3 1.8.1 setup is supported'
test "${#task_wrapper_sha}" = 40 || fail 'Missing video selector checksum'
case "$task_wrapper_sha" in *[!0-9a-f]*) fail 'Invalid selector checksum' ;; esac
task_current=$(sha "$task_selector")
case "$task_current" in "$task_original_sha"|"$task_wrapper_sha") ;; *) fail 'Unknown startup selector; nothing changed' ;; esac
if test "$task_current" = "$task_wrapper_sha" && test "$task_mode" != restore; then
    test "$(sha "$task_original")" = "$task_original_sha" || fail 'Verified native selector backup is unavailable'
fi
test "$(sha /etc/boxinit.d/99-mppd.rc)" = 5e6af16f7bddfdf0c604c364a3e6d129497ff07f || fail 'Unexpected init service; nothing changed'
test "$(sha /data/lib/mppd/native-sumo/mppd.native-sumo-v1c)" = 83874fd41722c8391b3e530c7fce0e2ff3bab461 || fail 'Native v1c is unavailable'
test "$(sha /data/lib/mppd/native-sumo-backup/mppd.stock-1.8.1)" = 52398949fe32b46b0251b2c7f63942593c068d62 || fail 'Stock backup checksum mismatch'
case "$(sha /usr/bin/mppd)" in
    52398949fe32b46b0251b2c7f63942593c068d62|83874fd41722c8391b3e530c7fce0e2ff3bab461) ;;
    *) fail 'Unknown control executable; nothing changed' ;;
esac
test "$(sha /usr/lib/libarsdk.so)" = 22980d0b736ff810803205ecee9808caaa8d7520 || fail 'Unexpected SC3 SDK'
test "$(sha /usr/lib/libarsdkctrl.so)" = 0ea5c5e31982ec3dac38f9bf6dbedf93d809a5cb || fail 'Unexpected SC3 controller SDK'
test "$(sha /lib/libc.so.6)" = cb9a149a2b54da08de2ea357ea64ffb9a3d70ab6 || fail 'Unexpected SC3 runtime'
status() {
    task_installed=disabled
    if test "$task_current" = "$task_wrapper_sha" && test -f "$task_enabled"; then
        if test "$(sha "$task_library")" = "$task_video_sha"; then task_installed=enabled; else task_installed=damaged; fi
    fi
    echo "video_startup=$task_installed"
    if test -f /data/lib/mppd/native-sumo/enabled; then echo 'native_startup=enabled'; else echo 'native_startup=disabled'; fi
    echo "control_service=$(gprop init.svc.mppd)"
    task_pid=$(pidof mppd 2>/dev/null || true)
    task_active=no
    case "$task_pid" in ''|*[!0-9]*) ;; *)
        if grep -Fq 'libsc3-sumo-native-v2f.so' "/proc/$task_pid/maps"; then task_active=yes; fi ;;
    esac
    echo "video_active=$task_active"
    if test "$task_current" = "$task_wrapper_sha"; then /bin/sh "$task_selector" --video-status; fi
}
if test "$task_mode" = status; then status; exit 0; fi
case "$task_stage" in /tmp/parrotlab-sc3-video-*) ;; *) fail 'Invalid staging directory' ;; esac
task_suffix=${task_stage#/tmp/parrotlab-sc3-video-}
case "$task_suffix" in ''|*[!a-zA-Z0-9-]*) fail 'Invalid staging directory' ;; esac
test "$(sha "$task_stage/startup-video.sh")" = "$task_wrapper_sha" || fail 'Video selector checksum mismatch'
test "$(sha "$task_stage/startup-v1c.sh")" = "$task_original_sha" || fail 'Original selector checksum mismatch'
test "$(sha "$task_stage/libsc3-sumo-native-v2f.so")" = "$task_video_sha" || fail 'Video helper checksum mismatch'
/bin/sh -n "$task_stage/startup-video.sh"
/bin/sh -n "$task_stage/startup-v1c.sh"
if test -e "$task_original" && test "$task_mode" != restore; then
    test "$(sha "$task_original")" = "$task_original_sha" || fail 'Unknown selector backup; nothing changed'
fi
if test -e "$task_library" && test "$task_mode" != restore; then
    test "$(sha "$task_library")" = "$task_video_sha" || fail 'Existing video helper changed; nothing overwritten'
fi
if test "$task_mode" = check; then echo 'SC3 video startup preflight passed; no changes made'; status; exit 0; fi
if test "$task_mode" = install; then
    test -f /data/lib/mppd/native-sumo/enabled || fail 'Enable the existing native Sumo setup first'
fi

umask 077
task_lock=/tmp/parrotlab-sc3-video-install.lock
if ! mkdir "$task_lock" 2>/dev/null; then
    task_owner=$(cat "$task_lock/pid" 2>/dev/null || true)
    case "$task_owner" in ''|*[!0-9]*) fail 'Unknown installation lock; no changes made' ;; esac
    if kill -0 "$task_owner" 2>/dev/null; then fail 'Another video installation is running'; fi
    rm "$task_lock/pid"; rmdir "$task_lock"; mkdir "$task_lock"
fi
printf '%s\n' "$$" > "$task_lock/pid"
task_remount=0
finish() {
    task_exit=$?
    trap - EXIT HUP INT TERM
    trap '' PIPE
    sync
    if test "$task_remount" = 1; then
        if ! mount -o remount,ro /; then echo 'Root remount failed; inspect controller before restarting' >&2 || true; task_exit=1; fi
    fi
    rm -f "$task_lock/pid"; rmdir "$task_lock" || true
    exit "$task_exit"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM PIPE
task_mount_options=$(awk '$2=="/" {print $4; exit}' /proc/mounts)
case ",$task_mount_options," in *,ro,*) task_remount=1; mount -o remount,rw / ;; *,rw,*) ;; *) fail 'Unknown root mount state' ;; esac

if test "$task_mode" = install; then
    mkdir -p "$task_video_dir"; chmod 700 "$task_video_dir"
    if ! test -e "$task_library"; then
        cp "$task_stage/libsc3-sumo-native-v2f.so" "$task_library.pending"
        chmod 600 "$task_library.pending"
        test "$(sha "$task_library.pending")" = "$task_video_sha"
        mv "$task_library.pending" "$task_library"
    fi
    if ! test -e "$task_original"; then
        cp "$task_stage/startup-v1c.sh" "$task_original.pending"
        chmod 755 "$task_original.pending"
        test "$(sha "$task_original.pending")" = "$task_original_sha"
        mv "$task_original.pending" "$task_original"
    fi
    cp "$task_stage/startup-video.sh" "$task_selector.pending"
    chmod 755 "$task_selector.pending"
    test "$(sha "$task_selector.pending")" = "$task_wrapper_sha"
    mv "$task_selector.pending" "$task_selector"
    # Publish the enable marker last. Any interrupted first installation
    # falls back to the verified native selector without loading video.
    : > "$task_enabled.pending"; chmod 600 "$task_enabled.pending"
    mv "$task_enabled.pending" "$task_enabled"
    echo 'VIDEO_STARTUP_INSTALLED_NEXT_RESTART'
else
    # Disable first, then restore the exact original selector atomically.
    rm -f "$task_enabled"
    cp "$task_stage/startup-v1c.sh" "$task_selector.pending"
    chmod 755 "$task_selector.pending"
    test "$(sha "$task_selector.pending")" = "$task_original_sha"
    mv "$task_selector.pending" "$task_selector"
    echo 'VIDEO_STARTUP_REMOVED_NATIVE_CONTROLS_PRESERVED'
fi
sync
task_current=$(sha "$task_selector")
status
