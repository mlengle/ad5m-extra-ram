#!/bin/sh
# Three CPU1 offline/online rounds while harvest.py holds pages; after each round harvest.py is told
# (SIGUSR1) to verify its pages. Port of extra-ram-tests/printer/cpu1multi.sh with parameterised paths.
# Environment (all optional): XR_STATE, XR_TESTDIR (output dir, default $XR_STATE/test), XR_BOOTID, XR_CPUDIR.
: ${XR_STATE:=/etc/extra-ram}
: ${XR_TESTDIR:=$XR_STATE/test}
: ${XR_BOOTID:=/proc/sys/kernel/random/boot_id}
: ${XR_CPUDIR:=/sys/devices/system/cpu}
D=$XR_TESTDIR
mkdir -p "$D" || exit 1
L=$D/cpu1multi-$(cut -c1-8 "$XR_BOOTID").log
H=$(cat "$D/harvest.pid" 2>/dev/null)
log(){ echo "$(date +%T) $*" >> "$L"; sync; }
for i in 1 2 3; do
  log "round $i off"; echo 0 > "$XR_CPUDIR/cpu1/online"; log "round $i offline=$(cat "$XR_CPUDIR/online")"
  sleep 3
  echo 1 > "$XR_CPUDIR/cpu1/online"; log "round $i online=$(cat "$XR_CPUDIR/online")"
  [ -n "$H" ] && kill -USR1 "$H"; sleep 4; log "$(tail -1 "$D/harvest.log")"
done
log done
