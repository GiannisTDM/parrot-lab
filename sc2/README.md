# SkyController 2 support

This directory contains the driver and boot integration that let an Apple
Silicon Mac use the SC2 USB-A host port as a network link.

## Included files

- `apple_mac_ncm.c`: adapted Apple private CDC-NCM host driver source
- `apple_mac_ncm.ko`: prebuilt module for the tested SC2 1.0.9 kernel
- `install.sh`: persistent module loader and drone telemetry relay
- `uninstall.sh`: removes Parrot Lab boot integration
- `test.sh` / `unload.sh`: reversible, non-persistent driver test
- `Makefile`: reference build file for an appropriate SC2 kernel tree

## Verify after installation

After rebooting the SC2:

```sh
grep '^apple_mac_ncm ' /proc/modules
netstat -ltn | grep ':2324 '
cat /tmp/parrotlab-boot.log
```

The expected module state contains `apple_mac_ncm ... [permanent], Live`. Once
the Mac is connected, `ifconfig usb0` should normally show `192.168.53.1` and
the Mac should receive an address such as `192.168.53.13`.

## Confirmed boxinit persistence bug

The first installer used the boxinit service names `parrotlab-apple-ncm` and
`parrotlab-drone-telnet`. The files were present, `/data` was mounted, and the
module itself loaded successfully when invoked, but those 19- and 22-character
services were silently never started at boot.

A short service named `plncm` proved that `class main` custom services execute
correctly. The production installer therefore uses one short service name,
`plboot`, and delegates both jobs to `/data/lib/parrotlab/parrotlab_boot.sh`.
Do not change it back to a long `parrotlab-*` boxinit service name.

During installation, these obsolete experimental RC files are removed:

```text
/etc/boxinit.d/51-parrotlab-usb.rc
/etc/boxinit.d/99-parrotlab-usb.rc
/etc/boxinit.d/99-pltest.rc
/etc/boxinit.d/99-plncm.rc
```

Only `/etc/boxinit.d/99-plboot.rc` remains, with mode `0640`.
