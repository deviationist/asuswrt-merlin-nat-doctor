#!/bin/sh
# nat-fault-probe.sh — "do I have this bug?"
#
# Run ON the router (busybox sh). Read-only: it inspects state and logs and
# changes nothing. Safe to run at any time, fault or no fault.
#
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/extras/nat-fault-probe.sh | sh
#
# It answers two separate questions:
#   1. Is the fault happening RIGHT NOW?
#   2. Has it happened BEFORE, in whatever log history survives?
#
# The second matters because the fault is self-concealing: the router looks
# healthy afterwards, and a reboot (or this tool healing it) erases the live
# evidence. The syslog signature is the only trace left.
#
# Output is deliberately copy-pasteable into a bug report.

echo "=== nat-doctor fault probe ==="
echo "date: $(date)"
echo

# --- platform ---------------------------------------------------------------
echo "--- platform ---"
if [ ! -d /jffs ]; then
	echo "no /jffs — this does not look like an Asuswrt-Merlin router."
	echo "The FAULT affects stock AsusWRT too, but this probe needs Merlin's shell."
	exit 1
fi
echo "model    : $(nvram get productid 2>/dev/null)"
echo "firmware : $(nvram get firmver 2>/dev/null).$(nvram get buildno 2>/dev/null)_$(nvram get extendno 2>/dev/null)"
echo "kernel   : $(uname -r 2>/dev/null)"
echo "uptime   : $(uptime 2>/dev/null | sed 's/^ *//')"
echo

# --- live state -------------------------------------------------------------
echo "--- live state ---"
UNIT=$(nvram get wan_primary 2>/dev/null)
case "$UNIT" in 0|1) ;; *) UNIT=0 ;; esac
PROTO=$(nvram get wan${UNIT}_proto 2>/dev/null)
case "$PROTO" in
	pppoe|pptp|l2tp) WANIF=$(nvram get wan${UNIT}_pppoe_ifname 2>/dev/null) ;;
	*)               WANIF=$(nvram get wan${UNIT}_ifname 2>/dev/null) ;;
esac
STATE=$(nvram get wan${UNIT}_state_t 2>/dev/null)
echo "active WAN unit : $UNIT ($PROTO)"
echo "netdev          : ${WANIF:-<undetermined>}"
echo "state_t         : $STATE   (2 = connected)"

MASQ=no
if [ -n "$WANIF" ] && iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- "-o $WANIF -j MASQUERADE"; then
	MASQ=yes
fi
VS=$(iptables -t nat -S VSERVER 2>/dev/null | grep -c '^-A')
FWD_ON=$(nvram get vts_enable_x 2>/dev/null)
echo "WAN MASQUERADE  : $MASQ"
echo "VSERVER rules   : $VS   (port forwarding enabled: ${FWD_ON:-?})"
echo
echo "POSTROUTING:"
iptables -t nat -S POSTROUTING 2>/dev/null | sed 's/^/  /'
echo

# --- configuration context --------------------------------------------------
echo "--- why short flaps are the dangerous ones ---"
WDI=$(nvram get wandog_interval 2>/dev/null)
WDM=$(nvram get wandog_maxfail 2>/dev/null)
echo "wandog_interval : ${WDI:-?}"
echo "wandog_maxfail  : ${WDM:-?}"
if [ -n "$WDI" ] && [ -n "$WDM" ]; then
	echo "=> failover threshold ~$((WDI * WDM))s."
	echo "   A WAN outage SHORTER than that never reaches wanduck and is handled"
	echo "   by udhcpc's lightweight path — the one that wedges. Longer outages"
	echo "   get a full restart_wan_line and recover cleanly."
fi
echo "dual WAN        : $(nvram get wans_dualwan 2>/dev/null) / mode $(nvram get wans_mode 2>/dev/null)"
echo

# --- historical evidence ----------------------------------------------------
echo "--- historical evidence (syslog) ---"
# On Merlin /tmp/syslog.log is usually a SYMLINK to /jffs/syslog.log. Searching
# both counts every event twice — which looked like two incidents when there
# had been one. Prefer the /jffs pair; fall back to /tmp only if absent.
LOGS=""
if [ -f /jffs/syslog.log ]; then
	for f in /jffs/syslog.log-1 /jffs/syslog.log; do [ -f "$f" ] && LOGS="$LOGS $f"; done
else
	for f in /tmp/syslog.log-1 /tmp/syslog.log; do [ -f "$f" ] && LOGS="$LOGS $f"; done
fi
if [ -z "$LOGS" ]; then
	echo "no syslog files found — cannot check history."
else
	echo "searched:$LOGS"
	FIRST=$(head -1 $(echo $LOGS | cut -d' ' -f1) 2>/dev/null | cut -c1-15)
	LAST=$(tail -1 /jffs/syslog.log 2>/dev/null || tail -1 /tmp/syslog.log 2>/dev/null)
	echo "coverage: ${FIRST:-?} -> $(echo "$LAST" | cut -c1-15)"
	echo "  NOTE: rotation is ~1MB. On a busy router that is barely a day, so"
	echo "  'no evidence' here does NOT mean it never happened."
	echo
	STUCK=$(grep -h "abort the stuck service" $LOGS 2>/dev/null | wc -l)
	FLAP=$(grep -h "WAN was restored" $LOGS 2>/dev/null | wc -l)
	PHY=$(grep -h "hnd_get_phy_status" $LOGS 2>/dev/null | wc -l)
	NATS=$(grep -h "nat-start" $LOGS 2>/dev/null | wc -l)
	echo "abort the stuck service : $STUCK   <-- THE signature"
	echo "WAN was restored        : $FLAP"
	echo "hnd_get_phy_status      : $PHY"
	echo "nat-start runs          : $NATS"
	if [ "$STUCK" -gt 0 ] 2>/dev/null; then
		echo
		echo "stuck-service events in detail:"
		grep -h "abort the stuck service" $LOGS 2>/dev/null | sed 's/^/  /' | tail -10
		echo
		echo "surrounding WAN events:"
		grep -hE "link down|WAN was restored|hnd_get_phy_status" $LOGS 2>/dev/null | sed 's/^/  /' | tail -10
		echo
		echo "  NOTE: this firmware logs rc_service/ddns/dhcp lines in UTC and the"
		echo "  rest in local time. A two-hour 'gap' between related lines is that,"
		echo "  not two separate events."
	fi
fi
echo

# --- verdict ----------------------------------------------------------------
echo "--- verdict ---"
LIVE=no
if [ "$STATE" = "2" ] && [ -n "$WANIF" ] && [ "$MASQ" = "no" ]; then LIVE=yes; fi
if [ "$STATE" = "2" ] && [ "$FWD_ON" = "1" ] && [ "$VS" = "0" ]; then LIVE=yes; fi

if [ "$LIVE" = "yes" ]; then
	echo "*** THE FAULT IS ACTIVE RIGHT NOW ***"
	echo
	echo "WAN reports connected (state_t=2) but the NAT rules for it are missing."
	echo "Your LAN clients cannot reach the internet; the router itself can."
	echo
	echo "Fix without rebooting:"
	echo "    service restart_firewall"
	echo "Then check WireGuard separately — restart_firewall rebuilds iptables,"
	echo "not interfaces, so a stopped WireGuard server stays stopped:"
	echo "    wg show wgs\$(nvram get wgs_unit)   # 'Unable to access' = gone"
	echo "    service restart_wgs"
	echo
	echo "Before you fix it, consider capturing evidence — it disappears on repair:"
	echo "    iptables-save > /tmp/fault-natsave.txt"
elif [ "${STUCK:-0}" -gt 0 ] 2>/dev/null; then
	echo "NOT active right now, but this router HAS wedged its service queue"
	echo "($STUCK occurrence(s) in retained logs). That is the mechanism behind"
	echo "this fault. If you have had unexplained LAN-wide internet loss that a"
	echo "reboot fixed, this is very likely what it was."
	echo
	echo "Install the watchdog: it repairs the fault within a minute, unattended."
	echo "    curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/install.sh | sh"
else
	echo "No evidence of this fault in the state or logs available right now."
	echo
	echo "Given the short log retention, that is weak evidence of absence. If you"
	echo "recognise the symptoms — every device offline at once, router insisting"
	echo "it is connected, names resolving but nothing loading, a reboot curing"
	echo "it — run this probe again WHILE it is happening."
fi
echo
echo "=== end of probe ==="
