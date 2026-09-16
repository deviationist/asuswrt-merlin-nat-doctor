#!/bin/sh
# setup.sh — guided install/uninstall for nat-doctor, run from YOUR COMPUTER
# (macOS/Linux), not on the router.
#
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/setup.sh | sh
#
# It asks for your router's address and SSH username, connects (ssh prompts
# for your password if you haven't set up keys), checks whether nat-doctor is
# installed, and walks you through installing, reinstalling, or uninstalling.

RAW="https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main"
TTY=/dev/tty

say() { printf '%s\n' "$*"; }
ask() { printf '%s' "$1" > "$TTY"; read -r REPLY < "$TTY"; }
die() { say "ERROR: $*" >&2; exit 1; }

[ -e "$TTY" ] || die "no interactive terminal available — run this in a terminal."

say "=== nat-doctor guided setup ==="
say ""
say "This connects to your Asuswrt-Merlin router over SSH."
say "Prerequisites (router web UI, Administration -> System):"
say "  - 'Enable JFFS custom scripts and configs' = Yes"
say "  - 'Enable SSH' = LAN only"
say ""

# ASUS ships both 192.168.50.1 (most modern models, incl. the Wi-Fi 7 line
# this bug is reported on) and 192.168.1.1 (older models) as factory defaults.
# Anything else means the owner changed it — hence the prompt.
say "Your router's LAN address — ASUS factory defaults are 192.168.50.1"
say "(most current models) or 192.168.1.1 (older). Yours may differ."
ask "Router address [192.168.50.1]: "
HOST=${REPLY:-192.168.50.1}
ask "SSH username [admin]: "
USER=${REPLY:-admin}
TARGET="$USER@$HOST"

# One TCP connection for everything: multiplex where the platform allows it,
# so a password is asked at most once.
CP="$HOME/.ssh/natdoc-setup-$$"
SSHOPTS="-o ConnectTimeout=8 -o ControlPath=$CP"
cleanup() { ssh -o ControlPath="$CP" -O exit "$TARGET" 2>/dev/null; rm -f "$CP"; }
trap cleanup EXIT INT TERM

say ""
say "Connecting to $TARGET (enter your router password if prompted)..."
ssh $SSHOPTS -o ControlMaster=auto -o ControlPersist=120 "$TARGET" true < "$TTY" \
  || die "cannot SSH to $TARGET — check address, username, and that SSH is enabled."

R() { ssh $SSHOPTS "$TARGET" "$@"; }

STATE=$(R '
  [ -d /jffs ] || { echo NOJFFS; exit 0; }
  [ "$(nvram get jffs2_scripts)" = "1" ] || { echo NOSCRIPTS; exit 0; }
  if [ -f /jffs/scripts/natctl ]; then
    if cru l 2>/dev/null | grep -q nat-doctor-wd; then echo INSTALLED_ARMED; else echo INSTALLED_UNARMED; fi
  else
    echo NOT_INSTALLED
  fi')

case "$STATE" in
  NOJFFS)    die "no /jffs on this device — is it an Asuswrt-Merlin router?" ;;
  NOSCRIPTS) die "JFFS custom scripts are disabled. Enable them in the web UI
       (Administration -> System -> 'Enable JFFS custom scripts and configs' = Yes,
       Apply, reboot if asked), then re-run this setup." ;;
esac

say ""
case "$STATE" in
  INSTALLED_ARMED)   say "Status: nat-doctor is INSTALLED and the watchdog is ARMED." ;;
  INSTALLED_UNARMED) say "Status: nat-doctor is installed but the cron watchdog is MISSING." ;;
  NOT_INSTALLED)     say "Status: nat-doctor is NOT installed." ;;
esac
say ""

if [ "$STATE" = "NOT_INSTALLED" ]; then
  ask "Install it now? [Y/n]: "
  case "$REPLY" in n|N) say "Nothing done. Bye!"; exit 0 ;; esac
  ACTION=install
else
  say "  [u] uninstall"
  say "  [r] reinstall / repair (safe, idempotent)"
  say "  [s] show current status and exit"
  say "  [q] quit"
  ask "Choice [q]: "
  case "$REPLY" in
    u|U) ACTION=uninstall ;;
    r|R) ACTION=install ;;
    s|S) R '/jffs/scripts/natctl status' || true; exit 0 ;;
    *)   say "Nothing done. Bye!"; exit 0 ;;
  esac
fi

say ""
if [ "$ACTION" = "install" ]; then
  R "curl -fsSL $RAW/install.sh | sh" || die "install failed."
  say ""
  say "Done! The watchdog runs every minute and survives reboots."
  say "Check what it sees anytime with:"
  say "  ssh $TARGET '/jffs/scripts/natctl status'"
else
  R "curl -fsSL $RAW/uninstall.sh | sh" || die "uninstall failed."
  say ""
  say "Done! nat-doctor has been fully removed."
fi
