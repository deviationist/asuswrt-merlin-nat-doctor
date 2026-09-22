#!/bin/sh
# tests/invariant.sh — fixtures for nat-doctor's detection logic.
#
# Run after ANY change to a should_run_*/is_ok_* function or to run_check().
#
# It extracts those functions VERBATIM from scripts/natctl and drives them
# against a stubbed nvram, iptables, wg, pidof and netdev namespace. This is
# the repo's only automated regression net, and it pins two rules that will
# cause real damage if they ever break:
#
#   1. THE FIREWALL CHECK FOLLOWS THE ACTIVE WAN, NEVER A HARDCODED INTERFACE.
#      Hardcoded to the primary's ethN, it would see "no MASQUERADE" while
#      failed over to a PPP secondary and restart the firewall every minute
#      for the whole outage. Cases 4-6.
#
#   2. A SERVICE THE USER DISABLED IS NEVER "REPAIRED".
#      should_run must come from what nvram DECLARES, not from what is
#      running. Get this wrong and the watchdog fights the owner's own
#      configuration every minute, forever. Cases 12, 16, 18, 19.
#
#   sh tests/invariant.sh

SELF_DIR=$(dirname "$0")
# NATCTL_SRC is for the negative-control check documented in AGENTS.md
# (point it at a deliberately-broken copy and confirm these fixtures fail).
SRC="${NATCTL_SRC:-$SELF_DIR/../scripts/natctl}"
[ -f "$SRC" ] || { echo "cannot find $SRC" >&2; exit 1; }

# --- extract the functions under test, verbatim ----------------------------
BLOCK=$(sed -n '/^active_unit() {/,/^# --- per-check rate limiting/p' "$SRC" | sed '$d')
for needed in active_ifname should_run_firewall is_ok_firewall \
              should_run_wireguard is_ok_wireguard \
              should_run_dnsmasq is_ok_dnsmasq run_check; do
	case "$BLOCK" in
		*"$needed"*) ;;
		*) echo "extraction failed: $needed missing — did the block or its trailing marker move?" >&2; exit 1 ;;
	esac
done

# --- stubs -----------------------------------------------------------------
NETDEV_ROOT=$(mktemp -d 2>/dev/null || echo /tmp/natdoc-test.$$)
mkdir -p "$NETDEV_ROOT"
: > "$NETDEV_ROOT/eth0"
: > "$NETDEV_ROOT/ppp0"
trap 'rm -rf "$NETDEV_ROOT"' EXIT INT TERM

nvram() {
	[ "$1" = "get" ] || return 1
	eval "printf '%s' \"\${NV_$2}\""
}

iptables() {
	case "$4" in
		POSTROUTING) printf '%s\n' "$IPT_POSTROUTING" ;;
		VSERVER)     printf '%s\n' "$IPT_VSERVER" ;;
	esac
}

# `wg show <iface>` succeeds only for interfaces listed in WG_IFACES.
wg() {
	for _i in $WG_IFACES; do [ "$_i" = "$2" ] && return 0; done
	return 1
}

# pidof succeeds only for names listed in PROCS.
pidof() {
	for _p in $PROCS; do [ "$_p" = "$1" ] && { echo 1234; return 0; }; done
	return 1
}

log() { :; }

# have_proc is defined in natctl's helper section, above the extracted block.
# Pull it verbatim rather than reimplementing it — a test that reimplements
# the thing under test proves nothing.
HELPER=$(grep '^have_proc()' "$SRC")
[ -n "$HELPER" ] || { echo "extraction failed: have_proc missing" >&2; exit 1; }
eval "$HELPER"

eval "$BLOCK"

reset() {
	for k in wan_primary wan0_primary wan1_primary \
	         wan0_proto wan1_proto wan0_ifname wan1_ifname \
	         wan0_pppoe_ifname wan1_pppoe_ifname \
	         wan0_state_t wan1_state_t vts_enable_x vts_rulelist \
	         wgs_enable wgs_unit sw_mode enable_samba upnp_enable; do
		eval "NV_$k=''"
	done
	IPT_POSTROUTING=""; IPT_VSERVER=""; WG_IFACES=""; PROCS=""
}

# A healthy firewall baseline, so non-firewall cases don't trip over it.
fw_healthy() {
	NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
	NV_vts_enable_x=0
	IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_EMPTY"
}

PASS=0; FAIL=0
expect() {
	_want="$1"; _check="$2"; _name="$3"
	run_check "$_check"
	if [ "$STATE" = "$_want" ]; then
		PASS=$((PASS + 1)); printf '  ok    %-9s %s  [%s]\n' "$_check" "$_name" "$STATE"
	else
		FAIL=$((FAIL + 1)); printf '  FAIL  %-9s %s  expected %s, got %s\n' "$_check" "$_name" "$_want" "$STATE"
		printf '        why: %s\n' "$WHY"
	fi
}

MASQ_ETH0="-P POSTROUTING ACCEPT
-A POSTROUTING ! -s 198.51.100.7/32 -o eth0 -j MASQUERADE
-A POSTROUTING -s 192.168.1.0/24 -d 192.168.1.0/24 -o br0 -j MASQUERADE"
MASQ_PPP0="-P POSTROUTING ACCEPT
-A POSTROUTING -o ppp0 -j MASQUERADE"
NO_MASQ="-P POSTROUTING ACCEPT
-A POSTROUTING -s 192.168.1.0/24 -d 192.168.1.0/24 -o br0 -j MASQUERADE"
VS_FULL="-N VSERVER
-A VSERVER -p tcp -m tcp --dport 443 -j DNAT --to-destination 192.168.1.10:443"
VS_EMPTY="-N VSERVER"

echo "nat-doctor fixtures"
echo ""
echo "-- firewall --"

# 1
reset; NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=1; NV_vts_rulelist="<x"; IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_FULL"
expect ok firewall "healthy primary"

# 2 — THE FAULT
reset; NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=1; NV_vts_rulelist="<x"; IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect broken firewall "connected but MASQUERADE missing"

# 3
reset; NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=0
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect skip firewall "WAN down — absent rules are correct"

# 4 — LANDMINE
reset; NV_wan_primary=1; NV_wan1_proto=pppoe; NV_wan1_ifname=/dev/ttyUSB0
NV_wan1_pppoe_ifname=ppp0; NV_wan1_state_t=2; NV_vts_enable_x=0
IPT_POSTROUTING="$MASQ_PPP0"; IPT_VSERVER="$VS_EMPTY"
expect ok firewall "failover to PPP — follows ppp0, not eth0"

# 5
reset; NV_wan_primary=1; NV_wan1_proto=pppoe; NV_wan1_ifname=/dev/ttyUSB0
NV_wan1_pppoe_ifname=""; NV_wan1_state_t=2
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect skip firewall "PPP netdev not yet published"

# 6
reset; NV_wan_primary=1; NV_wan1_proto=dhcp; NV_wan1_ifname=/dev/ttyUSB0; NV_wan1_state_t=2
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect skip firewall "/dev/ttyUSB0 rejected as a netdev"

# 7
reset; NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=1; NV_vts_rulelist="<x"; IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_EMPTY"
expect broken firewall "VSERVER emptied while forwarding enabled"

# 8
reset; NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=0; IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_EMPTY"
expect ok firewall "no forwards configured — empty VSERVER correct"

# 9
reset; NV_wan_primary=""; NV_wan0_primary=0; NV_wan1_primary=0
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect skip firewall "cannot determine active WAN unit"

# 10
reset; NV_wan_primary=""; NV_wan0_primary=1
NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2; NV_vts_enable_x=0
IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_EMPTY"
expect ok firewall "falls back to wanN_primary"

echo ""
echo "-- wireguard --"

# 11
reset; fw_healthy; NV_wgs_enable=1; NV_wgs_unit=1; WG_IFACES="wgs1"
expect ok wireguard "enabled and wgs1 up"

# 12 — the 2026-09-22 casualty
reset; fw_healthy; NV_wgs_enable=1; NV_wgs_unit=1; WG_IFACES=""
expect broken wireguard "enabled but interface missing"

# 13 — DO NOT FIGHT THE OWNER'S CONFIG
reset; fw_healthy; NV_wgs_enable=0; NV_wgs_unit=1; WG_IFACES=""
expect skip wireguard "deliberately disabled — absence is correct"

# 14
reset; fw_healthy; NV_wgs_enable=""; WG_IFACES=""
expect skip wireguard "wgs_enable unreadable"

# 15 — unit number is a variable, not a constant
reset; fw_healthy; NV_wgs_enable=1; NV_wgs_unit=2; WG_IFACES="wgs2"
expect ok wireguard "honours wgs_unit=2 (wgs2, not wgs1)"

# 16
reset; fw_healthy; NV_wgs_enable=1; NV_wgs_unit=""; WG_IFACES="wgs1"
expect skip wireguard "wgs_unit unreadable"

echo ""
echo "-- dnsmasq --"

# 17
reset; fw_healthy; NV_sw_mode=1; PROCS="dnsmasq"
expect ok dnsmasq "router mode, dnsmasq running"

# 18
reset; fw_healthy; NV_sw_mode=1; PROCS=""
expect broken dnsmasq "router mode, dnsmasq absent"

# 19 — AP mode does not run dnsmasq
reset; fw_healthy; NV_sw_mode=3; PROCS=""
expect skip dnsmasq "AP mode — dnsmasq not expected"

# 20
reset; fw_healthy; NV_sw_mode=""; PROCS=""
expect skip dnsmasq "sw_mode unreadable"

echo ""
echo "-- opt-in checks --"

# 21
reset; fw_healthy; NV_enable_samba=1; PROCS="smbd"
expect ok samba "samba enabled and running"
# 22
reset; fw_healthy; NV_enable_samba=1; PROCS=""
expect broken samba "samba enabled but smbd absent"
# 23
reset; fw_healthy; NV_enable_samba=0; PROCS=""
expect skip samba "samba disabled — absence is correct"
# 24
reset; fw_healthy; NV_upnp_enable=0; PROCS=""
expect skip upnp "upnp disabled — absence is correct"
# 25
reset; fw_healthy; NV_upnp_enable=1; PROCS=""
expect broken upnp "upnp enabled but miniupnpd absent"

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = "0" ] || exit 1
