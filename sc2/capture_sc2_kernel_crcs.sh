#!/bin/sh

# Read the SC2 kernel's exported-symbol CRC values. These are required by
# CONFIG_MODVERSIONS and are read-only accesses through /dev/kmem.

OUT=/var/lib/ftp/internal_000/sc2_kernel_crcs.txt
SYMBOLS="
module_layout
usbnet_probe
__alloc_skb
__netdev_alloc_skb
__netif_schedule
local_bh_disable
local_bh_enable
usb_driver_claim_interface
usb_ifnum_to_if
usb_set_interface
usbnet_get_ethernet_addr
usbnet_get_link
usbnet_get_msglevel
usbnet_get_settings
usbnet_nway_reset
usbnet_set_msglevel
usbnet_set_settings
"

if [ ! -r /dev/kmem ]; then
	echo "ERROR: /dev/kmem is not readable"
	exit 1
fi

date > "$OUT"
uname -a >> "$OUT"

for SYMBOL in $SYMBOLS; do
	LINE=$(grep " __kcrctab_${SYMBOL}$" /proc/kallsyms | head -n 1)
	ADDR=${LINE%% *}
	if [ -z "$ADDR" ]; then
		echo "MISSING $SYMBOL" >> "$OUT"
		continue
	fi
	SKIP=$((0x$ADDR / 4))
	CRC=$(dd if=/dev/kmem bs=4 skip="$SKIP" count=1 2>/dev/null |
		hexdump -v -e '1/4 "%08x"')
	if [ ${#CRC} -ne 8 ]; then
		echo "READ_ERROR $SYMBOL $ADDR" >> "$OUT"
	else
		echo "0x$CRC $SYMBOL" >> "$OUT"
	fi
done

echo "CRC capture complete: internal_000/sc2_kernel_crcs.txt"
