#!/bin/sh
# One CPU1 offline/online round: taking the second core down and up goes through PSCI in OP-TEE, so it
# proves OP-TEE survives. Port of extra-ram-tests/printer/cpu1test.sh with parameterised paths.
# Environment (all optional): XR_STATE, XR_TESTDIR (output dir, default $XR_STATE/test), XR_CMDLINE,
# XR_MEMINFO, XR_BOOTID, XR_CPUDIR, XR_MESSAGES.
: ${XR_STATE:=/etc/extra-ram}
: ${XR_TESTDIR:=$XR_STATE/test}
: ${XR_CMDLINE:=/proc/cmdline}
: ${XR_MEMINFO:=/proc/meminfo}
: ${XR_BOOTID:=/proc/sys/kernel/random/boot_id}
: ${XR_CPUDIR:=/sys/devices/system/cpu}
: ${XR_MESSAGES:=/var/log/messages}
D=$XR_TESTDIR
mkdir -p "$D" || exit 1
L=$D/cpu1test-$(cut -c1-8 "$XR_BOOTID").log
log(){ echo "$(date +%T) $*" >> "$L"; sync; }
# terminated mid-round (selftest.sh cleanup sends TERM): never leave the second core offline
trap 'echo 1 > "$XR_CPUDIR/cpu1/online"; log "interrupted, cpu1 -> 1"; exit 1' TERM HUP INT
S=$({ wc -l < "$XR_MESSAGES"; } 2>/dev/null || echo 0)
log "start nodsp=$(grep -cwE "xram_on|zmod_nodsp|zmod_mem" "$XR_CMDLINE") memtotal=$(awk "/MemTotal/{print \$2}" "$XR_MEMINFO") online=$(cat "$XR_CPUDIR/online")"
log "cpu1 -> 0"
echo 0 > "$XR_CPUDIR/cpu1/online"
log "cpu1 off rc=$? online=$(cat "$XR_CPUDIR/online")"
sleep 5
log "cpu1 -> 1"
echo 1 > "$XR_CPUDIR/cpu1/online"
log "cpu1 on rc=$? online=$(cat "$XR_CPUDIR/online")"
sleep 2
tail -n +$((S+1)) "$XR_MESSAGES" 2>/dev/null | grep kernel >> "$L"
log "done"
