#!/bin/sh
set -eu

# Parrot Lab's non-persistent Dragon launcher for Bebop 2 firmware 4.4.2.
# Install this file and the optional patched binary in /data/ftp/internal_000.
# It never changes persist.dragon-prog.post_cmd or overwrites /usr/bin files.

LAB_ROOT="${PARROTLAB_DRAGON_ROOT:-/data/ftp/internal_000}"
CUSTOM_1080="${PARROTLAB_DRAGON_1080:-$LAB_ROOT/dragon-prog-1080p-mode1-30fps}"
STATE_FILE="$LAB_ROOT/parrotlab-dragon-video.state"
LOG_FILE="/tmp/parrotlab-dragon-video.log"

emit()
{
    printf '__PARROTLAB_DRAGON__=%s\n' "$1"
}

fail()
{
    emit "ERROR|$1"
    exit 1
}

usage()
{
    cat <<'EOF'
Usage:
  parrotlab_dragon_video.sh status
  parrotlab_dragon_video.sh apply stock480|stock720|lab1080 BITRATE_KBPS adaptive|constant LANDED
  parrotlab_dragon_video.sh restore LANDED

Applying or restoring stops the active Dragon process. Use only while landed
with props removed. Changes are runtime-only; a normal reboot restores startup.
EOF
}

dragon_pids()
{
    for proc_dir in /proc/[0-9]*; do
        [ -r "$proc_dir/exe" ] || continue
        executable=$(readlink "$proc_dir/exe" 2>/dev/null || true)
        case "$executable" in
            */dragon-prog|*/dragon-prog-*) basename "$proc_dir" ;;
        esac
    done
}

wait_for_dragon_stop()
{
    count=0
    while [ "$count" -lt 30 ]; do
        [ -z "$(dragon_pids)" ] && return 0
        usleep 100000
        count=$((count + 1))
    done
    return 1
}

stop_dragon()
{
    pids=$(dragon_pids)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
        if ! wait_for_dragon_stop; then
            pids=$(dragon_pids)
            [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
            wait_for_dragon_stop || fail "DRAGON_WOULD_NOT_STOP"
        fi
    fi
    # Allow the stock DragonStarter wrapper to complete its safety cleanup.
    sleep 1
}

require_landed_confirmation()
{
    [ "${1:-}" = "LANDED" ] || fail "LANDED_CONFIRMATION_REQUIRED"
}

validate_bitrate()
{
    case "$1" in
        ''|*[!0-9]*) fail "INVALID_BITRATE" ;;
    esac
    [ "$1" -ge 1000 ] && [ "$1" -le 16000 ] || fail "BITRATE_OUT_OF_RANGE"
    [ $(($1 % 500)) -eq 0 ] || fail "BITRATE_STEP_MUST_BE_500"
}

start_profile()
{
    resolution=$1
    bitrate=$2
    rate_mode=$3

    case "$resolution" in
        stock480)
            binary=/usr/bin/dragon-prog
            video_mode=1
            ;;
        stock720)
            binary=/usr/bin/dragon-prog
            video_mode=2
            ;;
        lab1080)
            binary=$CUSTOM_1080
            video_mode=1
            ;;
        *) fail "UNKNOWN_RESOLUTION" ;;
    esac

    [ -x "$binary" ] || fail "BINARY_NOT_EXECUTABLE|$binary"
    case "$rate_mode" in
        adaptive|constant) ;;
        *) fail "UNKNOWN_RATE_MODE" ;;
    esac

    stop_dragon
    : > "$LOG_FILE"
    if [ "$rate_mode" = "constant" ]; then
        setsid "$binary" -V "$video_mode" -f 30 -R off -S 0 -I off \
            -q "$bitrate" -s -o >> "$LOG_FILE" 2>&1 < /dev/null &
    else
        setsid "$binary" -V "$video_mode" -f 30 -R off -S 0 -I off \
            -q "$bitrate" -o >> "$LOG_FILE" 2>&1 < /dev/null &
    fi
    new_pid=$!

    sleep 2
    kill -0 "$new_pid" 2>/dev/null || fail "DRAGON_START_FAILED|$LOG_FILE"
    printf '%s %s %s %s\n' "$resolution" "$bitrate" "$rate_mode" "$new_pid" > "$STATE_FILE"
    emit "RUNNING|$resolution|$bitrate|$rate_mode|$new_pid"
}

restore_stock()
{
    stop_dragon
    : > "$LOG_FILE"
    setsid /usr/bin/DragonStarter.sh -out2null >> "$LOG_FILE" 2>&1 < /dev/null &
    starter_pid=$!

    count=0
    while [ "$count" -lt 100 ]; do
        pids=$(dragon_pids)
        if [ -n "$pids" ]; then
            rm -f "$STATE_FILE"
            emit "RESTORED|stock|$pids|starter:$starter_pid"
            return 0
        fi
        usleep 100000
        count=$((count + 1))
    done
    fail "STOCK_START_FAILED|$LOG_FILE"
}

report_status()
{
    pids=$(dragon_pids)
    if [ -z "$pids" ]; then
        emit "STATUS|STOPPED"
        return 0
    fi
    first_pid=$(printf '%s\n' "$pids" | head -n 1)
    executable=$(readlink "/proc/$first_pid/exe" 2>/dev/null || true)
    command_line=$(tr '\000' ' ' < "/proc/$first_pid/cmdline" 2>/dev/null || true)
    emit "STATUS|RUNNING|$first_pid|$executable|$command_line"
}

case "${1:-}" in
    status)
        report_status
        ;;
    apply)
        [ "$#" -eq 5 ] || { usage; exit 2; }
        validate_bitrate "$3"
        require_landed_confirmation "$5"
        start_profile "$2" "$3" "$4"
        ;;
    restore)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        require_landed_confirmation "$2"
        restore_stock
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 2
        ;;
esac
