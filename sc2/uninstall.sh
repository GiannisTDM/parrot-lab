#!/bin/sh
set -eu

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: run this as root on the SkyController 2"
    exit 1
fi

mount -o remount,rw /
rm -f \
    /etc/boxinit.d/99-plboot.rc \
    /etc/boxinit.d/51-parrotlab-usb.rc \
    /etc/boxinit.d/99-parrotlab-usb.rc \
    /etc/boxinit.d/99-pltest.rc \
    /etc/boxinit.d/99-plncm.rc
sync
mount -o remount,ro /

if [ -r /tmp/parrotlab-drone-relay.pid ]; then
    kill "$(cat /tmp/parrotlab-drone-relay.pid)" 2>/dev/null || true
fi

echo "Parrot Lab boot integration removed."
echo "Disconnect the Mac and reboot before attempting to unload the module."
