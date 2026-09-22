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

**This repo is the doctor.** A cron-driven watchdog that asks, every minute,
whether the things the router *says* should be running actually are — the WAN's
NAT rules, the port forwards, the WireGuard server, dnsmasq — and repairs
whichever the failed rebuild left behind. No daemon, no dependencies; a small
amount of logic wrapped in a lot of care about not making things worse.

There's also a [read-only probe](#am-i-actually-hitting-this-bug) that tells
you whether you're hitting this at all, including whether it has happened
before on your router.

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
natctl status        # active WAN, netdev, rules, per-check counters, + check
natctl check         # every active check — exit 0=all ok 1=broken 2=some unknown
natctl log           # recent syslog lines (rotates in ~1 day)
natctl history       # durable record of every repair ever made
natctl heal [check]  # force a repair now (ignores cooldown); optionally just one
natctl watchdog      # the cron entrypoint
natctl version
```

### "How do I know it's actually doing anything?"

A watchdog that works is invisible, which makes it hard to trust. `natctl log`
reads syslog — but syslog rotates in about a day on a busy router, so a repair
at 3am on a Tuesday can be gone before you ever look.

So repairs are also appended to `/jffs/scripts/nat-doctor.history`, which
survives rotation and reboots:

```
2026-09-22 21:03:00	firewall  DETECTED   wan0 connected on eth0 but no MASQUERADE in POSTROUTING
2026-09-22 21:03:30	firewall  REPAIRED   wan0 on eth0, MASQUERADE present, VSERVER 10 rules
```

It is written **only** when a repair actually happens — never on a healthy
check — so an empty history is the good outcome, not a broken one. `natctl
history` prints it with a count of repairs versus events that needed a human.

## How it decides

The WAN-up cascade is a chain of stop/start pairs, and a wedge strands
whatever pair it died inside — so the damage differs every time. Two observed
incidents on the same router:

| | 2026-09-13 | 2026-09-22 |
|---|---|---|
| died after | WireGuard *restarted* | `WireGuard: Stopping server` |
| NAT rules | missing | missing |
| WireGuard server | fine | **interface gone — total VPN lockout** |

So nat-doctor runs several independent checks. Each answers **three**
questions, and only acts when all three are unambiguous:

```
should_run   what the router's config DECLARES   (nvram)
is_ok        observable reality                  (rules / interface / process)
enabled      whether you want it watched         (HEAL_CHECKS)
```

| Check | Declared by | Broken when | Repair |
|---|---|---|---|
| `firewall` | WAN `state_t=2` | no `MASQUERADE` for the active WAN, or `VSERVER` empty while forwarding is on | `restart_firewall` |
| `wireguard` | `wgs_enable=1` | `wgs${wgs_unit}` interface absent | `restart_wgs` |
| `dnsmasq` | `sw_mode=1` | no `dnsmasq` process | `restart_dnsmasq` |
| `samba` | `enable_samba=1` | no `smbd` | `restart_samba` ⚠️ |
| `upnp` | `upnp_enable=1` | no `miniupnpd` | `restart_upnp` ⚠️ |
| `ntpd` | — | no `ntp` process | `restart_ntpd` ⚠️ |

Default active: **`firewall wireguard dnsmasq`** — the three whose repair
commands have been executed on a real router and confirmed to work, and the
three with observed or documented failure modes.

⚠️ **The opt-in three are untested.** Their repair commands have never been
run. They appear in a `strings` dump of `/sbin/rc`, but that dump is
unreliable — `restart_firewall` and `restart_wgs` are missing from it and both
work — so presence there is not evidence. Enabling one means its first real
execution would be during an outage. Each also carries its own hazard:
restarting Samba drops in-flight transfers, restarting UPnP drops active port
mappings, and `stop_ntpd` is *the service that wedges*, so poking ntpd around
a wedge is the repair most likely to re-enter the hang. See
[AGENTS.md](AGENTS.md) for what verifying them would involve.

**`should_run` comes from what nvram declares, never from what's running.**
If you have deliberately disabled WireGuard, its absence is *correct* and
nat-doctor leaves it alone. Getting this backwards would mean a watchdog that
fights your own configuration every minute, forever.

On a violation: one repair, wait, re-check. Fixed → log and stop. Still
broken → log loudly and, only for `firewall` and only if you explicitly opted
in, escalate to a reboot.

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
| `should_run` read from nvram, not from what's running | A service you disabled must never be "repaired" |
| Unreadable nvram gate ⇒ skip | Never act on intent we had to guess |
| Per-check cooldown and counters | One flapping check can't suppress repairs for the others |
| `REPAIR_TIMEOUT` on every repair | Our repairs use the queue that this bug wedges |
| `MAX_RUN` deadline per run | A long run can't outlive its usefulness |
| Lock stores its start time | Distinguishes a hung holder from a busy one, so a wedged repair can't silently disable the watchdog |
| Reboot escalation **off by default**, `firewall` only | Opt in with `touch /jffs/scripts/nat-doctor.reboot-ok`. Rebooting over a stopped Samba would be absurd |
| Reboot rate limit survives reboots | Otherwise an escalation could loop |

## Tunables

Optional, in `/jffs/scripts/nat-doctor.conf` (sourced over the defaults; the
installer never writes or overwrites this file):

```sh
HEAL_CHECKS="firewall wireguard dnsmasq"   # available: samba upnp ntpd

COOLDOWN=300           # min seconds between repair attempts, PER CHECK
MAXHEALS=3             # max repairs per WINDOW per check, then stand down
WINDOW=3600
RECHECK_WAIT=30        # settle time before re-checking after a repair
REBOOT_MIN_GAP=21600   # 6h minimum between escalated reboots

REPAIR_TIMEOUT=60      # hard-kill a repair command that hangs this long
MAX_RUN=240            # abandon the whole run after this many seconds
LOCK_STALE=600         # a lock held longer than this means the holder is hung
```

Those last three are not ordinary tuning knobs. Repairs call `service`, which
goes through the **same `rc_service` queue whose wedging causes this fault** —
so a repair attempted while that queue is stuck can hang indefinitely. Without
these bounds, one hung call would hold the lock forever and silently disable
the watchdog while everything still looked installed and healthy.

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
| `/jffs/scripts/nat-doctor.history` | durable repair record (persistent by design) |
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

**The quick way** — run the probe on the router. Read-only, changes nothing,
safe at any time:

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/extras/nat-fault-probe.sh | sh
```

It answers two questions separately: is the fault active *right now*, and has
it happened *before* in whatever log history survives. The second matters
because this fault is self-concealing — the router looks healthy afterwards,
and a reboot erases the live evidence, leaving only the syslog signature.

It also prints your `wandog` threshold, so you can see exactly how short a WAN
outage has to be on *your* router to take the dangerous path.

Output is copy-pasteable into a bug report.

**Manually**, while the symptoms are present, on the router:

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
