#!/bin/sh
# install.sh — nat-doctor installer for Asuswrt-Merlin.
#
# Run ON the router (after enabling SSH + JFFS scripts, see README):
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/install.sh | sh
#
# Or from a clone of this repo copied to the router:
#   sh install.sh
#
# Uninstall (removes the watchdog, boot hooks, state, alias):
#   sh install.sh uninstall

REPO_RAW="https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main"
DEST=/jffs/scripts
SS=$DEST/services-start
CRU_ID=nat-doctor-wd
PROFILE=/jffs/configs/profile.add
ALIAS_TAG="# nat-doctor"

fail() { echo "ERROR: $1" >&2; exit 1; }

[ -d /jffs ] || fail "no /jffs mount — is this an Asuswrt-Merlin router?"
[ "$(nvram get jffs2_scripts)" = "1" ] || fail "JFFS custom scripts are disabled.
Enable: Administration -> System -> 'Enable JFFS custom scripts and configs' = Yes,
hit Apply, then re-run this installer."

if [ "$1" = "uninstall" ]; then
  cru d "$CRU_ID" 2>/dev/null
  [ -f "$SS" ] && sed -i "/$CRU_ID/d" "$SS"
  [ -f "$PROFILE" ] && sed -i "/^alias natctl=.*nat-doctor/d" "$PROFILE"
  rm -f "$DEST/natctl" "$DEST/nat-doctor.conf" "$DEST/nat-doctor.reboot" "$DEST/nat-doctor.reboot-ok"
  rm -rf /tmp/nat-doctor
  echo "nat-doctor uninstalled."
  echo "(the 'natctl' alias stays live in THIS shell until you log out)"
  exit 0
fi

mkdir -p "$DEST"
for f in natctl; do
  if [ -f "./scripts/$f" ]; then
    cp "./scripts/$f" "$DEST/$f"
  else
    # ?cb= busts the raw CDN edge cache
    curl -fsSL "$REPO_RAW/scripts/$f?cb=$(date +%s)" -o "$DEST/$f" || fail "download of $f failed"
  fi
  chmod 755 "$DEST/$f"
done

# Boot hook (idempotent). cru entries do not survive a reboot, which is why
# services-start re-adds it on every boot.
if [ ! -f "$SS" ]; then printf '#!/bin/sh\n' > "$SS"; chmod 755 "$SS"; fi
grep -q "$CRU_ID" "$SS" || echo "cru a $CRU_ID \"* * * * * $DEST/natctl watchdog\"" >> "$SS"

# Make `natctl` callable by bare name in interactive shells (idempotent).
# profile.add is sourced, not executed — 644 is correct, no shebang needed.
mkdir -p /jffs/configs
[ -f "$PROFILE" ] || { : > "$PROFILE"; chmod 644 "$PROFILE"; }
grep -q "^alias natctl=" "$PROFILE" || echo "alias natctl='$DEST/natctl'   $ALIAS_TAG" >> "$PROFILE"

# Arm now, without waiting for a reboot.
cru a "$CRU_ID" "* * * * * $DEST/natctl watchdog"

echo ""
"$DEST/natctl" status

cat <<'EOF'

Installed and WATCHING. Every minute it verifies that the active WAN has a
MASQUERADE rule and that VSERVER is populated; if that invariant is violated
while the WAN is connected, it runs one rate-limited 'service restart_firewall'.

Reboot escalation is DISABLED by default. Enable it only if you accept an
automatic reboot when restart_firewall fails to resolve the fault:
  touch /jffs/scripts/nat-doctor.reboot-ok

From your NEXT login you can type plain "natctl" instead of the full path
(an alias was added to /jffs/configs/profile.add). Until then, use the path:

  /jffs/scripts/natctl status      # what it sees right now
  /jffs/scripts/natctl check       # invariant only (0=ok 1=broken 2=unknown)
  /jffs/scripts/natctl log         # what it has detected and healed
  /jffs/scripts/natctl heal        # force a heal attempt now
  sh install.sh uninstall          # remove everything

Tunables (optional, never overwritten by the installer):
  /jffs/scripts/nat-doctor.conf    # COOLDOWN, MAXHEALS, WINDOW, RECHECK_WAIT,
                                   # REBOOT_MIN_GAP
EOF
