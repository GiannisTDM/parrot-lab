#!/bin/sh
# Persistent Apple-private CDC NCM driver installer for SkyController 2 1.0.9.
# The app uploads this file and apple_mac_ncm.ko together to internal_000.

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
SOURCE_MODULE="${1:-$SCRIPT_DIR/apple_mac_ncm.ko}"

DATA_DIR=/data/lib/parrotlab
MODULE=$DATA_DIR/apple_mac_ncm.ko
BOOT_HELPER=$DATA_DIR/parrotlab_boot.sh
RELAY=$DATA_DIR/drone_telnet_relay.sh
UNINSTALL=$DATA_DIR/uninstall_sc2_apple_ncm.sh
BACKUP_DIR=$DATA_DIR/rc-backups
RC_FILE=/etc/boxinit.d/99-plboot.rc
LEGACY_RC_FILES="
/etc/boxinit.d/51-parrotlab-usb.rc
/etc/boxinit.d/99-parrotlab-usb.rc
/etc/boxinit.d/99-pltest.rc
/etc/boxinit.d/99-plncm.rc
"

ROOT_RW=0
cleanup_root_mount()
{
    if [ "$ROOT_RW" = "1" ]; then
        sync || true
        mount -o remount,ro / >/dev/null 2>&1 || true
    fi
}
trap cleanup_root_mount EXIT INT TERM

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || fail "run this installer as root on the SC2"
[ -r "$SOURCE_MODULE" ] || fail "cannot read module $SOURCE_MODULE"
[ "$(uname -r)" = "3.4.11+" ] || fail "unsupported kernel $(uname -r); expected 3.4.11+"
grep -q '^ro.parrot.build.version=1\.0\.9$' /etc/build.prop 2>/dev/null || \
    fail "this module is only verified for SkyController 2 firmware 1.0.9"

mkdir -p "$DATA_DIR" "$BACKUP_DIR"
cp "$SOURCE_MODULE" "$MODULE"
chmod 644 "$MODULE"

cat > "$RELAY" <<'EOF_RELAY'
#!/bin/sh
exec /usr/bin/telnet 192.168.42.1
EOF_RELAY
chmod 755 "$RELAY"

# A single short Boxinit service name is intentional. SC2 Boxinit silently
# ignores the older long parrotlab-* service names. The process loads the
# module, then becomes the persistent drone Telnet relay on TCP 2324.
cat > "$BOOT_HELPER" <<'EOF_BOOT'
#!/bin/sh

MODULE=/data/lib/parrotlab/apple_mac_ncm.ko
RELAY=/data/lib/parrotlab/drone_telnet_relay.sh
LOG=/tmp/parrotlab-apple-ncm.log
MAX_TRIES=60
TRY=0

echo "parrotlab: plboot started at uptime $(cat /proc/uptime 2>/dev/null)" >> "$LOG"
while [ "$TRY" -lt "$MAX_TRIES" ]; do
    if grep -q '^apple_mac_ncm ' /proc/modules 2>/dev/null; then
        echo "parrotlab: apple_mac_ncm already loaded" >> "$LOG"
        break
    fi
    if [ -r "$MODULE" ] && /sbin/insmod "$MODULE" >> "$LOG" 2>&1; then
        echo "parrotlab: apple_mac_ncm loaded successfully" >> "$LOG"
        break
    fi
    TRY=$((TRY + 1))
    sleep 1
done

if ! grep -q '^apple_mac_ncm ' /proc/modules 2>/dev/null; then
    echo "parrotlab: ERROR: module failed to load after $MAX_TRIES tries" >> "$LOG"
    exit 1
fi

echo "parrotlab: starting drone relay on TCP 2324" >> "$LOG"
exec /usr/bin/nc -ll -p 2324 -e "$RELAY"
EOF_BOOT
chmod 755 "$BOOT_HELPER"

cat > "$UNINSTALL" <<'EOF_UNINSTALL'
#!/bin/sh
set -eu

DATA_DIR=/data/lib/parrotlab
BACKUP_DIR=$DATA_DIR/rc-backups
RC_FILE=/etc/boxinit.d/99-plboot.rc
LEGACY_RC_FILES="
/etc/boxinit.d/51-parrotlab-usb.rc
/etc/boxinit.d/99-parrotlab-usb.rc
/etc/boxinit.d/99-pltest.rc
/etc/boxinit.d/99-plncm.rc
"

[ "$(id -u)" = "0" ] || { echo "ERROR: run as root" >&2; exit 1; }
mount -o remount,rw /
rm -f "$RC_FILE"
for FILE in $LEGACY_RC_FILES; do
    BACKUP="$BACKUP_DIR/$(basename "$FILE").before-plboot"
    if [ -r "$BACKUP" ]; then
        cp "$BACKUP" "$FILE"
    fi
done
sync
mount -o remount,ro /

rm -f "$DATA_DIR/apple_mac_ncm.ko" \
    "$DATA_DIR/parrotlab_boot.sh" \
    "$DATA_DIR/drone_telnet_relay.sh"
echo "Removed the Parrot Lab SC2 Apple-NCM boot installation."
echo "Reboot the SC2 to finish rollback."
EOF_UNINSTALL
chmod 755 "$UNINSTALL"

mount -o remount,rw /
ROOT_RW=1

# Preserve any pre-existing experimental RC entries once, then remove them so
# only the proven short production service can be active after reboot.
for FILE in $LEGACY_RC_FILES; do
    if [ -e "$FILE" ]; then
        BACKUP="$BACKUP_DIR/$(basename "$FILE").before-plboot"
        [ -e "$BACKUP" ] || cp "$FILE" "$BACKUP"
        rm -f "$FILE"
    fi
done

cat > "$RC_FILE" <<'EOF_RC'
service plboot /bin/sh /data/lib/parrotlab/parrotlab_boot.sh
    class main
    user root
EOF_RC
chmod 0640 "$RC_FILE"

sync
mount -o remount,ro /
ROOT_RW=0

echo "Installed Parrot Lab SC2 Apple-NCM boot configuration."
echo "Service: plboot"
echo "RC file: $RC_FILE"
echo "Module: $MODULE"
echo "Rollback: $UNINSTALL"
echo "The module has not been loaded by this installer; reboot to activate it."
echo "__PARROTLAB_SC2_DRIVER_SCRIPT__=INSTALLED"
