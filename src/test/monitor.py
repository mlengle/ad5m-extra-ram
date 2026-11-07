#!/usr/bin/env python3
"""Every INTERVAL seconds append one CSV row with memory/swap stats, DSP
register values and occupancy of the former DSP range; mirror new kernel
lines from /var/log/messages (tmpfs) to persistent storage.

  monitor.py [--out DIR] [--interval S]
"""
import os, struct, sys, time

# Paths come from the environment (set by extra-ram test / selftest.sh), defaults are the printer's
ENV = os.environ.get
CMDLINE = ENV("XR_CMDLINE", "/proc/cmdline")
MEMINFO = ENV("XR_MEMINFO", "/proc/meminfo")
BOOTID = ENV("XR_BOOTID", "/proc/sys/kernel/random/boot_id")
MESSAGES = ENV("XR_MESSAGES", "/var/log/messages")
MARKERS = ("xram_on", "zmod_mem", "zmod_nodsp")      # cmdline markers of an active mode

LO, HI = 0x41900, 0x42110
args = sys.argv[1:]
OUT = args[args.index("--out") + 1] if "--out" in args else (ENV("XR_TESTDIR") or os.path.join(ENV("XR_STATE", "/etc/extra-ram"), "test"))
INTERVAL = int(args[args.index("--interval") + 1]) if "--interval" in args else 60
os.makedirs(OUT, exist_ok=True)

boot_id = open(BOOTID).read().strip()[:8]
nodsp = any(m in open(CMDLINE).read().split() for m in MARKERS)
csv_path = os.path.join(OUT, "monitor-%s.csv" % boot_id)
kern_path = os.path.join(OUT, "kernel-%s.log" % boot_id)
with open(os.path.join(OUT, "monitor.pid"), "w") as f:
    f.write(str(os.getpid()))

def meminfo():
    d = {}
    for line in open(MEMINFO):
        k, v = line.split(":")
        d[k] = int(v.split()[0])
    return d

def vmstat():
    return {k: int(v) for k, v in (l.split() for l in open("/proc/vmstat"))}

def dsp_reg(addr):
    try:
        with open("/sys/class/sunxi_dump/dump", "w") as f:
            f.write(addr)
        return open("/sys/class/sunxi_dump/dump").read().strip()
    except OSError as e:
        return "err%d" % e.errno

def range_occupancy():
    n = HI - LO
    with open("/proc/kpagecount", "rb") as f:
        f.seek(LO * 8)
        counts = struct.unpack("<%dQ" % n, f.read(n * 8))
    with open("/proc/kpageflags", "rb") as f:
        f.seek(LO * 8)
        flags = struct.unpack("<%dQ" % n, f.read(n * 8))
    used = sum(1 for c in counts if c)
    buddy = sum(1 for fl in flags if fl >> 10 & 1)
    reserved = sum(1 for fl in flags if fl >> 32 & 1)
    mlocked = sum(1 for fl in flags if fl >> 33 & 1)
    return used, buddy, reserved, mlocked

# kernel log mirror: follow /var/log/messages by inode+offset
kpos = {"ino": None, "off": 0}
def mirror_kernel():
    p = MESSAGES
    try:
        st = os.stat(p)
    except OSError:
        return 0
    if st.st_ino != kpos["ino"] or st.st_size < kpos["off"]:
        kpos["ino"], kpos["off"] = st.st_ino, 0
    with open(p, "rb") as f:
        f.seek(kpos["off"])
        data = f.read()
        kpos["off"] = f.tell()
    lines = [l for l in data.split(b"\n") if b" kernel: " in l]
    if lines:
        with open(kern_path, "ab") as k:
            k.write(b"\n".join(lines) + b"\n")
    return len(lines)

hdr = ("time,uptime,nodsp,MemTotal,MemFree,MemAvailable,Cached,SwapFree,"
       "d_pswpin,d_pswpout,d_pgmajfault,range_used,range_free,range_reserved,"
       "range_mlocked,DSP_CLK,DSP_BGR,kern_lines\n")
new = not os.path.exists(csv_path)
csv = open(csv_path, "a", buffering=1)
if new:
    csv.write(hdr)

prev = vmstat()
while True:
    m, v = meminfo(), vmstat()
    up = open("/proc/uptime").read().split()[0]
    used, buddy, res, mlk = range_occupancy()
    row = [time.strftime("%Y-%m-%d %H:%M:%S"), up, int(nodsp),
           m["MemTotal"], m["MemFree"], m["MemAvailable"], m["Cached"], m["SwapFree"],
           v["pswpin"] - prev["pswpin"], v["pswpout"] - prev["pswpout"],
           v["pgmajfault"] - prev["pgmajfault"],
           used, buddy, res, mlk,
           dsp_reg("0x02001c70"), dsp_reg("0x02001c7c"), mirror_kernel()]
    csv.write(",".join(map(str, row)) + "\n")
    prev = v
    time.sleep(INTERVAL)
