# asuswrt-merlin-nat-doctor

> **Not a technical person?** Skip to
> [what this bug feels like in daily life](#in-plain-words--what-this-bug-feels-like).

A brief WAN link flap — a couple of seconds, the kind that happens when your
ISP bounces a port — can leave an ASUS router **healthy in every way it knows
how to measure, while every device on your network has no internet.**

The router's own connectivity is fine. The admin GUI says *Internet:
Connected*. DNS still resolves. Dual-WAN failover never triggers, correctly,
because nothing it can see is broken. But the NAT rules that translate your
LAN traffic onto the internet were never rebuilt, so your clients' packets
leave with private source addresses and nothing can reply. It stays that way
until someone forces a rebuild — often hours later, usually by rebooting.

The bug is in **stock AsusWRT's closed-source service manager**, so
[Asuswrt-Merlin](https://www.asuswrt-merlin.net/) and stock firmware are
equally affected, and it has been reported across the Wi-Fi 7 line.

**This repo is the doctor.** A cron-driven watchdog that checks one thing
every minute — *does the active WAN actually have a NAT rule?* — and repairs
the firewall when the answer is no. No daemon, no dependencies, ~20 lines of
actual logic wrapped in a lot of care about not making things worse.

## In plain words — what this bug feels like

Your internet "goes down", but strangely:

- The router's lights are normal and its web page says you're connected.
- Restarting your laptop's Wi-Fi doesn't help. Neither does a new cable.
- Some things half-work — a website may load from cache, a name may resolve —
  which makes you doubt yourself.
- Your ISP's line test passes, because their line genuinely is fine.
- **Rebooting the router fixes it**, so you reboot, and it works, and you
  never find out why. Then weeks later it happens again.

That's this bug. It isn't your ISP, your cables, or your devices. It's the
router forgetting one rule and never noticing.

## What actually happens

1. The WAN link drops briefly — **shorter than the dual-WAN failover
   threshold** (`wandog_interval × wandog_maxfail`, often ~18s).
2. Because it's below that threshold, `wanduck` — the daemon that would do a
   full, robust `restart_wan_line` — never engages. The flap is handled by
   `udhcpc`'s lightweight re-init path instead.
3. Everything in that path serialises through a **single-slot `rc_service`
   queue**. With only seconds between the down and up events, the two
   sequences collide. A service wedges on stop (`stop_ntpd` in the observed
   cases), `rc` force-aborts it, and **the WAN-keyed rule installation that
   should follow never runs.**
4. The result:

   ```
   # broken — the only surviving rule is an unrelated LAN hairpin
   -A POSTROUTING -s 192.168.1.0/24 -d 192.168.1.0/24 -o br0 -j MASQUERADE
   Chain VSERVER (1 references)          <-- empty: every port forward gone
   ```

   No `-o <wan> -j MASQUERADE`, so LAN packets egress the WAN still sourced
   `192.168.x.x` and nothing upstream can route a reply. Hence *timeouts*,
   not refusals.

5. **Nothing retries, and nothing detects it.** `wan0_state_t=2`, no errors
   logged, the GUI is green. Router-originated traffic is unaffected because
   it already carries the WAN address — which is why DNS keeps working and
   why every health check passes.

### Why a watchdog is the only possible answer

The dual-WAN health check pings its target **from the router**. During this
fault the router reaches the internet perfectly. So does DNS. **No
router-originated probe of any kind can detect this** — the router is never
the thing that's broken. The only way to see it is to inspect the rules
themselves, which is exactly what this does.

## Requirements

- An ASUS router running **Asuswrt-Merlin** (required — only Merlin runs user
  scripts; stock firmware is affected by the bug but cannot host the cure).
- **SSH enabled** and **JFFS custom scripts enabled**
  (Administration → System).

Developed and validated on an **RT-BE92U** (Merlin 3006.102.8). The logic is
model-agnostic — it reads the active WAN from nvram rather than assuming
anything — but see [AGENTS.md](AGENTS.md) for the platform facts that were
verified rather than assumed.

## Install

**Guided, from your computer:**

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/setup.sh | sh
```

**Directly, on the router:**

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/install.sh | sh
```

Either way it installs `natctl`, registers a per-minute cron watchdog, adds a
boot hook so the watchdog survives reboots, and prints a status report.

## Commands

```
natctl status      # what it sees right now: active WAN, netdev, rules, counters
natctl check       # invariant only — exit 0=healthy 1=broken 2=cannot tell
natctl log         # what it has detected and healed
natctl heal        # force a heal attempt now (ignores cooldown)
natctl watchdog    # the cron entrypoint
natctl version
```

## How it decides

The fault state is unambiguous and **cannot occur legitimately**:

> the active WAN unit is connected (`state_t=2`) **and** its netdev has no
> `MASQUERADE` rule in `POSTROUTING`

plus a secondary trigger: masquerade present but `VSERVER` empty *while port
forwarding is configured*.

On violation: one `service restart_firewall`, wait, re-check. If it's fixed,
log and stop. If not, log loudly and — only if you have explicitly opted in —
escalate to a reboot.

### Safety

The whole design principle is **when in doubt, do nothing**, because a false
positive restarts your firewall:

| Guard | Why |
|---|---|
| Follows the **active** WAN, never a hardcoded interface | On failover to a PPP secondary, NAT lives on `pppN`. A check hardcoded to `ethN` would restart the firewall *every minute for the whole outage* |
| Serial devices rejected as netdevs | `wan1_ifname` is `/dev/ttyUSB0` on USB-dongle secondaries |
| WAN down ⇒ skip | Absent rules are *correct* while the WAN is down |
| Unresolvable unit or netdev ⇒ skip | Never act on a state you can't read |
| `VSERVER` gated on configured forwards | Empty is correct if you have none |
| PID lockfile | A heal outlives the 60s cron interval; runs must not stack |
| `COOLDOWN` (300s) | No thrashing |
| `MAXHEALS` per `WINDOW` (3/hour) | After that it stands down and only logs. A watchdog that can't stop trying is worse than none |
| Reboot escalation **off by default** | Opt in with `touch /jffs/scripts/nat-doctor.reboot-ok` |
| Reboot rate limit survives reboots | Otherwise an escalation could loop |

## Tunables

Optional, in `/jffs/scripts/nat-doctor.conf` (sourced over the defaults; the
installer never writes or overwrites this file):

```sh
COOLDOWN=300           # min seconds between heal attempts
MAXHEALS=3             # max heals per WINDOW before standing down
WINDOW=3600
RECHECK_WAIT=30        # settle time before re-checking after restart_firewall
REBOOT_MIN_GAP=21600   # 6h minimum between escalated reboots
```

## Uninstall

```sh
sh install.sh uninstall
# or
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/uninstall.sh | sh
```

Every artifact, for manual removal or audit:

| Artifact | Purpose |
|---|---|
| `/jffs/scripts/natctl` | the script |
| `/jffs/scripts/nat-doctor.conf` | user tunables (optional) |
| `/jffs/scripts/nat-doctor.reboot` | escalated-reboot timestamp (persistent by design) |
| `/jffs/scripts/nat-doctor.reboot-ok` | reboot-escalation opt-in flag |
| `/jffs/scripts/services-start` | one `cru a nat-doctor-wd …` line |
| `/jffs/configs/profile.add` | one `alias natctl=…` line |
| `cru` entry `nat-doctor-wd` | the per-minute watchdog |
| `/tmp/nat-doctor/` | runtime state (lock, heal timestamps) |

## Testing

```sh
for f in install.sh uninstall.sh scripts/* tests/*; do sh -n "$f"; done
sh tests/invariant.sh
```

The fixtures extract the detection functions verbatim from `scripts/natctl`
and drive them against a stubbed `nvram`, `iptables` and netdev namespace.
See [AGENTS.md](AGENTS.md) for the negative-control procedure that proves
they still have teeth.

## Am I actually hitting this bug?

While the symptoms are present, on the router:

```sh
nvram get wan0_state_t                      # 2 = connected
ping -c3 1.1.1.1                            # works from the router
iptables -t nat -S POSTROUTING              # no '-o <wan> -j MASQUERADE'?
iptables -t nat -S VSERVER                  # empty despite configured forwards?
grep -E "link down|abort the stuck service" /tmp/syslog.log
```

The signature is a `WAN(0) link down` / `WAN was restored` pair seconds apart,
followed within ~15s by `rc_service: abort the stuck service:stop_ntpd`.

**Recovery without this tool**, in increasing order of disruption: `service
restart_firewall`; forcing a WAN outage longer than the failover threshold
(which promotes recovery to `wanduck`'s robust path); a reboot.

## Related

- [asuswrt-merlin-flowcache-doctor](https://github.com/deviationist/asuswrt-merlin-flowcache-doctor)
  — sibling project for a different silent ASUS fault: Broadcom's flow cache
  blackholing traffic to specific LAN hosts after a Wi-Fi band roam.
- [SNBForums: rc_service queue deadlock on WAN reconnection](https://www.snbforums.com/threads/gt-be98-pro-rc_service-queue-deadlock-on-wan-reconnection-causing-wan-outage.97346/)
  — GT-BE98 Pro, same signature.
- [SNBForums: dnsmasq restart gets stuck on IPv6 prefix renewal](https://www.snbforums.com/threads/dnsmasq-restart-gets-stuck-on-ipv6-prefix-renewal-dns-dies-until-reboot.97560/)
  — same queue, different service, on **stock** firmware. Includes the
  maintainer-identified `notify_rc_and_wait_2min()` call and ASUS's response
  to the report.

## License

MIT — see [LICENSE](LICENSE).
