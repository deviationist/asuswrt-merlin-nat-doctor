#!/bin/sh
# tests/invariant.sh — fixtures for nat-doctor's detection logic.
#
# Run after ANY change to active_unit(), active_ifname(), masq_present(),
# vserver_rule_count(), forwards_configured() or check_invariant().
#
# It extracts those functions VERBATIM from scripts/natctl and drives them
# against a stubbed nvram, iptables and netdev namespace. This is the repo's
# only automated regression net, and it exists mainly to pin one rule:
#
#   THE CHECK MUST FOLLOW THE ACTIVE WAN, NEVER A HARDCODED INTERFACE.
#
# If it followed the primary's ethN while the router was failed over to a PPP
# secondary, it would see "no MASQUERADE" and restart the firewall every
# minute for the whole outage. Cases 4-6 exist to make that regression loud.
#
#   sh tests/invariant.sh

SELF_DIR=$(dirname "$0")
# NATCTL_SRC is for the negative-control check documented in AGENTS.md
# (point it at a deliberately-broken copy and confirm these fixtures fail).
SRC="${NATCTL_SRC:-$SELF_DIR/../scripts/natctl}"
[ -f "$SRC" ] || { echo "cannot find $SRC" >&2; exit 1; }

# --- extract the functions under test, verbatim ----------------------------
BLOCK=$(sed -n '/^active_unit() {/,/^# --- rate limiting/p' "$SRC" | sed '$d')
case "$BLOCK" in
	*"check_invariant()"*) ;;
	*) echo "extraction failed — did the function block or its trailing marker move?" >&2; exit 1 ;;
esac

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

eval "$BLOCK"

reset() {
	for k in wan_primary wan0_primary wan1_primary \
	         wan0_proto wan1_proto wan0_ifname wan1_ifname \
	         wan0_pppoe_ifname wan1_pppoe_ifname \
	         wan0_state_t wan1_state_t vts_enable_x vts_rulelist; do
		eval "NV_$k=''"
	done
	IPT_POSTROUTING=""
	IPT_VSERVER=""
}

PASS=0; FAIL=0
expect() {
	_want="$1"; _name="$2"
	# Deliberately NOT a command substitution: REASON must survive into the
	# failure message, and a subshell would swallow it.
	if check_invariant; then
		if [ "$INDETERMINATE" = "1" ]; then _got=UNKNOWN; else _got=OK; fi
	else
		_got=BROKEN
	fi
	if [ "$_got" = "$_want" ]; then
		PASS=$((PASS + 1)); echo "  ok    $_name  [$_got]"
	else
		FAIL=$((FAIL + 1)); echo "  FAIL  $_name  expected $_want, got $_got"
		echo "        reason: $REASON"
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

echo "nat-doctor invariant fixtures"
echo ""

# 1 — healthy primary
reset
NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=1; NV_vts_rulelist="<x"
IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_FULL"
expect OK "healthy primary (dhcp/eth0, masq + forwards present)"

# 2 — THE FAULT: connected, but no masquerade
reset
NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=1; NV_vts_rulelist="<x"
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect BROKEN "the fault: wan connected but MASQUERADE missing"

# 3 — WAN legitimately down: rules absent is CORRECT, must not heal
reset
NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=0
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect UNKNOWN "wan down (state_t=0) — absent rules are correct"

# 4 — LANDMINE: failed over to PPP secondary, masq on ppp0.
#     A check hardcoded to eth0 would call this BROKEN and restart the
#     firewall every minute for the entire outage.
reset
NV_wan_primary=1; NV_wan1_proto=pppoe; NV_wan1_ifname=/dev/ttyUSB0
NV_wan1_pppoe_ifname=ppp0; NV_wan1_state_t=2
NV_vts_enable_x=1; NV_vts_rulelist="<x"
IPT_POSTROUTING="$MASQ_PPP0"; IPT_VSERVER="$VS_FULL"
expect OK "failover to PPP secondary — follows ppp0, not eth0"

# 5 — PPP secondary still coming up: netdev not yet published
reset
NV_wan_primary=1; NV_wan1_proto=pppoe; NV_wan1_ifname=/dev/ttyUSB0
NV_wan1_pppoe_ifname=""; NV_wan1_state_t=2
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect UNKNOWN "PPP netdev not yet published — skip, never heal"

# 6 — a serial device is not a netdev and must never be used as one
reset
NV_wan_primary=1; NV_wan1_proto=dhcp; NV_wan1_ifname=/dev/ttyUSB0
NV_wan1_state_t=2
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect UNKNOWN "/dev/ttyUSB0 rejected as a netdev"

# 7 — masq fine, but every port forward vanished
reset
NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=1; NV_vts_rulelist="<x"
IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_EMPTY"
expect BROKEN "VSERVER emptied while port forwarding is enabled"

# 8 — empty VSERVER is CORRECT when the user configures no forwards
reset
NV_wan_primary=0; NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=0; NV_vts_rulelist=""
IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_EMPTY"
expect OK "no forwards configured — empty VSERVER is correct"

# 9 — unresolvable active unit
reset
NV_wan_primary=""; NV_wan0_primary=0; NV_wan1_primary=0
IPT_POSTROUTING="$NO_MASQ"; IPT_VSERVER="$VS_EMPTY"
expect UNKNOWN "cannot determine active WAN unit — skip"

# 10 — wan_primary unset but wanN_primary flags usable
reset
NV_wan_primary=""; NV_wan0_primary=1
NV_wan0_proto=dhcp; NV_wan0_ifname=eth0; NV_wan0_state_t=2
NV_vts_enable_x=0
IPT_POSTROUTING="$MASQ_ETH0"; IPT_VSERVER="$VS_EMPTY"
expect OK "falls back to wanN_primary when wan_primary is unset"

echo ""
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = "0" ] || exit 1
