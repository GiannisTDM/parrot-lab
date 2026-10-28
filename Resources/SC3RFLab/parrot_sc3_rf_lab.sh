#!/bin/sh
# SC3 1.8.1 / QCA6174 RF lab. Broadcom EPA/PD/MAXP presets do not apply.
# Dashboard/snapshot are read-only. Config writes require an explicit APPLY.
VERSION=0.2.0
IFACE=${RF_LAB_INTERFACE:-wlan0}
INI=${RF_LAB_CONFIG:-/lib/firmware/wlan/qcom_cfg.ini}
STATE=${RF_LAB_STATE_DIR:-/data/local/sc3-rf-lab}
LOG_DIR=${RF_LAB_LOG_DIR:-/data/lib/ftp/internal_000/rf_lab_logs}
BACKUP_DIR=$STATE/backups
INTERVAL=${RF_LAB_INTERVAL:-1}
COUNT=${RF_LAB_COUNT:-0}
FIXTURES=${RF_LAB_FIXTURE_DIR:-}
TEST_MODE=${RF_LAB_TEST_MODE:-0}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
QCA_HELPER=${RF_LAB_QCA_HELPER:-$SCRIPT_DIR/sc3-qca-rssi}
STAGE_DIR= STAGE= TARGET_TMP= ROOT_REMOUNTED=0 LOCK_OWNED=0 HIDDEN=0
ESC=$(printf '\033')
RESET= BOLD= DIM= CYAN= YELLOW= RED= GREEN= BLUE=
if [ "${NO_COLOR:-0}" != 1 ]; then
    RESET="${ESC}[0m"; BOLD="${ESC}[1m"; CYAN="${ESC}[96m"
    YELLOW="${ESC}[93m"; RED="${ESC}[91m"; GREEN="${ESC}[92m"
    DIM="${ESC}[2m"; BLUE="${ESC}[94m"
fi

die() { printf '%s\n' "$*" >&2; return 1; }
unsigned() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
integer() { case "$1" in -*) unsigned "${1#-}";; *) unsigned "$1";; esac; }
power_value() { unsigned "$1" && [ "$1" -ge 1 ] && [ "$1" -le 30 ]; }
digest() { sha1sum "$1" 2>/dev/null | awk '{print $1}'; }
value_of() { printf '%s\n' "$1" | awk -F= -v key="$2" '$1==key {sub(/^[^=]*=/, "");print;exit}'; }
ini_get()
{
    awk -v key="$1" '
        /^[ \t]*#/ {next}
        {p=index($0,"=");if(!p)next;k=substr($0,1,p-1);gsub(/[ \t]/,"",k)
         if(k==key){v=substr($0,p+1);sub(/[ \t]*#.*/,"",v);gsub(/^[ \t]+|[ \t\r]+$/,"",v);print v;exit}}
    ' "${2:-$INI}"
}
root_rw()
{
    [ "$TEST_MODE" = 1 ] && return 0
    awk '$2=="/" {rw=($4 ~ /^rw(,|$)/)} END {exit !rw}' /proc/mounts
}
restore_mount()
{
    if [ "$ROOT_REMOUNTED" = 1 ]; then
        mount -o remount,ro / || { die 'WARNING: could not restore / read-only; run mount -o remount,ro /'; return 1; }
        ROOT_REMOUNTED=0
    fi
}
cleanup()
{
    [ -z "$TARGET_TMP" ] || rm -f "$TARGET_TMP"
    restore_mount
    if [ "$LOCK_OWNED" = 1 ]; then rmdir "$STATE/apply.lock" 2>/dev/null; fi
    if [ -n "$STAGE_DIR" ]; then
        rm -f "$STAGE_DIR/config.ini" "$STAGE_DIR/base.ini" "$STAGE_DIR/next.ini" "$STAGE_DIR/base.other" "$STAGE_DIR/stage.other"
        rmdir "$STAGE_DIR" 2>/dev/null
    fi
    [ "$HIDDEN" = 0 ] || printf '%s[?25h' "$ESC"
    printf '%s' "$RESET"
}
trap cleanup 0
trap 'exit 130' 1 2 15

verify_device()
{
    case "$IFACE" in ''|*[!A-Za-z0-9_.:-]*) die 'Invalid interface name'; return 1;; esac
    if [ -n "$FIXTURES" ]; then
        [ "$TEST_MODE" = 1 ] || { die 'Fixtures require RF_LAB_TEST_MODE=1'; return 1; }
        return 0
    fi
    [ "$(gprop ro.hardware 2>/dev/null)" = mpp3 ] || { die 'This tool supports Skycontroller 3 (mpp3), not SC2 or ANAFI.'; return 1; }
    [ "$(gprop ro.parrot.build.version 2>/dev/null)" = 1.8.1 ] || { die 'Only SC3 firmware 1.8.1 has been validated.'; return 1; }
    [ -x /usr/sbin/iw ] && [ -x /sbin/iwpriv ] && [ -r "$INI" ] || { die 'SC3 radio tools/configuration missing'; return 1; }
}

query()
{
    _query=$1
    if [ -n "$FIXTURES" ]; then
        [ -f "$FIXTURES/$_query.txt" ] || return 1
        cat "$FIXTURES/$_query.txt"
        return
    fi
    case "$_query" in
        link) /usr/sbin/iw dev "$IFACE" link;;
        station) /usr/sbin/iw dev "$IFACE" station dump;;
        survey) /usr/sbin/iw dev "$IFACE" survey dump;;
        info) /usr/sbin/iw dev "$IFACE" info;;
        phy) /usr/sbin/iw phy phy0 info;;
        regulatory) /usr/sbin/iw reg get;;
        iwconfig) /sbin/iwconfig "$IFACE";;
        version) /sbin/iwpriv "$IFACE" version;;
        counters) awk -v iface="$IFACE:" '$1==iface {print $2,$3,$4,$5,$10,$11,$12,$13}' /proc/net/dev;;
        uptime) awk '{print $1}' /proc/uptime;;
        bdf) cat /sys/module/wlan/parameters/bdf;;
        chain) [ -x "$QCA_HELPER" ] && "$QCA_HELPER" "$IFACE" "$PEER";;
        *) return 2;;
    esac
}

# Only fields actually provided by this driver are used. Its station dump
# reports the local station MAC, so peer identity must come from `iw link`.
parse_link()
{
    awk '
      /^Connected to / {print "peer="tolower($3);connected=1}
      /^[ \t]*SSID: / {sub(/^[ \t]*SSID: /,"");print "ssid="$0}
      /^[ \t]*freq:/ {print "frequency="$2}
      /^[ \t]*signal:/ {print "signal="$2}
      /^[ \t]*tx bitrate:/ {print "tx_rate="$3}
      /^[ \t]*rx bitrate:/ {print "rx_rate="$3}
      END {print "connected="(connected?1:0)}'
}
parse_station()
{
    awk '
      /^[ \t]*signal avg:/ {print "signal_avg="$3;next}
      /^[ \t]*signal:/ {print "signal="$2}
      /^[ \t]*tx bitrate:/ {print "tx_rate="$3}
      /^[ \t]*rx bitrate:/ {print "rx_rate="$3}
      /^[ \t]*tx retries:/ {print "retries="$3}
      /^[ \t]*tx failed:/ {print "failed="$3}
      /^[ \t]*rx drop misc:/ {print "rx_drop_misc="$4}'
}
parse_noise()
{
    awk '
      /Survey data/ {noise="";active=0}
      /frequency:.*\[in use\]/ {active=1}
      /^[ \t]*noise:/ {noise=$2}
      active && noise!="" {print noise;exit}'
}
parse_txpower()
{
    awk '{line=$0;if(match(line,/Tx-Power[=:][ \t]*-?[0-9]+/)){s=substr(line,RSTART,RLENGTH);sub(/^[^=:]*[=:][ \t]*/,"",s);print s;exit}}'
}
load_sample()
{
    LINK_RAW=$(query link 2>/dev/null)
    LINK=$(printf '%s\n' "$LINK_RAW" | parse_link)
    CONNECTED=$(value_of "$LINK" connected)
    PEER=$(value_of "$LINK" peer); SSID=$(value_of "$LINK" ssid | LC_ALL=C tr -d '\000-\037\177')
    FREQUENCY=$(value_of "$LINK" frequency)
    SIGNAL=$(value_of "$LINK" signal)
    STATION_RAW= STATION= CHAIN= A0= A1= NOISE= SNR= TXPOWER=
    TX_RATE= RX_RATE= RETRIES= FAILED= SIGNAL_AVG=
    if [ "$CONNECTED" = 1 ]; then
        STATION_RAW=$(query station 2>/dev/null)
        STATION=$(printf '%s\n' "$STATION_RAW" | parse_station)
        TX_RATE=$(value_of "$STATION" tx_rate); RX_RATE=$(value_of "$STATION" rx_rate)
        [ -n "$TX_RATE" ] || TX_RATE=$(value_of "$LINK" tx_rate)
        [ -n "$RX_RATE" ] || RX_RATE=$(value_of "$LINK" rx_rate)
        RETRIES=$(value_of "$STATION" retries); FAILED=$(value_of "$STATION" failed)
        SIGNAL_AVG=$(value_of "$STATION" signal_avg)
        CHAIN=$(query chain 2>/dev/null)
        A0=$(value_of "$CHAIN" chain0_dbm); A1=$(value_of "$CHAIN" chain1_dbm)
        integer "$A0" || A0=; integer "$A1" || A1=
        NOISE=$(query survey 2>/dev/null | parse_noise)
        if integer "$SIGNAL" && integer "$NOISE"; then SNR=$((SIGNAL-NOISE)); fi
        TXPOWER=$(query iwconfig 2>/dev/null | parse_txpower)
    fi
    _counters=$(query counters 2>/dev/null)
    set -- $_counters
    RX_BYTES=${1:-}; RX_PACKETS=${2:-}; RX_ERRORS=${3:-}; RX_DROPS=${4:-}
    TX_BYTES=${5:-}; TX_PACKETS=${6:-}; TX_ERRORS=${7:-}; TX_DROPS=${8:-}
    NOW=$(query uptime 2>/dev/null)
    # Use actual monotonic elapsed time, not requested sleep interval. Rebase
    # on link changes/counter resets; do not report a first-sample spike.
    RATES=$(awk -v now="$NOW" -v previous="${PREV_TIME:-}" -v rx="$RX_BYTES" -v prx="${PREV_RX:-}" -v tx="$TX_BYTES" -v ptx="${PREV_TX:-}" -v peer="$PEER" -v prev_peer="${PREV_PEER:-}" '
      BEGIN {if(now==""||previous==""||now<=previous||rx==""||tx==""||prx==""||ptx==""||rx<prx||tx<ptx||peer!=prev_peer){print "NA|NA|NA";exit}
      dt=now-previous;printf "%.3f|%.3f|%.3f\n",(tx-ptx)*8/dt/1000000,(rx-prx)*8/dt/1000000,dt}')
    OLD_IFS=$IFS; IFS='|'; set -- $RATES; IFS=$OLD_IFS
    TX_MBPS=$1; RX_MBPS=$2; ELAPSED=$3
    D_RETRIES=$(delta "$RETRIES" "${PREV_RETRIES:-}")
    D_FAILED=$(delta "$FAILED" "${PREV_FAILED:-}")
    D_RX_ERRORS=$(delta "$RX_ERRORS" "${PREV_RX_ERRORS:-}")
    D_TX_ERRORS=$(delta "$TX_ERRORS" "${PREV_TX_ERRORS:-}")
    if [ "$PEER" != "${PREV_PEER:-}" ]; then D_RETRIES=NA; D_FAILED=NA; fi
    PREV_TIME=$NOW; PREV_RX=$RX_BYTES; PREV_TX=$TX_BYTES; PREV_PEER=$PEER
    PREV_RETRIES=$RETRIES; PREV_FAILED=$FAILED; PREV_RX_ERRORS=$RX_ERRORS; PREV_TX_ERRORS=$TX_ERRORS
    if integer "$A0" && integer "$A1"; then CHAIN_MEAN=$(((A0+A1)/2)); else CHAIN_MEAN=; fi
}
delta()
{
    if unsigned "$1" && unsigned "$2" && [ "$1" -ge "$2" ]; then printf '%s' "$(($1-$2))"; else printf NA; fi
}
signal_text()
{
    _s=$1
    if ! integer "$_s"; then printf 'not available'; return; fi
    _colour=$GREEN; [ "$_s" -ge -65 ] || _colour=$YELLOW; [ "$_s" -ge -80 ] || _colour=$RED
    _filled=$(((_s+95)*24/65)); [ "$_filled" -ge 0 ] || _filled=0; [ "$_filled" -le 24 ] || _filled=24
    printf '%s' "$_colour"
    printf '%*s' "$_filled" '' | tr ' ' '='
    printf '%*s' "$((24-_filled))" '' | tr ' ' '.'
    printf ' %4s dBm%s' "$_s" "$RESET"
}
header()
{
    printf '%sPARROT RF LAB %s | Skycontroller 3 | QCA6174%s\n' "$BOLD$CYAN" "$VERSION" "$RESET"
    printf '%sRX direction: peer -> SC3; TX direction: SC3 -> peer.%s\n' "$DIM" "$RESET"
}
ui_rule()
{
    printf '%s+------------------------------------------------------------------------------+%s\n' "$DIM" "$RESET"
}
ui_section()
{
    ui_rule
    printf '%s  %s%s\n' "$BOLD$CYAN" "$1" "$RESET"
}
clear_screen()
{
    if [ -t 1 ] && [ "${RF_LAB_NO_CLEAR:-0}" != 1 ]; then printf '%s[H%s[J' "$ESC" "$ESC"; fi
}
show_config()
{
    _cap=$(ini_get gTxPowerCap)
    printf '  Saved INI   gTxPowerCap: %-17s SAR/thermal 2G/5G: %s/%s\n' "${_cap:-default (unset)}" "$(ini_get TxPower2g)" "$(ini_get TxPower5g)"
    printf '  Board data  %s (calibration, read-only)\n' "${BDF:---}"
    printf '  Saved TPC   AP requests: %-18s FlexConnect factor: %s\n' "$(setting_value gAllowTPCfromAP "$INI")" "$(setting_value gFlexConnectPowerFactor "$INI")"
    printf '%s  Saved configuration is NOT live output power; 128 is a default sentinel.%s\n' "$DIM" "$RESET"
    if [ -r "$STATE/pending-boot-id" ]; then
        _boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
        if [ "$(cat "$STATE/pending-boot-id")" = "$_boot" ]; then
            printf '%s  INI edited in this boot: not activated; normal reboot required.%s\n' "$YELLOW" "$RESET"
        else
            printf '  A later boot was observed; verify runtime before interpreting the cap.\n'
        fi
    fi
}
draw_body()
{
    header
    ui_section 'LINK / RECEIVE CHAINS'
    if [ "$CONNECTED" = 1 ]; then _link_state='ASSOCIATED'; _link_colour=$GREEN
    else _link_state='NOT ASSOCIATED'; _link_colour=$YELLOW; fi
    printf '  %s%-16s%s Sample: %-6s Interface: %s\n' "$_link_colour" "$_link_state" "$RESET" "$SAMPLE" "$IFACE"
    printf '  state: %s | peer: %s | frequency: %s MHz\n' "$CONNECTED" "${PEER:---}" "${FREQUENCY:---}"
    printf '  SSID: %.32s\n' "${SSID:---}"
    printf '  A0   '; signal_text "$A0"; printf '\n'
    printf '  A1   '; signal_text "$A1"; printf '\n'
    printf '  AVG  '; signal_text "$CHAIN_MEAN"; printf ' (current chains)\n'
    printf '  Driver RSSI: %s dBm | noise: %s dBm | SNR: %s dB\n' "${SIGNAL:---}" "${NOISE:---}" "${SNR:---}"
    ui_section 'LINK RATES / TRAFFIC / ERRORS'
    printf '  PHY rate TX/RX: %s/%s Mbps (not throughput)\n' "${TX_RATE:---}" "${RX_RATE:---}"
    printf '  Actual interface traffic TX/RX: %s/%s Mbps over %s s\n' "$TX_MBPS" "$RX_MBPS" "$ELAPSED"
    printf '  Retry/fail deltas (driver): %s/%s | TX/RX errors: %s/%s\n' "$D_RETRIES" "$D_FAILED" "$D_TX_ERRORS" "$D_RX_ERRORS"
    printf '%s  Missing metrics stay --; zero counters do not prove zero over-air retries.%s\n' "$DIM" "$RESET"
    ui_section 'SC3 TRANSMIT / SAVED CONFIGURATION'
    printf '  SC3 TX-power readback: %s dBm (driver statistic, not measured EIRP)\n' "${TXPOWER:---}"
    show_config
    printf '  CSV: %s\n' "${LOGFILE:---}"
    ui_rule
    printf '  %sq%s menu/exit   %sr%s refresh metadata   Ctrl+C exit\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
}
draw()
{
    if [ -t 1 ] && [ "${RF_LAB_NO_CLEAR:-0}" != 1 ]; then
        # Repaint without blanking the terminal between samples. Erase each
        # line's stale suffix and any old rows left by a taller previous frame.
        _frame=$(draw_body)
        printf '%s[H' "$ESC"
        printf '%s\n' "$_frame" | while IFS= read -r _line; do printf '%s%s[K\n' "$_line" "$ESC"; done
        printf '%s[J' "$ESC"
    else draw_body; fi
}
csv_field() { printf '"'; printf '%s' "$1" | tr '\r\n' '  ' | sed 's/"/""/g'; printf '"'; }
csv_ssid()
{
    # SSID is untrusted text. Quoting alone does not prevent spreadsheet
    # formula evaluation; only this text column receives an apostrophe.
    case "$SSID" in [=+@-]*) printf "'%s" "$SSID";; *) printf '%s' "$SSID";; esac
}
append_log()
{
    _first=1
    for _v in "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SAMPLE" "$CONNECTED" "$PEER" "$(csv_ssid)" "$FREQUENCY" "$A0" "$A1" "$CHAIN_MEAN" "$SIGNAL" "$NOISE" "$SNR" "$TX_RATE" "$RX_RATE" "$TX_MBPS" "$RX_MBPS" "$ELAPSED" "$RX_BYTES" "$TX_BYTES" "$RETRIES" "$FAILED" "$D_RETRIES" "$D_FAILED" "$D_TX_ERRORS" "$D_RX_ERRORS" "$TXPOWER" "$BDF" "$(ini_get gTxPowerCap)" "$(ini_get TxPower2g)" "$(ini_get TxPower5g)" "$LABEL" "$(ini_get gAllowTPCfromAP)" "$(ini_get gFlexConnectPowerFactor)"; do
        [ "$_first" = 1 ] || printf ','; _first=0; csv_field "$_v"
    done
    printf '\n'
}
monitor()
{
    LOGFILE=; LABEL=${1:-}
    if [ -n "$LABEL" ]; then
        case "$LABEL" in *[!A-Za-z0-9_.-]*) die 'Label must use letters, digits, dot, dash or underscore'; return 1;; esac
        umask 077; mkdir -p "$LOG_DIR" || return 1
        LOGFILE=$LOG_DIR/sc3-$(date '+%Y%m%d-%H%M%S')-$$-$LABEL.csv
        (set -C; printf '%s\n' 'timestamp,sample,connected,peer_mac,ssid,frequency_mhz,a0_dbm,a1_dbm,chain_mean_dbm,driver_rssi_dbm,noise_dbm,snr_db,tx_phy_mbps,rx_phy_mbps,tx_mbps,rx_mbps,elapsed_s,rx_bytes,tx_bytes,retries_total,failed_total,retries_delta,failed_delta,tx_errors_delta,rx_errors_delta,sc3_txpower_driver_dbm,bdf,gTxPowerCap,TxPower2g,TxPower5g,label,gAllowTPCfromAP,gFlexConnectPowerFactor' > "$LOGFILE") || return 1
    fi
    SAMPLE=0; PREV_TIME= PREV_RX= PREV_TX= PREV_PEER= PREV_RETRIES= PREV_FAILED= PREV_RX_ERRORS= PREV_TX_ERRORS=
    BDF=$(query bdf 2>/dev/null)
    if [ -t 1 ]; then HIDDEN=1; printf '%s[?25l' "$ESC"; fi
    while :; do
        load_sample; SAMPLE=$((SAMPLE+1)); draw
        [ -z "$LOGFILE" ] || append_log >> "$LOGFILE"
        [ "$COUNT" = 0 ] || [ "$SAMPLE" -lt "$COUNT" ] || break
        _key=
        if [ -t 0 ]; then IFS= read -r -s -n 1 -t "$INTERVAL" _key; else sleep "$INTERVAL"; fi
        case "$_key" in q|Q) break;; r|R) BDF=$(query bdf 2>/dev/null);; esac
    done
    [ "$HIDDEN" = 0 ] || printf '%s[?25h' "$ESC"; HIDDEN=0
}
snapshot()
{
    SAMPLE=1; BDF=$(query bdf 2>/dev/null); load_sample; draw
    printf '\nDriver/firmware version:\n'; query version 2>&1
    printf '\nRegulatory view (not an RF measurement):\n'; query regulatory 2>&1
    printf '\nInterface/PHY capabilities:\n'; query info 2>&1; query phy 2>&1
    printf '\nNetlink link:\n%s\n\nNetlink station:\n%s\n' "$LINK_RAW" "$STATION_RAW"
    printf '\nVendor chain reply:\n%s\n' "$CHAIN"
    printf '\nINI digest: %s\n' "$(digest "$INI")"
}
export_snapshot()
{
    umask 077; mkdir -p "$LOG_DIR" || return 1
    _export=$LOG_DIR/sc3-snapshot-$(date '+%Y%m%d-%H%M%S')-$$.txt
    (set -C; NO_COLOR=1; RESET=; BOLD=; DIM=; BLUE=; CYAN=; RED=; YELLOW=; GREEN=; RF_LAB_NO_CLEAR=1; snapshot > "$_export") || return 1
    printf 'Saved %s\n' "$_export"
}

clear_stage()
{
    if [ -n "$STAGE_DIR" ]; then
        rm -f "$STAGE_DIR/config.ini" "$STAGE_DIR/base.ini" "$STAGE_DIR/next.ini" "$STAGE_DIR/base.other" "$STAGE_DIR/stage.other"
        rmdir "$STAGE_DIR" 2>/dev/null
        STAGE_DIR=; STAGE=
    fi
}
new_stage()
{
    [ -f "$INI" ] && [ -r "$INI" ] && [ ! -L "$INI" ] || { die 'Config must be a regular non-symlink file'; return 1; }
    clear_stage
    STAGE_DIR=$(mktemp -d /tmp/sc3-rf-stage.XXXXXX) || return 1
    STAGE=$STAGE_DIR/config.ini
    cp "$INI" "$STAGE" && cp "$INI" "$STAGE_DIR/base.ini" || return 1
    BASE_DIGEST=$(digest "$INI")
}
allowed_key() { case "$1" in gTxPowerCap|TxPower2g|TxPower5g|gAllowTPCfromAP|gFlexConnectPowerFactor) return 0;; *) return 1;; esac; }
setting_limits()
{
    case "$1" in
        gTxPowerCap|TxPower2g|TxPower5g) printf '1 30';;
        gAllowTPCfromAP) printf '0 1';;
        gFlexConnectPowerFactor) printf '0 9';;
        *) return 1;;
    esac
}
setting_default()
{
    case "$1" in
        gTxPowerCap) printf 128;; TxPower2g|TxPower5g) printf 30;;
        gAllowTPCfromAP) printf 1;; gFlexConnectPowerFactor) printf 0;;
        *) return 1;;
    esac
}
normalize_setting_value()
{
    allowed_key "$1" || { die 'Setting is not allowlisted'; return 1; }
    case "$2" in
        unset|default|d) printf unset; return 0;;
        on|ON) [ "$1" = gAllowTPCfromAP ] && { printf 1; return 0; };;
        off|OFF) [ "$1" = gAllowTPCfromAP ] && { printf 0; return 0; };;
    esac
    unsigned "$2" || return 1
    _limits=$(setting_limits "$1") || return 1
    set -- "$2" $_limits
    # Validate before shell arithmetic; long/malformed input cannot overflow it.
    printf '%s\n' "$1" | awk -v lo="$2" -v hi="$3" '
      /^[0-9]+$/ && length($0)<=32 && $0+0>=lo && $0+0<=hi {printf "%d",$0+0;ok=1}
      END {exit !ok}'
}
stage_set()
{
    _stage_value=$(normalize_setting_value "$1" "$2") || { die 'Invalid setting/value; power 1..30, AP TPC 0/1, FlexConnect 0..9, or unset'; return 1; }
    awk -v key="$1" -v value="$_stage_value" '
      function active(line,k) {if(line~/^[ \t]*#/)return 0;p=index(line,"=");k=substr(line,1,p-1);gsub(/[ \t]/,"",k);return p&&k==key}
      ended && $0!~/^[ \t]*(#|END[ \t\r]*$|$)/ {bad=1}
      active($0) {if(++seen>1)bad=1;if(value!="unset")print key"="value;next}
      /^[ \t]*END[ \t\r]*$/ {if(!seen&&value!="unset"){print key"="value;seen=1}endcount++;ended=1}
      {print}
      END {if(bad||endcount!=1||(value!="unset"&&seen!=1))exit 1}' "$STAGE" > "$STAGE_DIR/next.ini" || { die 'Invalid/duplicate INI key or END marker'; return 1; }
    mv "$STAGE_DIR/next.ini" "$STAGE"
}
strip_allowed()
{
    awk '
      {line=$0;p=index(line,"=");k=substr(line,1,p-1);gsub(/[ \t]/,"",k)
       if(line!~/^[ \t]*#/&&p&&k~/^(gTxPowerCap|TxPower2g|TxPower5g|gAllowTPCfromAP|gFlexConnectPowerFactor)$/)next;print}' "$1"
}
validate_stage()
{
    [ -s "$STAGE" ] || return 1
    strip_allowed "$STAGE_DIR/base.ini" > "$STAGE_DIR/base.other"
    strip_allowed "$STAGE" > "$STAGE_DIR/stage.other"
    cmp -s "$STAGE_DIR/base.other" "$STAGE_DIR/stage.other" || { die 'Non-allowlisted settings changed'; return 1; }
    for _k in gTxPowerCap TxPower2g TxPower5g gAllowTPCfromAP gFlexConnectPowerFactor; do
        _value=$(ini_get "$_k" "$STAGE")
        # Original baseline may omit gTxPowerCap or contain its documented
        # sentinel. Only explicit lab edits introduce ordinary 1..30 limits.
        if [ -n "$_value" ] && ! { unsigned "$_value" && normalize_setting_value "$_k" "$_value" >/dev/null; }; then
            [ "$_value" = "$(ini_get "$_k" "$STAGE_DIR/base.ini")" ] || return 1
        fi
    done
    awk '
      /^[ \t]*END[ \t\r]*$/ {n++;ended=1;next}
      /^[ \t]*#/ {next}
      ended && $0!~/^[ \t\r]*$/ {bad=1}
      {p=index($0,"=");k=substr($0,1,p-1);gsub(/[ \t]/,"",k)
       if(p&&k~/^(gTxPowerCap|TxPower2g|TxPower5g|gAllowTPCfromAP|gFlexConnectPowerFactor)$/){
         if(++count[k]>1)bad=1;v=substr($0,p+1);sub(/[ \t]*#.*/,"",v);gsub(/[ \t\r]/,"",v);if(v=="")bad=1}}
      END {exit n!=1||bad}' "$STAGE"
}
stage_profile()
{
    case "$1" in
        stock|original)
            [ -r "$STATE/original.ini" ] && [ ! -L "$STATE/original.ini" ] || { die 'No preserved original exists yet; no guessed stock file will be generated'; return 1; }
            cp "$STATE/original.ini" "$STAGE";;
        cap10) stage_set gTxPowerCap 10;;
        cap15) stage_set gTxPowerCap 15;;
        cap20) stage_set gTxPowerCap 20;;
        *) die 'SC3 profiles: cap10, cap15, cap20, original. Broadcom presets are incompatible.'; return 1;;
    esac
}
apply_stage_inner()
{
    validate_stage || return 1
    [ "$BASE_DIGEST" = "$(digest "$INI")" ] || { die 'Active INI changed since staging; start again'; return 1; }
    if cmp -s "$INI" "$STAGE"; then printf 'Nothing to apply.\n'; return 0; fi
    [ "$TEST_MODE" = 1 ] || {
        [ "$INI" = /lib/firmware/wlan/qcom_cfg.ini ] && [ "$(id -u)" = 0 ] || { die 'Real writes require root and the exact SC3 config path'; return 1; }
    }
    diff -u "$INI" "$STAGE" 2>/dev/null
    printf 'Only INI limits will change; BDF/OTP/factory stay untouched. No radio reload or reboot is performed.\n'
    if [ "${CONFIRM:-}" != APPLY ]; then
        printf 'Type APPLY to save with a recovery backup: '; IFS= read -r CONFIRM
    fi
    [ "$CONFIRM" = APPLY ] || { printf 'Cancelled.\n'; return 1; }
    [ ! -L "$STATE" ] && [ ! -L "$BACKUP_DIR" ] && [ ! -L "$STATE/original.ini" ] || { die 'Refusing symlink state/backup/original'; return 1; }
    umask 077; mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$STATE" "$BACKUP_DIR" || return 1
    mkdir "$STATE/apply.lock" 2>/dev/null || { die 'Another apply is active; no file changed'; return 1; }; LOCK_OWNED=1
    # Recheck after the potentially long confirmation prompt, under our lock.
    [ ! -L "$INI" ] && [ "$BASE_DIGEST" = "$(digest "$INI")" ] || { die 'Active INI changed during confirmation; no setting saved'; return 1; }
    _backup=$BACKUP_DIR/sc3-$(date '+%Y%m%d-%H%M%S')-$$-$BASE_DIGEST.ini
    [ ! -e "$_backup" ] && cp -p "$INI" "$_backup" && cmp -s "$INI" "$_backup" || return 1
    if [ ! -e "$STATE/original.ini" ]; then cp -p "$INI" "$STATE/original.ini" || return 1; fi
    if ! root_rw; then mount -o remount,rw / || return 1; ROOT_REMOUNTED=1; fi
    TARGET_TMP=$(dirname "$INI")/.sc3-rf-lab-$$.ini
    [ ! -e "$TARGET_TMP" ] && [ ! -L "$TARGET_TMP" ] || { die 'Temporary target already exists'; TARGET_TMP=; return 1; }
    cp "$STAGE" "$TARGET_TMP" && chmod 644 "$TARGET_TMP" || return 1
    [ "$TEST_MODE" = 1 ] || chown 0:0 "$TARGET_TMP" || return 1
    cmp -s "$STAGE" "$TARGET_TMP" && mv "$TARGET_TMP" "$INI" || return 1; TARGET_TMP=
    sync
    cmp -s "$STAGE" "$INI" || { die "Readback failed; recover using $_backup"; return 1; }
    restore_mount || return 1
    if [ "$TEST_MODE" = 1 ]; then printf 'fixture\n' > "$STATE/pending-boot-id"; else cat /proc/sys/kernel/random/boot_id > "$STATE/pending-boot-id"; fi
    rmdir "$STATE/apply.lock"; LOCK_OWNED=0
    printf 'Saved. Backup: %s\nA normal reboot is required; no activation or RF improvement is claimed yet.\n' "$_backup"
}
apply_stage()
{
    apply_stage_inner
    _apply_result=$?
    # Failure must not leave an interactive session with / writable or a
    # half-created destination/lock. Backups remain available for recovery.
    if [ -n "$TARGET_TMP" ]; then rm -f "$TARGET_TMP" || _apply_result=1; TARGET_TMP=; fi
    restore_mount || _apply_result=1
    if [ "$LOCK_OWNED" = 1 ]; then
        rmdir "$STATE/apply.lock" || _apply_result=1
        LOCK_OWNED=0
    fi
    return "$_apply_result"
}
pause_screen() { printf 'Press Enter...'; IFS= read -r _answer; }
setting_key()
{
    case "$1" in
        1) printf gTxPowerCap;;
        2) printf TxPower2g;;
        3) printf TxPower5g;;
        4) printf gAllowTPCfromAP;;
        5) printf gFlexConnectPowerFactor;;
        *) return 1;;
    esac
}
setting_value()
{
    CONFIG_DISPLAY_VALUE=$(ini_get "$1" "$2")
    if [ "$1" = gAllowTPCfromAP ]; then
        case "$CONFIG_DISPLAY_VALUE" in
            '') printf 'ON (default 1)';; 1) printf 'ON (1)';; 0) printf 'OFF (0)';;
            *) printf 'invalid saved value';;
        esac
        return
    fi
    printf '%s' "${CONFIG_DISPLAY_VALUE:-default (unset)}"
}
config_screen()
{
    clear_screen
    header
    ui_section 'RADIO SETTINGS / STAGED EDITOR'
    printf 'File: %s\nSaved SHA-1: %s\n\n' "$INI" "$(digest "$INI")"
    printf '  #  %-24s  %-18s  %-18s\n' 'Setting' 'Saved INI' 'Pending'
    printf '     ----------------------------------------------------------\n'
    for CONFIG_NUMBER in 1 2 3 4 5; do
        CONFIG_KEY=$(setting_key "$CONFIG_NUMBER")
        CONFIG_SAVED=$(setting_value "$CONFIG_KEY" "$INI")
        CONFIG_PENDING=$(setting_value "$CONFIG_KEY" "$STAGE")
        CONFIG_MARK=' '
        [ "$CONFIG_SAVED" = "$CONFIG_PENDING" ] || CONFIG_MARK='*'
        printf '  %s  %-24s  %-18s  %-18s %s\n' "$CONFIG_NUMBER" "$CONFIG_KEY" "$CONFIG_SAVED" "$CONFIG_PENDING" "$CONFIG_MARK"
    done
    printf '\n1: host power-cap input; 2/3: SAR/thermal inputs for 2.4/5 GHz.\n'
    printf '4: accept AP TPC (toggle); 5: FlexConnect factor (0..9, effect unverified).\n'
    printf 'Unset uses compiled defaults: cap=128 sentinel, SAR=30/30, TPC=1, Flex=0.\n'
    printf 'These defaults are NOT necessarily the preserved original or live values.\n'
    printf 'Saved INI is not live RF output. * = unsaved edit; default is not 128 dBm.\n'
    if cmp -s "$INI" "$STAGE"; then
        printf '\nNo pending changes.\n'
    else
        printf '\n%sPending changes have NOT been saved or activated.%s\n' "$YELLOW" "$RESET"
    fi
    [ -z "${CONFIG_NOTICE:-}" ] || printf '%s\n' "$CONFIG_NOTICE"
    printf '\nChoose 1-3 (1..30), 4 to toggle AP TPC, or 5 (0..9).\n'
    printf 'Enter unset/default when editing a numeric field to remove its override.\n'
    printf '  p  Presets                    o  Stage preserved original\n'
    printf '  b  Stage recovery backup      r  Discard pending edits\n'
    printf '  d  View exact diff            a  Save edits (requires APPLY)\n'
    printf '  u  Unset/default a chosen setting (not original-file recovery)\n'
    printf '  0  Back without saving\n\nChoice: '
}
edit_setting()
{
    CONFIG_EDIT_KEY=$(setting_key "$1") || return 1
    CONFIG_OLD_VALUE=$(setting_value "$CONFIG_EDIT_KEY" "$STAGE")
    if [ "$CONFIG_EDIT_KEY" = gAllowTPCfromAP ]; then
        CONFIG_TOGGLE=$(ini_get "$CONFIG_EDIT_KEY" "$STAGE")
        [ -n "$CONFIG_TOGGLE" ] || CONFIG_TOGGLE=$(setting_default "$CONFIG_EDIT_KEY")
        case "$CONFIG_TOGGLE" in 0) CONFIG_INPUT=1;; 1) CONFIG_INPUT=0;;
            *) CONFIG_NOTICE='Invalid AP TPC baseline; no toggle staged.'; return 1;; esac
        stage_set "$CONFIG_EDIT_KEY" "$CONFIG_INPUT" || return 1
        CONFIG_NOTICE="$CONFIG_EDIT_KEY toggled to $CONFIG_INPUT, staged only; choose a to save."
        return 0
    fi
    CONFIG_EDIT_LIMITS=$(setting_limits "$CONFIG_EDIT_KEY")
    set -- $CONFIG_EDIT_LIMITS
    CONFIG_RANGE="$1..$2"
    while :; do
        printf '\n%s | saved: %s | pending: %s\n' "$CONFIG_EDIT_KEY" "$(setting_value "$CONFIG_EDIT_KEY" "$INI")" "$CONFIG_OLD_VALUE"
        printf 'New integer for %s (%s, unset/default; Enter cancels): ' "$CONFIG_EDIT_KEY" "$CONFIG_RANGE"
        IFS= read -r CONFIG_INPUT || return 1
        if [ -z "$CONFIG_INPUT" ]; then CONFIG_NOTICE='Edit cancelled; pending values kept.'; return 0; fi
        # Check text and range before integer conversion; very long inputs
        # must not overflow the shell's arithmetic or become INI syntax.
        if ! CONFIG_NORMALIZED=$(normalize_setting_value "$CONFIG_EDIT_KEY" "$CONFIG_INPUT"); then
            printf 'Invalid value. Enter a whole integer in %s or unset/default.\n' "$CONFIG_RANGE"
            continue
        fi
        if stage_set "$CONFIG_EDIT_KEY" "$CONFIG_NORMALIZED"; then
            CONFIG_NOTICE="$CONFIG_EDIT_KEY: $CONFIG_OLD_VALUE -> $CONFIG_NORMALIZED staged only; choose a to save."
            return 0
        fi
        CONFIG_NOTICE='Could not stage the edit; no saved setting changed.'
        return 1
    done
}
choose_preset()
{
    printf '\n1  cap10\n2  cap15\n3  cap20\n0  Cancel\nPreset: '
    IFS= read -r CONFIG_PRESET || return 1
    case "$CONFIG_PRESET" in
        1) CONFIG_PROFILE=cap10;; 2) CONFIG_PROFILE=cap15;; 3) CONFIG_PROFILE=cap20;;
        0|'') CONFIG_NOTICE='Preset cancelled.'; return 0;;
        *) CONFIG_NOTICE='Unknown preset; pending values kept.'; return 1;;
    esac
    if stage_profile "$CONFIG_PROFILE"; then
        CONFIG_NOTICE="$CONFIG_PROFILE staged only; choose a to save."
    else
        CONFIG_NOTICE='Could not stage preset; no saved setting changed.'; return 1
    fi
}
config_menu()
{
    new_stage || return 1
    CONFIG_NOTICE=
    while :; do
        config_screen
        IFS= read -r _choice || return
        case "$_choice" in
            1|2|3|4|5) edit_setting "$_choice";;
            p|P) choose_preset;;
            o|O) if stage_profile original; then CONFIG_NOTICE='Original staged only; choose a to save.'; else CONFIG_NOTICE='No preserved original available; pending values kept.'; fi;;
            b|B)
                printf 'Backups in %s:\n' "$BACKUP_DIR"; ls -1 "$BACKUP_DIR" 2>/dev/null
                printf 'Exact backup filename (Enter cancels): '; IFS= read -r _file || return
                case "$_file" in
                    '') CONFIG_NOTICE='Backup selection cancelled.';;
                    *[!A-Za-z0-9_.-]*) CONFIG_NOTICE='Invalid backup filename.';;
                    *) if [ -f "$BACKUP_DIR/$_file" ] && [ ! -L "$BACKUP_DIR/$_file" ]; then
                           cp "$STAGE" "$STAGE_DIR/next.ini" || return 1
                           if cp "$BACKUP_DIR/$_file" "$STAGE" && validate_stage; then
                               CONFIG_NOTICE='Backup staged only; choose a to save.'
                           else
                               cp "$STAGE_DIR/next.ini" "$STAGE" || return 1
                               CONFIG_NOTICE='Backup rejected; previous pending values kept.'
                           fi
                       else CONFIG_NOTICE='Backup not found; pending values kept.'; fi;;
                esac;;
            r|R) cp "$STAGE_DIR/base.ini" "$STAGE" || return 1; CONFIG_NOTICE='Pending edits discarded; saved configuration unchanged.';;
            d|D) printf '\nSaved INI -> pending diff:\n'; diff -u "$INI" "$STAGE" 2>/dev/null; pause_screen;;
            u|U)
                printf 'Setting number to unset (1-5; Enter cancels): '
                IFS= read -r CONFIG_UNSET_NUMBER || return
                if CONFIG_UNSET_KEY=$(setting_key "$CONFIG_UNSET_NUMBER"); then
                    if stage_set "$CONFIG_UNSET_KEY" unset; then
                        CONFIG_NOTICE="$CONFIG_UNSET_KEY unset staged only; choose a to save."
                    else CONFIG_NOTICE='Could not stage unset; saved configuration unchanged.'; fi
                else CONFIG_NOTICE='Unset cancelled or invalid setting number.'; fi;;
            a|A)
                CONFIRM=
                if apply_stage; then
                    new_stage || return 1
                    CONFIG_NOTICE='No pending changes. Saved INI does not imply live activation.'
                else CONFIG_NOTICE='Not saved; pending edits kept.'; fi
                pause_screen;;
            0|q|Q) clear_stage; return 0;;
            *) CONFIG_NOTICE='Choose a setting (1-5), p/o/b/r/d/a/u action, or 0 to return.';;
        esac
    done
}
parameter_help()
{
    printf '%s\n' \
      'QCA6174 controls are not Broadcom EPA/PD/MAXP fields.' \
      'gTxPowerCap: INI host power-cap input. Stock leaves it commented; compiled default 128 is a sentinel, NOT 128 dBm.' \
      'TxPower2g / TxPower5g: SAR/thermal per-band inputs, not measured output power.' \
      'gAllowTPCfromAP: accept AP transmit-power-control requests; compiled default is 1.' \
      'gFlexConnectPowerFactor: integer 0..9, compiled default 0; firmware meaning/units and SC3 RF effect remain unverified.' \
      'unset removes an explicit entry: defaults are cap 128 sentinel, SAR 30/30, AP TPC 1, Flex 0.' \
      'Unset/default is different from restoring the first preserved original file.' \
      'iwpriv setMaxTxPower / setTxMaxPower2G / setTxMaxPower5G: separate runtime dBm request paths.' \
      'Runtime power setters are documented but not automatically exercised by this tool.' \
      'Board data, regulatory limits, per-rate backoffs and radio firmware still constrain actual RF output.' \
      'cap10/cap15/cap20 stage only gTxPowerCap; activation requires a normal reboot.' \
      'Original restores the first file preserved by this tool, not a guessed regional profile.' \
      'BDF files, country, PA calibration, chain wiring and OTP are deliberately not edited.' \
      'Missing noise/RX-rate/retry-exhaustion metrics are unavailable, not zero.' \
      'SC3 chain RSSI uses Parrot vendor query 138 and raw-minus-96 conversion; driver RSSI can differ.'
}
settings_json()
{
    # JSON mode must not append a terminal-colour reset from the exit trap.
    RESET=; BOLD=; DIM=; BLUE=; CYAN=; RED=; YELLOW=; GREEN=
    printf '{"schema":"sc3-rf-settings-v1","version":"%s","ini_sha1":"%s","settings":[' "$VERSION" "$(digest "$INI")"
    _json_separator=
    for _json_key in gTxPowerCap TxPower2g TxPower5g gAllowTPCfromAP gFlexConnectPowerFactor; do
        _json_raw=$(ini_get "$_json_key")
        _json_limits=$(setting_limits "$_json_key"); set -- $_json_limits
        _json_kind=integer; [ "$_json_key" != gAllowTPCfromAP ] || _json_kind=toggle
        printf '%s{"key":"%s","kind":"%s","min":%s,"max":%s,"driver_default":%s,"saved":' "$_json_separator" "$_json_key" "$_json_kind" "$1" "$2" "$(setting_default "$_json_key")"
        _json_source=explicit
        if [ -z "$_json_raw" ]; then printf null; _json_source=unset
        elif printf '%s\n' "$_json_raw" | awk '/^[0-9]+$/ && length($0)<=32 {ok=1} END{exit !ok}'; then
            # Keep exact numeric text (including leading zeroes) as a JSON string.
            printf '"%s"' "$_json_raw"
        else printf null; _json_source=invalid; fi
        _json_valid=false
        [ -z "$_json_raw" ] && _json_valid=true
        if [ -n "$_json_raw" ] && unsigned "$_json_raw" && normalize_setting_value "$_json_key" "$_json_raw" >/dev/null; then _json_valid=true; fi
        printf ',"source":"%s","within_editor_range":%s,"unset_allowed":true}' "$_json_source" "$_json_valid"
        _json_separator=,
    done
    printf '],"saved_is_live_output":false,"radio_reload_performed":false}\n'
}
batch_changes()
{
    BATCH_OPERATION=$1; shift
    BATCH_EXPECT=; CONFIRM=; BATCH_KEYS=; BATCH_COUNT=0
    if [ "${1:-}" = --expect ]; then
        [ "$#" -ge 2 ] || return 2
        BATCH_EXPECT=$2; shift 2
        [ "${#BATCH_EXPECT}" = 40 ] || { die 'Expected SHA-1 must have 40 hex characters'; return 2; }
        case "$BATCH_EXPECT" in *[!0-9a-f]*) die 'Invalid expected SHA-1'; return 2;; esac
    fi
    if [ "$BATCH_OPERATION" = apply-changes ] && [ -z "$BATCH_EXPECT" ]; then
        die 'apply-changes requires --expect SHA1 from settings/preview'; return 2
    fi
    new_stage || return 1
    [ -z "$BATCH_EXPECT" ] || [ "$BATCH_EXPECT" = "$BASE_DIGEST" ] || { die 'Active INI changed since app preview'; return 1; }
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --confirm ]; then
            [ "$#" = 2 ] && [ -z "$CONFIRM" ] || { die 'Confirmation must be the final pair'; return 2; }
            CONFIRM=$2; shift 2; break
        fi
        [ "$#" -ge 2 ] || { die 'Expected KEY VALUE pairs'; return 2; }
        case " $BATCH_KEYS " in *" $1 "*) die 'Repeated key in batch'; return 2;; esac
        stage_set "$1" "$2" || return 1
        BATCH_KEYS="$BATCH_KEYS $1"; BATCH_COUNT=$((BATCH_COUNT+1)); shift 2
    done
    [ "$BATCH_COUNT" -gt 0 ] || { die 'No setting pairs supplied'; return 2; }
    validate_stage || return 1
    printf 'Base INI SHA-1: %s\n' "$BASE_DIGEST"
    if [ "$BATCH_OPERATION" = preview-changes ]; then
        diff -u "$INI" "$STAGE" 2>/dev/null
        BATCH_DIFF_STATUS=$?
        [ "$BATCH_DIFF_STATUS" -le 1 ] || return "$BATCH_DIFF_STATUS"
        printf 'Preview only; no INI setting saved, radio reload or reboot performed.\n'
    else
        [ "$CONFIRM" = APPLY ] || { die 'apply-changes requires explicit --confirm APPLY'; return 2; }
        apply_stage
    fi
}
usage()
{
    printf '%s\n' "SC3 RF Lab $VERSION" \
      "Usage: $0 [menu|monitor|log LABEL|snapshot|export|config|apply-profile PROFILE [--confirm APPLY]|help|--self-test]" \
      "       $0 settings" \
      "       $0 preview-changes [--expect SHA1] KEY VALUE [KEY VALUE ...]" \
      "       $0 apply-changes --expect SHA1 KEY VALUE [KEY VALUE ...] --confirm APPLY" \
      'RF_LAB_COUNT=N bounds monitor/log; RF_LAB_INTERVAL=N sets seconds (default 1).' \
      'Default read-only. Config/apply-profile need explicit APPLY and create a backup.'
}
self_test()
{
    _parsed=$(printf 'Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: test\n\tfreq: 2447\n\tsignal: -40 dBm\n\ttx bitrate: 65.0 MBit/s\n' | parse_link)
    [ "$(value_of "$_parsed" connected)" = 1 ] && [ "$(value_of "$_parsed" peer)" = aa:bb:cc:dd:ee:ff ] || return 1
    [ "$(printf 'Tx-Power=14 dBm' | parse_txpower)" = 14 ] || return 1
    [ "$(delta 3 8)" = NA ] && [ "$(delta 10 7)" = 3 ] || return 1
    ! allowed_key epagain2g && ! power_value 128 && ! power_value 0 || return 1
    [ "$(normalize_setting_value gAllowTPCfromAP off)" = 0 ] || return 1
    [ "$(normalize_setting_value gFlexConnectPowerFactor 0)" = 0 ] || return 1
    ! normalize_setting_value gFlexConnectPowerFactor 10 >/dev/null || return 1
    printf 'SC3 RF Lab self-test passed\n'
}

case "${1:-menu}" in --help|-h) usage; exit 0;; --self-test|self-test) self_test; exit $?;; help) parameter_help; exit 0;; esac
unsigned "$INTERVAL" && [ "$INTERVAL" -gt 0 ] && unsigned "$COUNT" || { die 'Invalid interval/count'; exit 2; }
verify_device || exit 1
case "${1:-menu}" in
    snapshot) snapshot;;
    monitor) monitor;;
    log) monitor "${2:-experiment}";;
    export) export_snapshot;;
    config) config_menu;;
    settings) settings_json;;
    preview-changes|apply-changes) BATCH_MODE=$1; shift; batch_changes "$BATCH_MODE" "$@";;
    apply-profile)
        [ "${3:-}" = --confirm ] && CONFIRM=${4:-}
        new_stage && stage_profile "${2:-}" && apply_stage;;
    menu)
        while :; do
            clear_screen
            header
            BDF=$(query bdf 2>/dev/null)
            LINK=$(query link 2>/dev/null | parse_link)
            PEER=$(value_of "$LINK" peer)
            printf '\n  Peer: %s%s%s   Interface: %s\n' "$BLUE" "${PEER:-not associated}" "$RESET" "$IFACE"
            printf '  INI: %s\n' "$INI"
            show_config
            ui_section 'OBSERVE'
            printf '  %s1%s  Live RF dashboard\n' "$CYAN" "$RESET"
            printf '  %s2%s  Live dashboard + CSV experiment log\n' "$CYAN" "$RESET"
            printf '  %s3%s  Comprehensive read-only snapshot\n' "$CYAN" "$RESET"
            printf '  %s4%s  Export snapshot to FTP storage\n' "$CYAN" "$RESET"
            ui_section 'CONFIGURE / DOCUMENTATION'
            printf '  %s5%s  Numbered radio settings / presets / recovery\n' "$CYAN" "$RESET"
            printf '  %s6%s  QCA6174 parameter help\n' "$CYAN" "$RESET"
            printf '  %sq%s  Quit\n' "$CYAN" "$RESET"
            ui_rule
            printf '  Observation is read-only; saving staged settings requires APPLY.\n\nChoice: '
            IFS= read -r _menu || break
            case "$_menu" in
                1) monitor;; 2) printf 'Experiment label: '; IFS= read -r _label; monitor "$_label";;
                3) snapshot; pause_screen;; 4) export_snapshot; pause_screen;;
                5) config_menu;; 6) parameter_help; pause_screen;; q|Q) break;;
            esac
        done;;
    *) usage; exit 2;;
esac
