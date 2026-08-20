#!/bin/sh
# Remove the experimental driver. No reboot is required.

if grep -q '^apple_mac_ncm ' /proc/modules; then
	if rmmod apple_mac_ncm; then
		echo "Apple-NCM driver unloaded. The SC2 is back to its stock state."
	else
		echo "Unload failed; disconnect the Mac cable and try again."
		exit 1
	fi
else
	echo "Apple-NCM driver is not loaded; nothing to undo."
fi
