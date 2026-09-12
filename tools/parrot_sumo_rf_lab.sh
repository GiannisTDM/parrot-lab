#!/bin/sh
# Parrot RF Lab: Jumping Sumo edition. EPA2 / PD14 and active NVM path
# confirmed by the owner. All other power/identity/regulatory values stay intact.
# Firmware 1.99.0 /bin/globals.sh names bcm43526.nvm; broadcom_setup.sh
# names wifi_bcm. Do not apply the SC2's EPA2 / PD16 / MAXP80 preset here.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
WL_BIN=${WL_BIN:-/usr/sbin/bcmwl}
NVM=${RF_LAB_NVM:-/lib/firmware/brcm/bcm43526.nvm}
IFACE=${RF_LAB_IFACE:-}
BACKUPS=${RF_LAB_FTP_ROOT:-/data/ftp/internal_000}/sumo_rf_lab_backups
STAGE=
RESTORE_RO=0
WRITE_STARTED=0

root_is_rw()
{
    mount | awk '$3 == "/" {rw=($0 ~ /\(rw[,)]/)} END {exit(rw ? 0 : 1)}'
}

restore_root()
{
    if [ "$RESTORE_RO" = 1 ]; then
        mount -o remount,ro / || return 1
        root_is_rw && return 1
        RESTORE_RO=0
    fi
}

cleanup()
{
    if [ "$WRITE_STARTED" = 1 ]; then
        if cp "$BACKUP" "$NVM" && sync && cmp -s "$BACKUP" "$NVM"; then
            printf '%s\n' 'Interrupted write: original NVM restored.' >&2
        else
            printf 'CRITICAL: restore failed; do not reboot. Backup: %s\n' "$BACKUP" >&2
        fi
    fi
    restore_root || printf '%s\n' 'WARNING: could not restore root read-only' >&2
    [ -z "$STAGE" ] || rm -f "$STAGE" "${STAGE}.compare"
}
trap cleanup 0
trap 'exit 130' HUP INT TERM

rf_error()
{
    printf '__PARROTLAB_RF_PROFILE__=ERROR:%s\n' "$1" >&2
    return 1
}

nvm_value()
{
    awk -F= -v key="$1" '$1 == key {print $2}' "$2"
}

apply_profile()
{
    case "$1" in epa2_pd14|stock) ;; *) rf_error UNSUPPORTED_PROFILE; return 1 ;; esac
    [ -f "$NVM" ] && [ ! -L "$NVM" ] || { rf_error ACTIVE_NVM_MISSING_OR_SYMLINK; return 1; }
    for key in epagain2g pdgain2g macaddr boardtype boardrev; do
        [ "$(grep -c "^$key=" "$NVM")" = 1 ] || { rf_error INVALID_NVM; return 1; }
    done
    mkdir -p "$BACKUPS" || { rf_error BACKUP_DIRECTORY; return 1; }
    BASELINE=$BACKUPS/sumo-parrotlab-original.nvm
    if [ "$1" = epa2_pd14 ]; then
        EPA=2; PD=14
        if [ "$(nvm_value epagain2g "$NVM")" = 2 ] && [ "$(nvm_value pdgain2g "$NVM")" = 14 ]; then
            printf '%s\n' '__PARROTLAB_RF_PROFILE__=OK:sumo:ALREADY_ENABLED'
            return 0
        fi
        if [ ! -e "$BASELINE" ]; then
            cp -p "$NVM" "$BASELINE" && cmp -s "$NVM" "$BASELINE" || { rf_error BASELINE_BACKUP; return 1; }
            md5sum "$BASELINE" > "$BASELINE.md5" || return 1
        fi
        [ -s "$BASELINE.md5" ] && md5sum -c "$BASELINE.md5" || { rf_error BASELINE_DAMAGED; return 1; }
    else
        [ -s "$BASELINE" ] && [ -s "$BASELINE.md5" ] && md5sum -c "$BASELINE.md5" || {
            rf_error ORIGINAL_BASELINE_MISSING_OR_DAMAGED; return 1
        }
        for key in macaddr boardtype boardrev; do
            [ "$(nvm_value "$key" "$NVM")" = "$(nvm_value "$key" "$BASELINE")" ] || {
                rf_error BASELINE_IDENTITY_MISMATCH; return 1
            }
        done
        EPA=$(nvm_value epagain2g "$BASELINE"); PD=$(nvm_value pdgain2g "$BASELINE")
        case "$EPA:$PD" in *[!0-9:]*|:*|*:) rf_error INVALID_BASELINE; return 1 ;; esac
    fi
    STAGE=$(mktemp /tmp/parrot-sumo-rf.XXXXXX) || return 1
    awk -v epa="$EPA" -v pd="$PD" '
        /^epagain2g=/ {print "epagain2g=" epa; next}
        /^pdgain2g=/ {print "pdgain2g=" pd; next}
        {print}
    ' "$NVM" > "$STAGE" || return 1
    # Prove no other line changed; never touch MAXP, PA tables, MAC or country.
    sed '/^epagain2g=/d; /^pdgain2g=/d' "$NVM" > "$STAGE.compare" || return 1
    sed '/^epagain2g=/d; /^pdgain2g=/d' "$STAGE" | cmp -s - "$STAGE.compare" || {
        rf_error UNEXPECTED_CHANGE; return 1
    }
    BACKUP=$BACKUPS/sumo-$(date +%Y%m%d-%H%M%S)-$$.nvm
    cp -p "$NVM" "$BACKUP" && cmp -s "$NVM" "$BACKUP" && sync || { rf_error BACKUP_FAILED; return 1; }
    if ! root_is_rw; then
        RESTORE_RO=1
        mount -o remount,rw / || { rf_error REMOUNT_FAILED; return 1; }
        root_is_rw || { rf_error ROOT_STILL_READ_ONLY; return 1; }
    fi
    WRITE_STARTED=1
    if ! { cp "$STAGE" "$NVM" && sync && cmp -s "$STAGE" "$NVM"; }; then
        if cp "$BACKUP" "$NVM" && sync && cmp -s "$BACKUP" "$NVM"; then
            WRITE_STARTED=0
            rf_error WRITE_FAILED_ORIGINAL_RESTORED
        else
            rf_error RESTORE_FAILED_DO_NOT_REBOOT
            printf 'Recovery backup: %s\n' "$BACKUP" >&2
        fi
        return 1
    fi
    WRITE_STARTED=0
    restore_root || { rf_error READ_ONLY_RESTORE_FAILED; return 1; }
    printf '__PARROTLAB_RF_PROFILE__=OK:sumo:%s\n' "$1"
}

if [ -z "$IFACE" ]; then
    if [ -d /sys/class/net/wifi_bcm ]; then
        IFACE=wifi_bcm
    elif [ -r /proc/net/wireless ]; then
        IFACE=$(awk -F: 'NR > 2 {gsub(/ /,"",$1); print $1; exit}' /proc/net/wireless)
    fi
fi

query()
{
    printf '\n%s\n' "--- $* ---"
    if [ -n "$IFACE" ]; then
        "$WL_BIN" -i "$IFACE" "$@" 2>&1 || printf '%s\n' 'Unavailable on this firmware'
    else
        "$WL_BIN" "$@" 2>&1 || printf '%s\n' 'Unavailable on this firmware'
    fi
}

status()
{
    printf '%s\n' 'Parrot RF Lab - Jumping Sumo (EPA2 / PD14)' "Interface: ${IFACE:-driver default}"
    for item in ver ssid bssid assoclist rssi noise chanspec country qtxpower counters; do
        query "$item"
    done
}

case "${1:-menu}" in
    status|menu)
        status
        printf '\n%s\n' 'Commands: status, monitor, diagnostics, apply-profile epa2_pd14, apply-profile stock.'
        printf '%s\n' 'Status is read-only. Power changes require a reboot; stock restores the preserved original EPA/PD.'
        ;;
    monitor)
        trap 'exit 0' INT TERM HUP
        while :; do status; sleep 2; done
        ;;
    diagnostics)
        status
        query nvram_dump
        printf '\n%s\n' "NVM candidate: $NVM"
        if [ -r "$NVM" ]; then
            ls -l "$NVM"
            md5sum "$NVM"
            # Read only; never source NVM contents or remount/write the filesystem.
            sed -n '1,240p' "$NVM"
        else
            printf '%s\n' 'NVM not readable. Confirm the active NVM path on this Sumo.'
        fi
        ;;
    apply-profile)
        # Factory/OTP writes are never supported, even via the diagnostics override.
        [ "$NVM" = /lib/firmware/brcm/bcm43526.nvm ] || { rf_error ACTIVE_PATH_NOT_CONFIRMED; exit 1; }
        apply_profile "${2:-}" || exit 1
        ;;
    *) printf '%s\n' 'Usage: sh parrot_sumo_rf_lab.sh [status|monitor|diagnostics|apply-profile epa2_pd14|apply-profile stock]' >&2; exit 2 ;;
esac
