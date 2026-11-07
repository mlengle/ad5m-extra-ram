#!/bin/sh
# Memory self-test of the Extra RAM mode (run it through "extra-ram test"): CPU1 offline/online rounds
# (PSCI goes through OP-TEE, so OP-TEE must survive) and a page harvester that fills pages of the freed
# DSP range with a pattern and verifies them for the whole soak. Port of
# extra-ram-tests/printer/selftest.sh with parameterised paths.
# Environment (all optional): XR_STATE, XR_TESTDIR (output dir, default $XR_STATE/test), XR_PYTHON
# (default /usr/bin/python3), XR_SOAK (soak seconds, default 600), XR_CMDLINE, XR_MEMINFO, XR_BOOTID,
# XR_MEMBLOCK, XR_CPUDIR, XR_MESSAGES.
# The summary goes to stdout and to $XR_TESTDIR/selftest-BOOTID.log; the last line is RESULT PASS or RESULT FAIL.
H=$(cd "$(dirname "$0")" && pwd)
: ${XR_STATE:=/etc/extra-ram}
: ${XR_TESTDIR:=$XR_STATE/test}
: ${XR_PYTHON:=/usr/bin/python3}
: ${XR_SOAK:=600}
: ${XR_CMDLINE:=/proc/cmdline}
: ${XR_MEMINFO:=/proc/meminfo}
: ${XR_BOOTID:=/proc/sys/kernel/random/boot_id}
: ${XR_MEMBLOCK:=/sys/kernel/debug/memblock/reserved}
: ${XR_CPUDIR:=/sys/devices/system/cpu}
: ${XR_MESSAGES:=/var/log/messages}
export XR_STATE XR_TESTDIR XR_PYTHON XR_CMDLINE XR_MEMINFO XR_BOOTID XR_MEMBLOCK XR_CPUDIR XR_MESSAGES
D=$XR_TESTDIR
mkdir -p "$D" && cd "$D" || { echo "selftest: cannot use $D"; echo "RESULT FAIL"; exit 1; }
B=$(cut -c1-8 "$XR_BOOTID"); L=$D/selftest-$B.log
log(){ echo "$(date +%T) $*" >> "$L"; echo "$*"; sync; }
# Orphans of an interrupted earlier run (the pid files are rotated away below): stop them if the pid is still ours
for f in harvest.pid monitor.pid; do
    op=$(cat "$f" 2>/dev/null)
    case "$op" in ''|*[!0-9]*) continue ;; esac
    tr '\0' ' ' < "/proc/$op/cmdline" 2>/dev/null | grep -qE "harvest.py|monitor.py" && kill "$op" 2>/dev/null
done
# A second run in the same boot must not count the rounds and lines of the first one
for f in cpu1test-$B.log cpu1multi-$B.log harvest.log monitor-$B.csv kernel-$B.log harvest.pid monitor.pid; do
    [ -e "$f" ] && mv -f "$f" "$f.prev"
done

# Cleanup on interruption (INT/TERM/HUP, also any other exit before the end): stop the harvester and the
# monitor, bring CPU1 back online, report RESULT FAIL. Long waits are "cmd & wait $!" so that a trapped
# signal is handled at once instead of after the foreground command (sleep 600) has finished.
SP=; CP=; HP=; MP=; FINISHED=
# await_harvest: wait up to 60 s for the final verify of harvest.py (its STOP line; kill -0 alone would also
# succeed on a zombie)
await_harvest() {
    i=0; while [ $i -lt 60 ] && kill -0 $HP 2>/dev/null && ! grep -q " STOP " harvest.log 2>/dev/null; do sleep 1; i=$((i+1)); done
}
cleanup() {
    kill $SP $CP 2>/dev/null
    kill $(cat harvest.pid 2>/dev/null) $(cat monitor.pid 2>/dev/null) $HP $MP 2>/dev/null
    echo 1 > "$XR_CPUDIR/cpu1/online" 2>/dev/null
    await_harvest
    echo 1 > "$XR_CPUDIR/cpu1/online" 2>/dev/null   # again: a killed cpu1 script may have been mid-round
}
on_signal() {
    trap '' INT TERM HUP
    cleanup
    FINISHED=1
    log "interrupted"
    log "RESULT FAIL"
    exit 1
}
trap on_signal INT TERM HUP
trap '[ -n "$FINISHED" ] || cleanup' EXIT

log "start up=$(cut -d" " -f1 /proc/uptime) nodsp=$(grep -cwE "xram_on|zmod_nodsp|zmod_mem" "$XR_CMDLINE") memtotal=$(awk "/MemTotal/{print \$2}" "$XR_MEMINFO") tee_rsv=$(grep -c 41b00000 "$XR_MEMBLOCK" 2>/dev/null) soak=${XR_SOAK}s"
"$H/cpu1test.sh" & CP=$!; wait $CP
# the early round counts only when cpu1 really went offline ("online=0") and came back ("online=0-1");
# lines are anchored at the end so that "online=0-1" never passes for "online=0"
E=0
grep -q " cpu1 off rc=0 online=0$" cpu1test-$B.log 2>/dev/null && grep -q " cpu1 on rc=0 online=0-1$" cpu1test-$B.log 2>/dev/null && E=1
log "cpu1 early: $E"
"$XR_PYTHON" -I "$H/monitor.py" --out "$D" > monitor.err 2>&1 &
MP=$!
"$XR_PYTHON" -I "$H/harvest.py" --out "$D" --rounds 16 --interval 30 > harvest.err 2>&1 &
HP=$!
sleep "$XR_SOAK" & SP=$!; wait $SP
"$H/cpu1multi.sh" & CP=$!; wait $CP
# a round counts when its "offline=0" line (cpu1 really offline) is followed by its "online=0-1" line
M=$(awk '$2 == "round" && $4 == "offline=0" && NF == 4 { off[$3] = 1 }
    $2 == "round" && $4 == "online=0-1" && NF == 4 && off[$3] { n++; off[$3] = 0 }
    END { print n + 0 }' cpu1multi-$B.log 2>/dev/null)
M=${M:-0}; log "cpu1 multi ok rounds: $M"
kill $(cat harvest.pid 2>/dev/null) $(cat monitor.pid 2>/dev/null) 2>/dev/null
kill $HP $MP 2>/dev/null
await_harvest
FINISHED=1
HB=$(grep -cE "MISMATCH|MOVED|ALERT" harvest.log 2>/dev/null)
# kernel errors fail the test; page allocation failures (a normal warning under memory pressure) are only counted
KB=$(grep -ciE "Out of memory|oom-kill|Bad page|Unable to handle|external abort" kernel-$B.log 2>/dev/null)
KA=$(grep -ci "allocation failure" kernel-$B.log 2>/dev/null)
HB=${HB:-0}; KB=${KB:-0}; KA=${KA:-0}
HELD=$(grep " HARVEST held=" harvest.log 2>/dev/null | tail -n 1 | sed -n 's/.* held=\([0-9]*\)\/.*/\1/p')
log "harvest: $(tail -n 1 harvest.log 2>/dev/null)"
log "harvest held pages: ${HELD:-none}"
log "harvest bad lines: $HB"
log "range: $(tail -n 1 monitor-$B.csv 2>/dev/null | cut -d, -f6,12-15)"
log "kernel bad: $KB"
log "kernel allocation failures (info): $KA"
log SUMMARY-DONE
# PASS: all 4 CPU1 rounds (1 early + 3 multi) came back online, nothing wrong in the harvester or the
# kernel log, and the harvester really held pages (a harvester that never ran must not pass)
R=PASS
[ $((E + M)) -ge 4 ] || R=FAIL
[ "$HB" -eq 0 ] || R=FAIL
[ "$KB" -eq 0 ] || R=FAIL
[ "${HELD:-0}" -gt 0 ] || R=FAIL
log "RESULT $R"
[ "$R" = PASS ]
