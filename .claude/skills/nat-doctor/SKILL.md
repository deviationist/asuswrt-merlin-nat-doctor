---
name: nat-doctor
description: Diagnose and fix the AsusWRT half-built firewall fault on ASUS routers — use when every device on the LAN suddenly has no internet but the router insists it is connected, when names resolve yet nothing loads, when port forwards or a VPN into the house stop working for no reason, or when "rebooting the router fixes it" has become a recurring ritual. Guides diagnosis over SSH, the one-command fix that avoids a reboot, and installing the automatic watchdog (requires Asuswrt-Merlin).
---

# nat-doctor — diagnosis & fix guide

You are helping the user determine whether they're hitting the AsusWRT
incomplete-firewall-rebuild fault (see this repo's README for the full
mechanism), and if so, fix it without a reboot. Work stepwise; report findings
between steps. Everything router-side happens over SSH — ask for the router
address and SSH username if not known.

**Read this first.** Two things about this fault make it different from
ordinary "internet is down" triage:

1. **Remote access may be gone.** The fault can leave the WireGuard server
   stopped, so a VPN into the house won't work — and the router's SSH isn't
   port-forwarded on most setups. If the user is away from home, say so early
   rather than sending them round a loop of failing connection attempts.
2. **Don't reboot yet.** A reboot cures it and destroys the evidence, and the
   syslog only retains about a day. `service restart_firewall` fixes it just
   as well while preserving everything. If the user just wants their internet
   back and doesn't care why, that's a legitimate choice — but say what is
   being given up.

## 1. Symptom triage (no tools needed)

Strong signals (most should hold):

- **Every** device on the LAN lost internet at once — not one host, all of them.
- The router's web UI says **Internet: Connected**, with the correct WAN IP.
- Names still resolve but nothing loads: `host example.com` works, the page
  times out. DNS is the *last* thing to break here, which is why it misleads.
- It started after a brief blip, often unnoticed — the trigger is a WAN link
  flap of only a few seconds.
- **Rebooting the router fixes it**, and it has happened more than once.
- Port forwards and inbound VPN stopped working at the same moment.
- The ISP's line test passes, because their line genuinely is fine.

Counter-signals (investigate other causes instead): only one LAN host is
affected (that's the sibling project, flowcache-doctor); the router itself
cannot reach the internet; the WAN link is genuinely down; a reboot does
*not* fix it.

## 2. Confirm from any LAN client

```sh
host vg.no                       # expect: resolves fine
curl -m 5 -o /dev/null https://1.1.1.1   # expect: timeout
ping -c 3 1.1.1.1                # expect: 100% loss
```

DNS working while a raw-IP connection times out is the signature. Resolution
happens *on the router*, which is healthy; only forwarded traffic is broken.

## 3. Confirm from outside (optional, strong evidence)

From a phone on mobile data, against the home WAN IP:

```sh
ping <home-wan-ip>               # expect: replies — the router is alive
nc -z -G 5 <home-wan-ip> 443     # expect: closed, if 443 is normally forwarded
```

Router reachable + every forward closed = the port-forward chain is empty.

## 4. Router-side proof (SSH to the router)

```sh
nvram get wan0_state_t                  # expect 2 = connected
ping -c 3 1.1.1.1                       # expect: works FROM the router
iptables -t nat -S POSTROUTING          # the money shot
iptables -t nat -S VSERVER
```

Diagnostic if **both** hold while `wan0_state_t=2`:

- `POSTROUTING` has **no** `-o <wan-iface> -j MASQUERADE` rule
- `VSERVER` shows only `-N VSERVER` (no `-A` lines) despite configured forwards

Without the masquerade rule, LAN packets leave the WAN still carrying private
source addresses, so nothing can route a reply — timeouts, not refusals. The
router is unaffected because its own traffic already has the WAN address.

Confirm the trigger in the log:

```sh
grep -E "link down|WAN was restored|abort the stuck service|hnd_get_phy_status" /tmp/syslog.log
```

Signature: a `WAN(0) link down` / `WAN was restored` pair seconds apart,
followed within ~15 s by `rc_service: abort the stuck service:stop_ntpd`.
Timestamps mix UTC and local in this firmware — don't read a two-hour jump as
two separate events.

If nat-doctor is already installed, all of the above collapses to:

```sh
/jffs/scripts/natctl check      # 0 = ok, 1 = broken, 2 = cannot tell
```

## 5. The fix — no reboot needed

```sh
service restart_firewall
```

Wait ~20 s, then re-check `iptables -t nat -S POSTROUTING` and re-test from a
client. Instant recovery confirms the diagnosis.

**Then check WireGuard separately** — `restart_firewall` rebuilds iptables,
not interfaces, so a stopped WireGuard server stays stopped:

```sh
wg show wgs1                    # "Unable to access interface" = it's gone
service restart_wgs             # if so
```

Also worth checking while you're there, if the user relies on them: `pidof
dnsmasq`, `pidof smbd`. The WAN-up cascade is a chain of stop/start pairs and
it strands whatever pair it died inside, so the casualties differ per
incident.

If `restart_firewall` does *not* fix it, a reboot will — but capture
`iptables-save` and the syslog window first, because that outcome is not yet
documented anywhere and is worth reporting.

## 6. The permanent fix

Requires Asuswrt-Merlin (stock firmware can't run user scripts — if the user
is on stock, point them to https://www.asuswrt-merlin.net/ and this repo's
README "Requirements"). Verify JFFS scripts: `nvram get jffs2_scripts` must be
`1` (else: web UI → Administration → System → Enable JFFS custom scripts and
configs = Yes → Apply).

Install (on the router):

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/install.sh | sh
```

It checks every minute and repairs automatically. Verify:

```sh
/jffs/scripts/natctl status     # active checks, WAN, rules, counters, verdict
/jffs/scripts/natctl log        # what it has detected and repaired
```

Reboot escalation is off by default and should stay off unless the user
explicitly wants an automatic reboot when `restart_firewall` fails to help.

## 7. Ongoing / troubleshooting

- What has it seen? `ssh <router> '/jffs/scripts/natctl log'`
- Force a repair: `natctl heal`, or one check only: `natctl heal wireguard`
- Enable more checks: set `HEAL_CHECKS` in `/jffs/scripts/nat-doctor.conf`.
  **`samba`, `upnp` and `ntpd` are off for a reason** — their repair commands
  have never been executed on real hardware. See AGENTS.md before enabling.
- A `SKIP` verdict is not a failure. It means the state was indeterminate —
  WAN down, an unreadable nvram gate, a service the owner disabled — and the
  correct action was to do nothing.
- The fault recurs: two occurrences nine days apart on the reference router.
  If the user has seen it once, expect it again, and arm the watchdog.
