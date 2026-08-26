#!/bin/sh
# Find the SkyController 2 DHCP address from the Bebop 2 access point.
# Read-only: correlates associated Wi-Fi stations with ARP/dnsmasq state.

MARKER="__PARROTLAB_SC2_IP__="
ARP_FILE="/proc/net/arp"
LEASE_FILE="/var/lib/misc/dhcp_eth0.leases"

valid_ip()
{
    case "$1" in
        192.168.42.*)
            [ "$1" != "192.168.42.1" ] && return 0
            ;;
    esac
    return 1
}

ip_for_mac()
{
    wanted="$1"
    ip=""
    if [ -r "$ARP_FILE" ]; then
        ip="$(awk -v mac="$wanted" '
            NR > 1 && tolower($4) == tolower(mac) { print $1; exit }
        ' "$ARP_FILE" 2>/dev/null)"
    fi
    if ! valid_ip "$ip" && [ -r "$LEASE_FILE" ]; then
        ip="$(awk -v mac="$wanted" '
            tolower($2) == tolower(mac) { print $3; exit }
        ' "$LEASE_FILE" 2>/dev/null)"
    fi
    valid_ip "$ip" && printf '%s\n' "$ip"
}

# Dragon/RF Lab firmware exposes the Broadcom utility under one of these names.
assoc="$(bcmwl assoclist 2>/dev/null || wl assoclist 2>/dev/null || true)"
macs="$(printf '%s\n' "$assoc" | awk '
    {
        for (i = 1; i <= NF; i++) {
            candidate = tolower($i)
            probe = candidate
            if (gsub(/:/, "", probe) == 5 && candidate ~ /^[0-9a-f:]+$/)
                print candidate
        }
    }
')"

# SC2 production units observed in the firmware captures use Parrot's A0:14:3D
# OUI. Prefer that associated station so a phone on the Bebop AP is not chosen.
for mac in $macs; do
    case "$mac" in
        a0:14:3d:*)
            ip="$(ip_for_mac "$mac")"
            if valid_ip "$ip"; then
                echo "${MARKER}${ip}"
                exit 0
            fi
            ;;
    esac
done

# A hostname-bearing dnsmasq lease is a useful fallback on firmware variants.
if [ -r "$LEASE_FILE" ]; then
    ip="$(awk '
        tolower($4) ~ /sky.*controller|controller.*sky/ { print $3; exit }
    ' "$LEASE_FILE" 2>/dev/null)"
    if valid_ip "$ip"; then
        echo "${MARKER}${ip}"
        exit 0
    fi
fi

# Last resort only when the SC2 is the sole station on the Bebop AP. Never pick
# an arbitrary client when a phone or Mac is associated as well.
set -- $macs
if [ "$#" -eq 1 ]; then
    ip="$(ip_for_mac "$1")"
    if valid_ip "$ip"; then
        echo "${MARKER}${ip}"
        exit 0
    fi
fi

echo "${MARKER}NOT_FOUND"
exit 1
