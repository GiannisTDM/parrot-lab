#!/bin/sh
set -eu

# Enable the stock developer-network script at boot on Bebop 2 firmware 4.4.2.
# The full system UBIFS gets headroom by relocating tcpdump to the writable
# eMMC. The rcS edit is reversible and / is always returned to read-only.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

RCS_FILE=/etc/init.d/rcS
RCS_STAGE=/tmp/parrotlab-rcS.$$
RCS_ORIGINAL=/tmp/parrotlab-rcS.original.$$
RCS_STOCK_MD5=9b435e97ffa79d6d94b5c5a101d09554
RCS_ENABLED_MD5=f6afeef2c65578fd05a24a780a8bc8de
TCPDUMP_FILE=/usr/sbin/tcpdump
TCPDUMP_STOCK_MD5=53a584f0e95536bd7ba72d27c4b56f51
BACKUP_DIR=/data/ftp/internal_000/parrotlab-system-backup
TCPDUMP_BACKUP=$BACKUP_DIR/tcpdump
ROOT_WRITABLE=0

emit()
{
    printf '__PARROTLAB_TELNET__=%s\n' "$1"
}

cleanup_temporary_files()
{
    rm -f "$RCS_STAGE" "$RCS_ORIGINAL" 2>/dev/null || true
}

file_digest()
{
    digest=$(md5sum "$1") || return 1
    printf '%s\n' "${digest%% *}"
}

root_mount_has_mode()
{
    awk -v wanted="$1" '
        $1 == "ubi1:system" && $2 == "/" && $3 == "ubifs" {
            count = split($4, options, ",")
            for (i = 1; i <= count; i++) {
                if (options[i] == wanted) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' /proc/mounts
}

restore_read_only()
{
    if [ "$ROOT_WRITABLE" -eq 1 ]; then
        sync
        /bin/mount / -o remount,ro >/dev/null 2>&1 || return 1
        root_mount_has_mode ro || return 1
        ROOT_WRITABLE=0
    fi
}

fail()
{
    restore_read_only >/dev/null 2>&1 || true
    cleanup_temporary_files
    emit "ERROR|$1"
    exit 1
}

trap 'restore_read_only >/dev/null 2>&1 || true; cleanup_temporary_files' 0
trap 'restore_read_only >/dev/null 2>&1 || true; cleanup_temporary_files; exit 1' HUP INT TERM

validate_firmware()
{
    grep -q '^ro.parrot.build.product=ardrone3$' /etc/build.prop || \
        fail NOT_BEBOP2_FIRMWARE
    grep -q '^ro.parrot.build.version=4\.4\.2$' /etc/build.prop || \
        fail UNSUPPORTED_FIRMWARE
    [ -f "$RCS_FILE" ] || fail RCS_NOT_FOUND
    [ -x /bin/usbnetwork.sh ] || fail USBNETWORK_NOT_FOUND
    [ -x /usr/bin/pstart ] || fail PSTART_NOT_AVAILABLE
}

make_root_writable()
{
    ROOT_WRITABLE=1
    /bin/mount / -o remount,rw >/dev/null 2>&1 || fail ROOT_REMOUNT_RW_FAILED
    root_mount_has_mode rw || fail ROOT_STILL_READ_ONLY
}

prepare_tcpdump_backup()
{
    mkdir -p "$BACKUP_DIR" || fail TCPDUMP_BACKUP_DIR_FAILED

    if [ -L "$TCPDUMP_FILE" ]; then
        [ "$(readlink "$TCPDUMP_FILE")" = "$TCPDUMP_BACKUP" ] || \
            fail UNKNOWN_TCPDUMP_SYMLINK
    elif [ -f "$TCPDUMP_FILE" ]; then
        [ "$(file_digest "$TCPDUMP_FILE")" = "$TCPDUMP_STOCK_MD5" ] || \
            fail UNKNOWN_TCPDUMP_FILE
        cp "$TCPDUMP_FILE" "$TCPDUMP_BACKUP" || fail TCPDUMP_BACKUP_FAILED
        chmod 0755 "$TCPDUMP_BACKUP" || fail TCPDUMP_BACKUP_CHMOD_FAILED
        sync
    fi

    [ -f "$TCPDUMP_BACKUP" ] || fail TCPDUMP_BACKUP_MISSING
    [ "$(file_digest "$TCPDUMP_BACKUP")" = "$TCPDUMP_STOCK_MD5" ] || \
        fail TCPDUMP_BACKUP_VERIFY_FAILED
}

relocate_tcpdump()
{
    if [ -L "$TCPDUMP_FILE" ]; then
        return 0
    fi
    [ -f "$TCPDUMP_FILE" ] || fail TCPDUMP_SOURCE_MISSING
    rm -f "$TCPDUMP_FILE" || fail TCPDUMP_REMOVE_FAILED
    sync
    ln -s "$TCPDUMP_BACKUP" "$TCPDUMP_FILE" || fail TCPDUMP_LINK_FAILED
    [ -x "$TCPDUMP_FILE" ] || fail TCPDUMP_LINK_VERIFY_FAILED
}

stage_enabled_rcs()
{
    awk '{
        if ($0 == "exit 0") print "/bin/usbnetwork.sh"
        print
    }' "$RCS_FILE" > "$RCS_STAGE" || fail RCS_STAGE_FAILED
    [ "$(file_digest "$RCS_STAGE")" = "$RCS_ENABLED_MD5" ] || \
        fail RCS_STAGE_VERIFY_FAILED
}

stage_stock_rcs()
{
    awk '$0 != "/bin/usbnetwork.sh" { print }' "$RCS_FILE" > "$RCS_STAGE" || \
        fail RCS_STAGE_FAILED
    [ "$(file_digest "$RCS_STAGE")" = "$RCS_STOCK_MD5" ] || \
        fail RCS_STAGE_VERIFY_FAILED
}

write_staged_rcs()
{
    cp "$RCS_FILE" "$RCS_ORIGINAL" || fail RCS_TEMP_BACKUP_FAILED
    if ! cat "$RCS_STAGE" > "$RCS_FILE"; then
        cat "$RCS_ORIGINAL" > "$RCS_FILE" 2>/dev/null || true
        fail RCS_WRITE_FAILED
    fi
    chmod 0755 "$RCS_FILE" || fail RCS_CHMOD_FAILED
    sync
}

install_service()
{
    validate_firmware
    current_digest=$(file_digest "$RCS_FILE") || fail RCS_DIGEST_FAILED

    if [ "$current_digest" = "$RCS_ENABLED_MD5" ]; then
        /usr/bin/pstart telnetd >/dev/null 2>&1 || fail TELNET_START_FAILED
        emit INSTALLED
        return 0
    fi
    [ "$current_digest" = "$RCS_STOCK_MD5" ] || fail UNKNOWN_RCS_FILE

    prepare_tcpdump_backup
    stage_enabled_rcs
    make_root_writable
    relocate_tcpdump
    write_staged_rcs
    [ "$(file_digest "$RCS_FILE")" = "$RCS_ENABLED_MD5" ] || {
        cat "$RCS_ORIGINAL" > "$RCS_FILE" 2>/dev/null || true
        fail RCS_VERIFY_FAILED
    }
    restore_read_only || fail ROOT_REMOUNT_RO_FAILED
    cleanup_temporary_files
    /usr/bin/pstart telnetd >/dev/null 2>&1 || fail TELNET_START_FAILED
    emit INSTALLED
}

remove_service()
{
    validate_firmware
    current_digest=$(file_digest "$RCS_FILE") || fail RCS_DIGEST_FAILED
    if [ "$current_digest" = "$RCS_STOCK_MD5" ]; then
        emit REMOVED
        return 0
    fi
    [ "$current_digest" = "$RCS_ENABLED_MD5" ] || fail UNKNOWN_RCS_FILE

    stage_stock_rcs
    make_root_writable
    write_staged_rcs
    [ "$(file_digest "$RCS_FILE")" = "$RCS_STOCK_MD5" ] || {
        cat "$RCS_ORIGINAL" > "$RCS_FILE" 2>/dev/null || true
        fail RCS_REMOVE_VERIFY_FAILED
    }
    restore_read_only || fail ROOT_REMOUNT_RO_FAILED
    cleanup_temporary_files
    emit REMOVED
}

case "${1:-}" in
    install) install_service ;;
    uninstall) remove_service ;;
    status)
        if [ -r "$RCS_FILE" ] && \
           [ "$(file_digest "$RCS_FILE" 2>/dev/null || true)" = "$RCS_ENABLED_MD5" ]; then
            emit INSTALLED
        else
            emit NOT_INSTALLED
        fi
        ;;
    *)
        printf '%s\n' "Usage: $0 install|uninstall|status" >&2
        exit 2
        ;;
esac
