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
echo "Disconnect the Mac and reboot the SC2 to finish rollback."
