#!/bin/sh

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# Keep B29 beside this script, normally in /data/ftp/internal_000.
case "$0" in
    /*) SCRIPT_DIR=${0%/*} ;;
    */*) SCRIPT_DIR=$(pwd)/${0%/*} ;;
    *)  SCRIPT_DIR=$(pwd) ;;
esac

B29=${1:-$SCRIPT_DIR/B29}

[ -f "$B29" ] || {
    echo "B29 not found: $B29" >&2
    exit 1
}
chmod +x "$B29" || exit 1

# Validate before stopping the running Dragon. Keep the stock wrapper: it
# stops motors if Dragon exits, and supplies the platform startup environment.
STARTER=/bin/DragonStarter.sh
[ -x "$STARTER" ] || { echo "DragonStarter missing: $STARTER" >&2; exit 1; }

# Dragon requests SIGQUIT (Ctrl+\\) for a clean camera/control shutdown.
PIDS=$(pidof dragon-prog 2>/dev/null || true)
if [ -n "$PIDS" ]; then
    echo "Stopping stock dragon-prog: $PIDS"
    kill -QUIT $PIDS 2>/dev/null || true

    N=0
    while [ "$N" -lt 30 ] && [ -n "$(pidof dragon-prog 2>/dev/null || true)" ]; do
        usleep 100000
        N=$((N + 1))
    done

    PIDS=$(pidof dragon-prog 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo "dragon-prog did not stop cleanly; forcing it down"
        kill -KILL $PIDS 2>/dev/null || true
        sleep 1
    fi
fi

echo "Starting $B29"
exec "$STARTER" -prog "$B29" -noout2null
