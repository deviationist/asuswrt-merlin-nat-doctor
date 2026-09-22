# AGENTS.md — guidance for AI coding agents working on this repo

This repo ships shell scripts that run on **Asuswrt-Merlin routers under
busybox `sh`**. The constraints are unusual and violating them produces
silent, hard-to-debug failures — read this before editing anything.

Sibling project: [`asuswrt-merlin-flowcache-doctor`](https://github.com/deviationist/asuswrt-merlin-flowcache-doctor).
Same author, same target platform, same house style. Most constraints below
were learned there; they apply here unchanged.

## Hard constraints (learned the hard way)

- **busybox `sh` only** for `scripts/` and the installers. No bash, no arrays,
  no `[[`, no process substitution. `sh -n <file>` is the repo's only lint —
  run it before committing.
- **No `command` builtin on the router's busybox sh** — `command -v foo` fails
  with "command: not found", a false negative that looks like foo is missing.
  Probe binaries with `which` or the `type` builtin.
- **No `pgrep`/`pkill`** on the router.
- **Never find a process via broad `ps | grep <string>`** — an SSH session
  whose command line mentions the path will match itself. `cmd_watchdog()`
  uses a pidfile plus `/proc/<pid>` existence; keep it that way.
- **JFFS flash wear: never write routine state to `/jffs`.** Runtime state
  goes to `/tmp/nat-doctor` (RAM); syslog via `logger -t nat-doctor`.
  **The one exception** is `/jffs/scripts/nat-doctor.reboot`, the escalated-
  reboot timestamp: it *must* survive a reboot or an escalation could reboot
  into the same fault and loop. It is written at most once per
  `REBOOT_MIN_GAP` (6h default), so it is not a wear concern. Do not move
  anything else to `/jffs`.
- **macOS BSD tools differ from GNU**: `sed -i` needs `''`. This repo is
  developed from macOS.
- **No development-setup specifics in shipped code** — no real IPs, MACs,
  hostnames or SSIDs, not even in comments or test fixtures. Use
  `192.168.1.x` / `198.51.100.x` (TEST-NET-2) / `AA:BB:CC:DD:EE:FF` style
  placeholders.
- **User tunables live in `/jffs/scripts/nat-doctor.conf`** (sourced over
  defaults). The installer must never write or overwrite it.
- **Every artifact is inventoried** (see the README's uninstall table) and
  **both uninstall paths** (`install.sh uninstall`, `uninstall.sh`) must
  remove every artifact, including any new one you add.

## Design invariants (do not weaken)

- **When in doubt, do nothing.** Every indeterminate state — unknown WAN unit,
  unresolvable netdev, WAN legitimately down, an unreadable nvram gate — is a
  SKIP, never a repair. A false positive restarts real services.
- **Every check answers THREE questions, and `should_run` comes from nvram.**
  `should_run_*` reports what the router's config DECLARES (0=yes, 1=no,
  2=cannot tell), `is_ok_*` reports observable reality, and `HEAL_CHECKS`
  says whether the operator wants us watching at all. **A service the user
  deliberately disabled must never be "repaired"** — inferring intent from
  what is running instead of what is declared would make the watchdog fight
  the owner's own configuration every minute, forever. Fixtures 13, 19, 23
  and 24 pin this; if you change a gate, add a disabled-case fixture.
- **Every repair is bounded, and the bounds are not optional.** Repairs call
  `service`, which goes through `notify_rc` into the SAME `rc_service` queue
  whose wedging causes this fault — so a repair attempted during a wedge can
  hang forever. `REPAIR_TIMEOUT` kills a hung repair, `MAX_RUN` abandons an
  over-long run, and the lockfile stores its start time so `LOCK_STALE` can
  tell a hung holder from a busy one. Without that last part a single wedged
  `service` call would hold the lock forever and **silently disable the
  watchdog while everything still looked installed and healthy** — the worst
  failure mode available to this program.
- **Rate limiting is per check, not global.** A shared cooldown would let one
  flapping check suppress repairs for every other. `MAXHEALS` per `WINDOW` is
  a rolling window, so a check stands down and then retries later rather than
  giving up permanently — the fault is recurring, so permanent surrender
  would be wrong.
- **THE CHECK MUST FOLLOW THE ACTIVE WAN, NEVER A HARDCODED INTERFACE.**
  This is the single most safety-critical rule here. On a dual-WAN router
  failed over to a PPP secondary, NAT lives on `pppN`, not the primary's
  `ethN`. A check hardcoded to the primary would see "no MASQUERADE" and run
  `restart_firewall` **every minute for the entire duration of a genuine
  outage** — converting a survivable failover into a catastrophe. Cases 4-6
  of `tests/invariant.sh` exist solely to make that regression loud.
- **`VSERVER` empty is only a fault when forwards are configured.** A user
  with no port forwards correctly has an empty chain. Gate it on
  `vts_enable_x` **and** a non-empty `vts_rulelist`.
- **Reboot escalation is OFF by default** and requires
  `/jffs/scripts/nat-doctor.reboot-ok`. Rebooting someone's router
  unprompted is not a default anyone should inherit. It is also rate-limited
  independently of heals, by a timestamp that survives reboots.
- **Rate limiting is layered**: a lockfile (heals take `RECHECK_WAIT`s while
  cron fires every 60s), a `COOLDOWN` between attempts, and a hard
  `MAXHEALS`-per-`WINDOW` ceiling after which it stands down and only logs.
  A watchdog that cannot stop trying is worse than no watchdog.
- **No daemon.** The watchdog is a `cru` entry. The check is a handful of
  `nvram`/`iptables` reads — cheap per minute — and cron is strictly more
  robust than a daemon that can die silently. Don't "upgrade" this to a
  daemon.
- **Never assume `service restart_firewall` is sufficient.** It was not
  verified against a live occurrence of the fault at the time of writing, and
  one field report (SNB 97346) says only a reboot worked for them. That
  uncertainty is why the escalation path exists.

## Verified platform facts

Collected live on an RT-BE92U, Merlin 3006.102.8. Re-verify before relying on
any of these on another model:

- **There is no `timeout` applet.** `flock`, `kill`, `pidof` and `sleep` exist.
  `run_limited()` supervises by hand because of this.
- **`strings /sbin/rc | grep restart_` UNDER-REPORTS.** `restart_firewall` and
  `restart_wgs` are both absent from that list and both work. Use it as a hint,
  never to reject a service name — verify by running it.
- **Verified repair commands** (each actually executed on the router):
  `restart_firewall` (healed a live fault 2026-09-22), `restart_wgs` (restored
  a missing `wgs1` the same night), `restart_dnsmasq` (pid changed cleanly,
  DNS resolving after). `restart_samba`, `restart_ntpd`, `restart_upnp` appear
  in the strings list but have NOT been executed — which is part of why they
  are opt-in.
- **`restart_firewall` does NOT restore the WireGuard server.** It rebuilds
  iptables, not interfaces. A separate `restart_wgs` is required. This is why
  the wireguard check exists.
- **`wgs_unit` names the interface** — it is `wgs${wgs_unit}`, not a hardcoded
  `wgs1`. Same class of bug as hardcoding the WAN interface.
- **`dnsmasq` has no enable key.** Intent is inferred from `sw_mode`
  (1=router, 2=repeater, 3=AP). `dnsmasq_enable` does not exist.
- **The `stop_ntpd` wedge is not DNS-related.** Switching the router's NTP
  servers from hostnames to literal IPs on 2026-09-14 did NOT prevent a
  recurrence on 2026-09-22 — it wedged on `stop_ntpd` again. Whatever hangs
  in there, it is not name resolution. Do not re-propose that theory.

- `service restart_wgs` rebuilds WireGuard server peers from nvram;
  `service restart_wgsc <n>` does **not** — it only re-reads that peer's
  enable state. Service names on this firmware need verifying, not assuming.
- `wan_primary` holds the active unit number; `wanN_primary` are per-unit
  flags. Both are used, in that order.
- `wanN_ifname` for a USB/serial secondary is `/dev/ttyUSB0` — a serial
  device, **not** a netdev. `active_ifname()` rejects it.
- `wg set` and `ip route` are live-kernel only; any service restart that
  rebuilds from nvram discards them.

## Testing

- Syntax: `for f in install.sh uninstall.sh scripts/* tests/*; do sh -n "$f"; done`
- **Invariant fixtures: `sh tests/invariant.sh`** — run after ANY change to
  the detection functions. It extracts them verbatim from `scripts/natctl`
  and drives them against a stubbed `nvram`, `iptables` and netdev namespace.
- **Negative control** — confirm the fixtures still have teeth after editing
  them:

  ```sh
  sed 's|^\tcase "$(nvram get wan${_u}_proto 2>/dev/null)" in|\techo eth0; return 0\n&|' \
      scripts/natctl > /tmp/natctl-broken
  NATCTL_SRC=/tmp/natctl-broken sh tests/invariant.sh   # must fail cases 4-6
  ```

  If that passes, the fixtures are vacuous and you have lost the only
  protection against the hardcoded-interface regression.
- There is no CI and no router emulator. Real validation happens on an actual
  Asuswrt-Merlin router over SSH:

  ```sh
  tar cf - -C scripts natctl | ssh <router> 'tar xf - -C /jffs/scripts && chmod 755 /jffs/scripts/natctl && /jffs/scripts/natctl status'
  ```

- **Testing the heal path for real** means breaking NAT deliberately
  (`iptables -t nat -D POSTROUTING <masquerade rule>`), which cuts every LAN
  client off until it is restored. Only do that with physical access to the
  router, and never on someone else's network.

## Release checklist

Bump `VERSION` in `scripts/natctl` in the release commit, then tag `vX.Y.Z`
plus a GitHub Release. Docs-only changes get no release — users install from
`main` via curl. Note that `raw.githubusercontent.com` can lag a push by
several minutes even with a cache-bust parameter.
