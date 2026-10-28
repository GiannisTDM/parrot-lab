#!/bin/sh
# SC3-side v1c installer/unhooker. No motor commands, reboot, pairing or RF writes.
# Run only from an integrity-checked, host-created private staging directory.
set -eu
action=${1:-}
case "$action" in install|remove-hook) ;; *) echo 'Expected install|remove-hook' >&2; exit 2;; esac
stage=${0%/*}
case "$stage" in /data/lib/mppd/sc3-app-stage-*) ;; *) exit 2;; esac
suffix=${stage##*/sc3-app-stage-}
test "${#suffix}" = 32
case "$suffix" in *[!0-9a-f]*) exit 2;; esac
sha() { sha1sum "$1" | cut -d ' ' -f 1; }
stock=52398949fe32b46b0251b2c7f63942593c068d62
patch=83874fd41722c8391b3e530c7fce0e2ff3bab461
stock_init=bcd89c78ce123680b3c40f3dbbaf61fffb54b0fc
selector_sha=0be1f74b8829fb66d07a8401fd7330b4a5016d87
config_sha=5e6af16f7bddfdf0c604c364a3e6d129497ff07f
control_sha=1b22641d969a0a2fef45d72d1f51bd4ab5c66b99
data=/data/lib/mppd/native-sumo
backup=/data/lib/mppd/native-sumo-backup
selector=/usr/bin/sc3-native-sumo-start
config=/etc/boxinit.d/99-mppd.rc
lock=/tmp/sc3-app-maintenance.lock
test "$(id -u)" = 0
test "$(gprop ro.product.model)" = 'Skycontroller 3'
test "$(gprop ro.parrot.build.version)" = 1.8.1
test "$(gprop ro.revision)" = 3
test ! -e /ramdiag/trace-profile
grep -q '^ubi0:rootfs / ubifs ro,' /proc/mounts
for dir in /data /data/lib /data/lib/mppd "$stage" "$data" "$backup"; do
    test ! -L "$dir"
done
test ! -L "$data/enabled"
for file in startup.sh control.sh 99-mppd.native.rc mppd.native-sumo-v1c; do
    test -f "$stage/$file"
    test ! -L "$stage/$file"
done
test "$(sha "$stage/startup.sh")" = "$selector_sha"
test "$(sha "$stage/control.sh")" = "$control_sha"
test "$(sha "$stage/99-mppd.native.rc")" = "$config_sha"
test "$(sha "$stage/mppd.native-sumo-v1c")" = "$patch"
/bin/sh -n "$stage/startup.sh"
/bin/sh -n "$stage/control.sh"
current=$(sha /usr/bin/mppd)
test "$current" = "$stock" || test "$current" = "$patch"
test ! -L "$config"
current_config=$(sha "$config")
test "$current_config" = "$stock_init" || test "$current_config" = "$config_sha"
if test -e "$selector"; then test ! -L "$selector"; test "$(sha "$selector")" = "$selector_sha"; fi
if test -e "$data/control.sh"; then test ! -L "$data/control.sh"; test "$(sha "$data/control.sh")" = "$control_sha"; fi
umask 077
mkdir "$lock"
root_rw=no
cleanup() {
    if test "$root_rw" = yes; then sync; mount -o remount,ro /; fi
    /bin/busybox rmdir "$lock"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
mkdir -p "$data" "$backup"
chmod 700 "$data" "$backup"

# Never overwrite backup evidence. Unknown/missing provenance fails closed.
if test ! -e "$backup/mppd.stock-1.8.1"; then
    test ! -L "$backup/mppd.stock-1.8.1"
    test "$current" = "$stock"
    test ! -e "$backup/mppd.copy-pending"
    test ! -L "$backup/mppd.copy-pending"
    cp /usr/bin/mppd "$backup/mppd.copy-pending"
    chmod 700 "$backup/mppd.copy-pending"
    test "$(sha "$backup/mppd.copy-pending")" = "$stock"
    mv "$backup/mppd.copy-pending" "$backup/mppd.stock-1.8.1"
fi
test ! -L "$backup/mppd.stock-1.8.1"
test "$(sha "$backup/mppd.stock-1.8.1")" = "$stock"
if test ! -e "$backup/99-mppd.rc.stock"; then
    test ! -L "$backup/99-mppd.rc.stock"
    test "$current_config" = "$stock_init"
    test ! -e "$backup/init.copy-pending"
    test ! -L "$backup/init.copy-pending"
    cp "$config" "$backup/init.copy-pending"
    chmod 600 "$backup/init.copy-pending"
    test "$(sha "$backup/init.copy-pending")" = "$stock_init"
    mv "$backup/init.copy-pending" "$backup/99-mppd.rc.stock"
fi
test ! -L "$backup/99-mppd.rc.stock"
test "$(sha "$backup/99-mppd.rc.stock")" = "$stock_init"

if test "$action" = remove-hook; then
    test "$(sha "$data/control.sh")" = "$control_sha"
    sh "$data/control.sh" stock
    test ! -e /etc/99-mppd.sc3-app.pending
    test ! -L /etc/99-mppd.sc3-app.pending
    mount -o remount,rw /
    root_rw=yes
    cp "$backup/99-mppd.rc.stock" /etc/99-mppd.sc3-app.pending
    chmod 640 /etc/99-mppd.sc3-app.pending
    test "$(sha /etc/99-mppd.sc3-app.pending)" = "$stock_init"
    mv /etc/99-mppd.sc3-app.pending "$config"
    sync
    mount -o remount,ro /
    root_rw=no
    echo 'Stock restored; init hook removed. Selector retained for cached init until next normal boot. Backups retained.'
    exit 0
fi

if test -e "$data/mppd.native-sumo-v1c"; then
    test ! -L "$data/mppd.native-sumo-v1c"
    test "$(sha "$data/mppd.native-sumo-v1c")" = "$patch"
else
    test ! -L "$data/mppd.native-sumo-v1c"
    test ! -e "$data/mppd.app-pending"
    test ! -L "$data/mppd.app-pending"
    cp "$stage/mppd.native-sumo-v1c" "$data/mppd.app-pending"
    chmod 700 "$data/mppd.app-pending"
    test "$(sha "$data/mppd.app-pending")" = "$patch"
    mv "$data/mppd.app-pending" "$data/mppd.native-sumo-v1c"
fi

# Publish selector first, then init reference; never replace underlying mppd.
for file in /usr/bin/sc3-native-sumo-start.app-pending /etc/99-mppd.sc3-app.pending "$data/control.app-pending"; do
    test ! -e "$file"; test ! -L "$file"
done
mount -o remount,rw /
root_rw=yes
cp "$stage/startup.sh" /usr/bin/sc3-native-sumo-start.app-pending
chmod 755 /usr/bin/sc3-native-sumo-start.app-pending
test "$(sha /usr/bin/sc3-native-sumo-start.app-pending)" = "$selector_sha"
mv /usr/bin/sc3-native-sumo-start.app-pending "$selector"
cp "$stage/99-mppd.native.rc" /etc/99-mppd.sc3-app.pending
chmod 640 /etc/99-mppd.sc3-app.pending
test "$(sha /etc/99-mppd.sc3-app.pending)" = "$config_sha"
mv /etc/99-mppd.sc3-app.pending "$config"
sync
mount -o remount,ro /
root_rw=no
cp "$stage/control.sh" "$data/control.app-pending"
chmod 700 "$data/control.app-pending"
test "$(sha "$data/control.app-pending")" = "$control_sha"
mv "$data/control.app-pending" "$data/control.sh"
sh "$data/control.sh" enable
sync
echo 'v1c installed, automatic startup enabled. Current daemon NOT restarted. No reboot/drive/jump command sent.'
