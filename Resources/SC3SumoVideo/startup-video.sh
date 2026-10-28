#!/bin/sh
# Existing init service remains the sole mppd supervisor. No second daemon.
set -eu
task_original=/usr/bin/sc3-native-sumo-start-v1c
task_original_sha=0be1f74b8829fb66d07a8401fd7330b4a5016d87
task_video=/data/lib/mppd/native-sumo/video/libsc3-sumo-native-v2f.so
task_video_sha=e18ff6ef07d172e53886e02a4f23118da7e0a1a5
task_enabled=/data/lib/mppd/native-sumo/video/enabled
task_counter=/tmp/sc3-native-sumo-video-start-count
task_result=/tmp/sc3-native-sumo-video-selection
task_mode=${1:---start}
sha() { sha1sum "$1" 2>/dev/null | cut -d ' ' -f 1; }
case "$task_mode" in --start|--check|--prepare|--video-status) ;; *) exit 2 ;; esac
unset LD_PRELOAD

# Retain a rootfs copy of the original selector: loss of /data must still
# select stock through the existing hash-checked policy.
if ! test "$(sha "$task_original")" = "$task_original_sha"; then
    echo 'Native selector backup missing or changed; refusing unknown startup' >&2
    exit 1
fi
case "$task_mode" in
    --check|--prepare) exec /bin/sh "$task_original" "$task_mode" ;;
esac
task_attempts=0
if test -r "$task_counter"; then
    task_attempts=$(cat "$task_counter")
    case "$task_attempts" in 0|1|2) ;; *) task_attempts=2 ;; esac
fi
task_reason=enabled
if ! test -f "$task_enabled"; then task_reason=disabled
elif test "$(gprop ro.parrot.build.version)" != 1.8.1; then task_reason=firmware-mismatch
elif test "$(sha "$task_video")" != "$task_video_sha"; then task_reason=video-mismatch
elif test "$(sha /usr/lib/libarsdk.so)" != 22980d0b736ff810803205ecee9808caaa8d7520 ||
     test "$(sha /usr/lib/libarsdkctrl.so)" != 0ea5c5e31982ec3dac38f9bf6dbedf93d809a5cb ||
     test "$(sha /lib/libc.so.6)" != cb9a149a2b54da08de2ea357ea64ffb9a3d70ab6; then task_reason=sdk-mismatch
elif test "$task_attempts" -ge 2; then task_reason=video-launch-limit
fi
if test "$task_mode" = --video-status; then
    echo "video=$task_reason attempts=$task_attempts"
    exit 0
fi

# Exactly one prepare/launch count. The original still controls native-vs-stock
# selection, recognized overlays, and its three-launch fallback.
/bin/sh "$task_original" --prepare
task_native=0
if test -r /tmp/sc3-native-sumo-selection; then
    case "$(cat /tmp/sc3-native-sumo-selection)" in selection=native\ *) task_native=1 ;; esac
fi
if test "$task_native" != 1; then task_reason=native-unavailable; fi
umask 077
printf 'video=%s attempts=%s\n' "$task_reason" "$task_attempts" > "$task_result"
if test "$task_reason" = enabled; then
    task_attempts=$((task_attempts + 1))
    printf '%s\n' "$task_attempts" > "$task_counter"
    printf 'video=enabled attempts=%s\n' "$task_attempts" > "$task_result"
    export LD_PRELOAD="$task_video"
fi
exec /usr/bin/mppd
