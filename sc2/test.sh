#!/bin/sh
# Reversible, non-persistent loader for the Apple private-NCM SC2 driver.

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)
MODULE="${1:-$SCRIPT_DIR/apple_mac_ncm.ko}"
LOG=/tmp/sc2-mac-ncm-test.log
DRIVER=/sys/bus/usb/drivers/apple_mac_ncm

say()
{
	echo "$*"
	echo "$*" >> "$LOG"
}

: > "$LOG"
say "SC2 Apple-NCM test (nothing is installed persistently)"
say "Kernel: $(uname -r)"

if [ ! -r "$MODULE" ]; then
	say "ERROR: cannot read $MODULE"
	exit 1
fi

if grep -q '^apple_mac_ncm ' /proc/modules; then
	say "Driver is already loaded. Reusing it."
else
	say "Loading $MODULE"
	if ! insmod "$MODULE" 2>> "$LOG"; then
		say "ERROR: insmod failed. Recent kernel messages:"
		dmesg | tail -40 | tee -a "$LOG"
		exit 1
	fi
fi

say "Connect the Mac to the SC2 USB-A port now (or leave it connected)."
say "Waiting up to 45 seconds for Apple's private NCM interfaces..."

i=0
while [ "$i" -lt 45 ]; do
	bound=0
	if [ -d "$DRIVER" ]; then
		for node in "$DRIVER"/*:*; do
			[ -e "$node" ] && bound=$((bound + 1))
		done
	fi
	[ "$bound" -gt 0 ] && break
	i=$((i + 1))
	sleep 1
done

if [ "${bound:-0}" -eq 0 ]; then
	say "No Mac interface bound. Check the data cable, then rerun this script."
	dmesg | tail -60 | tee -a "$LOG"
	exit 2
fi

say "SUCCESS: $bound Apple private-NCM USB interface(s) bound."
sleep 4
say "Network state:"
ifconfig -a | tee -a "$LOG"
say "Recent kernel messages:"
dmesg | tail -80 | tee -a "$LOG"
say ""
say "The stock usbnetd service should assign each new eth*/usb* link a"
say "192.168.X.1 address and offer DHCP to the Mac. Keep this terminal open."
say "To undo the test: sh $SCRIPT_DIR/unload_sc2_mac_ncm.sh"
say "Log: $LOG"
