#!/bin/sh
set -eu

# Parrot Lab's non-persistent Dragon launcher for Bebop 2 firmware 4.4.2.
# Install this file and the optional patched binary in /data/ftp/internal_000.
# It never changes persist.dragon-prog.post_cmd or overwrites /usr/bin files.
#
# Important: apply/custom/restore validate everything and queue a detached
# worker before Dragon is stopped. Dragon teardown can drop the SC2 Telnet
# relay, so the worker must not depend on that transport remaining connected.

LAB_ROOT="${PARROTLAB_DRAGON_ROOT:-/data/ftp/internal_000}"
CUSTOM_1080="${PARROTLAB_DRAGON_1080:-$LAB_ROOT/dragon-prog-1080p-mode1-30fps}"
STATE_FILE="$LAB_ROOT/parrotlab-dragon-video.state"
LOG_FILE="/tmp/parrotlab-dragon-video.log"
WORKER_LOG="/tmp/parrotlab-dragon-worker.log"
WORKER_TOKEN="PARROTLAB_DETACHED_V1"
WORKER_ACTIVE=0

case "$0" in
    /*) SELF_PATH=$0 ;;
    *) SELF_PATH="$(pwd)/$0" ;;
esac

emit()
{
    printf '__PARROTLAB_DRAGON__=%s\n' "$1"
}

record_state()
{
    printf '%s\n' "$1" > "$STATE_FILE"
}

fail()
{
    if [ "$WORKER_ACTIVE" -eq 1 ]; then
        record_state "error|$1"
    fi
    emit "ERROR|$1"
    exit 1
}

usage()
{
    cat <<'EOF'
Usage:
  parrotlab_dragon_video.sh status
  parrotlab_dragon_video.sh apply stock480|stock720|lab1080 BITRATE_KBPS adaptive|constant LANDED
  parrotlab_dragon_video.sh custom BASE64_ARGUMENTS LANDED
  parrotlab_dragon_video.sh restore LANDED

Applying, starting custom Dragon, or restoring queues a detached worker before
the active Dragon process is stopped. Use only while landed with props removed.
Changes are runtime-only; a normal reboot restores startup.
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

require_worker_token()
{
    [ "${1:-}" = "$WORKER_TOKEN" ] || fail "INVALID_WORKER_TOKEN"
}

validate_bitrate()
{
    case "$1" in
        ''|*[!0-9]*) fail "INVALID_BITRATE" ;;
    esac
    [ "$1" -ge 1000 ] && [ "$1" -le 16000 ] || fail "BITRATE_OUT_OF_RANGE"
    [ $(($1 % 500)) -eq 0 ] || fail "BITRATE_STEP_MUST_BE_500"
}

validate_profile()
{
    profile_resolution=$1
    profile_rate_mode=$2

    case "$profile_resolution" in
        stock480)
            profile_binary=/usr/bin/dragon-prog
            profile_video_mode=1
            ;;
        stock720)
            profile_binary=/usr/bin/dragon-prog
            profile_video_mode=2
            ;;
        lab1080)
            profile_binary=$CUSTOM_1080
            profile_video_mode=1
            ;;
        *) fail "UNKNOWN_RESOLUTION" ;;
    esac

    [ -x "$profile_binary" ] || fail "BINARY_NOT_EXECUTABLE|$profile_binary"
    case "$profile_rate_mode" in
        adaptive|constant) ;;
        *) fail "UNKNOWN_RATE_MODE" ;;
    esac
}

validate_custom_payload()
{
    encoded_arguments=$1
    case "$encoded_arguments" in
        ''|*[!A-Za-z0-9+/=]*) fail "INVALID_CUSTOM_ENCODING" ;;
    esac
    command -v base64 >/dev/null 2>&1 || fail "BASE64_NOT_AVAILABLE"
    custom_arguments=$(printf '%s' "$encoded_arguments" | base64 -d 2>/dev/null) || \
        fail "INVALID_CUSTOM_ENCODING"
    [ -n "$custom_arguments" ] || fail "CUSTOM_ARGUMENTS_EMPTY"

    argument_bytes=$(printf '%s' "$custom_arguments" | wc -c | tr -d ' ')
    [ "$argument_bytes" -le 512 ] || fail "CUSTOM_ARGUMENTS_TOO_LONG"
    invalid_characters=$(printf '%s' "$custom_arguments" | \
        sed 's/[A-Za-z0-9_.,:\/+=@ -]//g')
    [ -z "$invalid_characters" ] || fail "CUSTOM_ARGUMENTS_UNSAFE"

    # Deliberate whitespace tokenization, without eval. Glob and shell control
    # characters were rejected above, so expansion cannot execute a command.
    set -- $custom_arguments
    [ "$#" -gt 0 ] || fail "CUSTOM_ARGUMENTS_EMPTY"
    [ "$#" -le 64 ] || fail "TOO_MANY_CUSTOM_ARGUMENTS"
    [ -x "$CUSTOM_1080" ] || fail "BINARY_NOT_EXECUTABLE|$CUSTOM_1080"
}

queue_worker()
{
    worker_action=$1
    shift
    [ -r "$SELF_PATH" ] || fail "HELPER_NOT_READABLE|$SELF_PATH"
    command -v setsid >/dev/null 2>&1 || fail "SETSID_NOT_AVAILABLE"

    : > "$WORKER_LOG"
    setsid sh "$SELF_PATH" "$worker_action" "$@" \
        >> "$WORKER_LOG" 2>&1 < /dev/null &
    queued_worker_pid=$!
    usleep 100000
    kill -0 "$queued_worker_pid" 2>/dev/null || fail "WORKER_START_FAILED|$WORKER_LOG"
}

start_profile()
{
    resolution=$1
    bitrate=$2
    rate_mode=$3
    validate_bitrate "$bitrate"
    validate_profile "$resolution" "$rate_mode"

    stop_dragon
    : > "$LOG_FILE"
    if [ "$rate_mode" = "constant" ]; then
        setsid "$profile_binary" -V "$profile_video_mode" -f 30 -R off -S 0 -I off \
            -q "$bitrate" -s -o >> "$LOG_FILE" 2>&1 < /dev/null &
    else
        setsid "$profile_binary" -V "$profile_video_mode" -f 30 -R off -S 0 -I off \
            -q "$bitrate" -o >> "$LOG_FILE" 2>&1 < /dev/null &
    fi
    new_pid=$!

    sleep 2
    kill -0 "$new_pid" 2>/dev/null || fail "DRAGON_START_FAILED|$LOG_FILE"
    record_state "running|$resolution|$bitrate|$rate_mode|$new_pid"
    emit "RUNNING|$resolution|$bitrate|$rate_mode|$new_pid"
}

start_custom()
{
    validate_custom_payload "$1"
    stop_dragon
    : > "$LOG_FILE"

    set -- $custom_arguments
    setsid "$CUSTOM_1080" "$@" >> "$LOG_FILE" 2>&1 < /dev/null &
    new_pid=$!

    sleep 2
    kill -0 "$new_pid" 2>/dev/null || fail "DRAGON_START_FAILED|$LOG_FILE"
    record_state "running|custom|$new_pid|$custom_arguments"
    emit "RUNNING|custom|$new_pid|$custom_arguments"
}

restore_stock()
{
    [ -x /usr/bin/DragonStarter.sh ] || fail "STOCK_STARTER_NOT_EXECUTABLE"
    stop_dragon
    : > "$LOG_FILE"
    setsid /usr/bin/DragonStarter.sh -out2null >> "$LOG_FILE" 2>&1 < /dev/null &
    starter_pid=$!

    count=0
    while [ "$count" -lt 100 ]; do
        pids=$(dragon_pids)
        if [ -n "$pids" ]; then
            record_state "restored|stock|$pids|starter:$starter_pid"
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
    state=unknown
    if [ -r "$STATE_FILE" ]; then
        state=$(tr '\n' ' ' < "$STATE_FILE")
    fi
    pids=$(dragon_pids)
    if [ -z "$pids" ]; then
        emit "STATUS|STOPPED|$state"
        return 0
    fi
    first_pid=$(printf '%s\n' "$pids" | head -n 1)
    executable=$(readlink "/proc/$first_pid/exe" 2>/dev/null || true)
    command_line=$(tr '\000' ' ' < "/proc/$first_pid/cmdline" 2>/dev/null || true)
    emit "STATUS|RUNNING|$first_pid|$executable|$state|$command_line"
}

case "${1:-}" in
    status)
        report_status
        ;;
    apply)
        [ "$#" -eq 5 ] || { usage; exit 2; }
        validate_bitrate "$3"
        validate_profile "$2" "$4"
        require_landed_confirmation "$5"
        queue_worker _worker_apply "$2" "$3" "$4" "$WORKER_TOKEN"
        record_state "queued|apply|$2|$3|$4|$queued_worker_pid"
        emit "QUEUED|apply|$2|$3|$4|$queued_worker_pid"
        ;;
    custom)
        [ "$#" -eq 3 ] || { usage; exit 2; }
        validate_custom_payload "$2"
        require_landed_confirmation "$3"
        queue_worker _worker_custom "$2" "$WORKER_TOKEN"
        record_state "queued|custom|$queued_worker_pid"
        emit "QUEUED|custom|$queued_worker_pid"
        ;;
    restore)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        require_landed_confirmation "$2"
        [ -x /usr/bin/DragonStarter.sh ] || fail "STOCK_STARTER_NOT_EXECUTABLE"
        queue_worker _worker_restore "$WORKER_TOKEN"
        record_state "queued|restore|$queued_worker_pid"
        emit "QUEUED|restore|$queued_worker_pid"
        ;;
    _worker_apply)
        [ "$#" -eq 5 ] || exit 2
        require_worker_token "$5"
        WORKER_ACTIVE=1
        trap '' HUP
        sleep 1
        start_profile "$2" "$3" "$4"
        ;;
    _worker_custom)
        [ "$#" -eq 3 ] || exit 2
        require_worker_token "$3"
        WORKER_ACTIVE=1
        trap '' HUP
        sleep 1
        start_custom "$2"
        ;;
    _worker_restore)
        [ "$#" -eq 2 ] || exit 2
        require_worker_token "$2"
        WORKER_ACTIVE=1
        trap '' HUP
        sleep 1
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
