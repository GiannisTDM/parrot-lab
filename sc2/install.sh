#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
SOURCE_MODULE="${1:-$SCRIPT_DIR/apple_mac_ncm.ko}"
DATA_DIR=/data/lib/parrotlab
MODULE=$DATA_DIR/apple_mac_ncm.ko
BOOT=$DATA_DIR/parrotlab_boot.sh
RELAY=$DATA_DIR/drone_telnet_relay.sh
UNINSTALL=$DATA_DIR/uninstall.sh
RC_FILE=/etc/boxinit.d/99-plboot.rc
ROOT_RW=0

restore_root()
{
    if [ "$ROOT_RW" = "1" ]; then
        sync || true
        mount -o remount,ro / >/dev/null 2>&1 || true
    fi
}
trap restore_root EXIT INT TERM

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: run this as root on the SkyController 2"
    exit 1
fi

if [ ! -r "$SOURCE_MODULE" ]; then
    echo "ERROR: cannot read $SOURCE_MODULE"
    exit 1
fi

mkdir -p "$DATA_DIR"
cp "$SOURCE_MODULE" "$MODULE"
chmod 0644 "$MODULE"

cat > "$RELAY" <<'EOF_RELAY'
#!/bin/sh
exec /usr/bin/telnet 192.168.42.1
EOF_RELAY
chmod 0755 "$RELAY"

cat > "$BOOT" <<'EOF_BOOT'
#!/bin/sh

MODULE=/data/lib/parrotlab/apple_mac_ncm.ko
RELAY=/data/lib/parrotlab/drone_telnet_relay.sh
LOG=/tmp/parrotlab-boot.log

echo "parrotlab: class-main boot started" >> "$LOG"
echo "parrotlab: uptime: $(cat /proc/uptime 2>/dev/null)" >> "$LOG"

if grep -q '^apple_mac_ncm ' /proc/modules 2>/dev/null; then
    echo "parrotlab: apple_mac_ncm already loaded" >> "$LOG"
elif [ ! -r "$MODULE" ]; then
    echo "parrotlab: ERROR: cannot read $MODULE" >> "$LOG"
else
    echo "parrotlab: insmod $MODULE" >> "$LOG"
    if /sbin/insmod "$MODULE" >> "$LOG" 2>&1; then
        echo "parrotlab: apple_mac_ncm loaded successfully" >> "$LOG"
    else
        echo "parrotlab: ERROR: apple_mac_ncm load failed" >> "$LOG"
    fi
fi

if netstat -ltn 2>/dev/null | grep -q ':2324 '; then
    echo "parrotlab: drone relay already listening" >> "$LOG"
else
    /usr/bin/nc -ll -p 2324 -e "$RELAY" >/tmp/parrotlab-drone-relay.log 2>&1 &
    echo $! > /tmp/parrotlab-drone-relay.pid
    echo "parrotlab: drone relay started on TCP 2324" >> "$LOG"
fi
EOF_BOOT
chmod 0755 "$BOOT"

cp "$SCRIPT_DIR/uninstall.sh" "$UNINSTALL"
chmod 0755 "$UNINSTALL"

mount -o remount,rw /
ROOT_RW=1

rm -f \
    /etc/boxinit.d/51-parrotlab-usb.rc \
    /etc/boxinit.d/99-parrotlab-usb.rc \
    /etc/boxinit.d/99-pltest.rc \
    /etc/boxinit.d/99-plncm.rc

cat > "$RC_FILE" <<'EOF_RC'
service plboot /bin/sh /data/lib/parrotlab/parrotlab_boot.sh
    class main
    user root
    oneshot
EOF_RC
chmod 0640 "$RC_FILE"

sync
mount -o remount,ro /
ROOT_RW=0

/bin/sh "$BOOT"

echo "Parrot Lab SC2 support installed."
echo "Reboot, reconnect the Mac, then verify:"
echo "  grep '^apple_mac_ncm ' /proc/modules"
echo "  netstat -ltn | grep ':2324 '"
echo "  cat /tmp/parrotlab-boot.log"
