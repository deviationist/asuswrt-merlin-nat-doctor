#!/bin/sh
# uninstall.sh — remove nat-doctor completely from an Asuswrt-Merlin router.
#
# Run ON the router:
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-nat-doctor/main/uninstall.sh | sh
#
# Removes: the control script, the cron watchdog, the services-start boot hook,
# the shell alias, user tunables, the persistent reboot stamp, and runtime
# state. Leaves everything else on your router untouched.
#
# nat-doctor runs no daemon — the watchdog is a cron entry — so there is no
# process to stop and no pidfile to chase.

DEST=/jffs/scripts
SS=$DEST/services-start
CRU_ID=nat-doctor-wd
PROFILE=/jffs/configs/profile.add

cru d "$CRU_ID" 2>/dev/null
[ -f "$SS" ] && sed -i "/$CRU_ID/d" "$SS"
[ -f "$PROFILE" ] && sed -i "/^alias natctl=.*nat-doctor/d" "$PROFILE"

rm -f "$DEST/natctl" \
      "$DEST/nat-doctor.conf" \
      "$DEST/nat-doctor.reboot" \
      "$DEST/nat-doctor.reboot-ok"
rm -rf /tmp/nat-doctor

logger -t nat-doctor "uninstalled" 2>/dev/null
echo "nat-doctor uninstalled. (services-start kept, minus our line.)"
echo "(the 'natctl' alias stays live in THIS shell until you log out)"
