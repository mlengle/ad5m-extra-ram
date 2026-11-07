#!/usr/bin/env python3
"""Page harvester: grab physical pages from the former DSP memreserve range,
fill them with a PFN-keyed pattern, mlock them and periodically verify.

Holds at most RANGE pages (~8 MB). Pages outside the range are unmapped
immediately, so transient overhead is one chunk.

  harvest.py [--out DIR] [--chunk KB] [--rounds N] [--interval S]
             [--min-avail KB] [--control]

--control: harvest a fixed budget, report how many in-range pages were
obtained, exit (on a normal DSP boot the expected answer is 0).
SIGUSR1: verify now.  SIGTERM/SIGINT: final verify, exit.
"""
import ctypes, hashlib, os, random, signal, struct, sys, time

# Paths come from the environment (set by extra-ram test / selftest.sh), defaults are the printer's
ENV = os.environ.get
CMDLINE = ENV("XR_CMDLINE", "/proc/cmdline")
MEMINFO = ENV("XR_MEMINFO", "/proc/meminfo")
MARKERS = ("xram_on", "zmod_mem", "zmod_nodsp")      # cmdline markers of an active mode

PAGE = 4096
LO, HI = 0x41900, 0x42110          # PFN range [LO, HI), 2064 pages
TEE_LO, TEE_HI = 0x41B00, 0x41C00  # OP-TEE TEE_RAM, must stay reserved
RANGE = HI - LO - (TEE_HI - TEE_LO)

args = sys.argv[1:]
def opt(name, default, conv=str):
    if name in args:
        return conv(args[args.index(name) + 1])
    return default
OUT = opt("--out", ENV("XR_TESTDIR") or os.path.join(ENV("XR_STATE", "/etc/extra-ram"), "test"))
CHUNK = opt("--chunk", 1024, int) * 1024
ROUNDS = opt("--rounds", 8, int)
INTERVAL = opt("--interval", 120, int)
MIN_AVAIL = opt("--min-avail", 14000, int)
CONTROL = "--control" in args

libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
for f in ("munmap", "mlock", "munlock"):
    getattr(libc, f).argtypes = [ctypes.c_void_p, ctypes.c_size_t]
MAP_FAILED = ctypes.c_void_p(-1).value

os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "control.log" if CONTROL else "harvest.log"), "a", buffering=1)
def log(msg):
    LOG.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))

SEED = random.getrandbits(32)
def pattern(pfn):
    return hashlib.sha256(b"%d:%d" % (SEED, pfn)).digest() * (PAGE // 32)

pagemap = open("/proc/self/pagemap", "rb", buffering=0)
def pfns(addr, n):
    pagemap.seek(addr // PAGE * 8)
    raw = pagemap.read(n * 8)
    out = []
    for (e,) in struct.iter_unpack("<Q", raw):
        out.append(e & ((1 << 55) - 1) if e >> 63 else None)
    return out

def meminfo(key):
    with open(MEMINFO) as f:
        for line in f:
            if line.startswith(key + ":"):
                return int(line.split()[1])
    return 0

held = {}        # addr -> pfn
stats = dict(rounds=0, seen_in_range=0, mismatches=0, moved=0, verifies=0)

def harvest_round():
    n = CHUNK // PAGE
    base = libc.mmap(None, CHUNK, 3, 0x22, -1, 0)
    if base in (None, MAP_FAILED):
        log("mmap failed errno=%d" % ctypes.get_errno())
        return 0
    zero = b"\0"
    for i in range(n):                         # fault every page in
        ctypes.memmove(base + i * PAGE, zero, 1)
    got = 0
    for i, pfn in enumerate(pfns(base, n)):
        a = base + i * PAGE
        if pfn is not None and TEE_LO <= pfn < TEE_HI:
            log("ALERT got TEE_RAM page pfn=%#x (reservation not effective!)" % pfn)
        if pfn is not None and LO <= pfn < HI and not TEE_LO <= pfn < TEE_HI and len(held) < RANGE:
            ctypes.memmove(a, pattern(pfn), PAGE)
            if libc.mlock(a, PAGE) != 0:
                log("mlock failed errno=%d" % ctypes.get_errno())
            held[a] = pfn
            got += 1
        else:
            libc.munmap(a, PAGE)
    stats["rounds"] += 1
    stats["seen_in_range"] += got
    return got

def release(a):
    libc.munlock(a, PAGE)
    libc.munmap(a, PAGE)
    del held[a]

def verify(tag="periodic"):
    stats["verifies"] += 1
    bad = moved = 0
    for a, pfn in list(held.items()):
        now = pfns(a, 1)[0]
        if now != pfn:
            moved += 1
            log("MOVED vaddr=%#x pfn %#x -> %s" % (a, pfn, hex(now) if now else "not-present"))
            release(a)
            continue
        data = ctypes.string_at(a, PAGE)
        exp = pattern(pfn)
        if data != exp:
            bad += 1
            diffs = [i for i in range(PAGE) if data[i] != exp[i]]
            off = diffs[0] & ~31
            log("MISMATCH pfn=%#x phys=%#x bytes_differ=%d first_off=%#x got=%s exp=%s"
                % (pfn, pfn * PAGE, len(diffs), diffs[0],
                   data[off:off + 32].hex(), exp[off:off + 32].hex()))
            ctypes.memmove(a, exp, PAGE)       # rearm so new hits are visible
    stats["mismatches"] += bad
    stats["moved"] += moved
    log("VERIFY %s held=%d bad=%d moved=%d | total mismatches=%d moved=%d"
        % (tag, len(held), bad, moved, stats["mismatches"], stats["moved"]))

if CONTROL:
    budget = opt("--budget", 64, int)
    for _ in range(budget):
        if meminfo("MemAvailable") < MIN_AVAIL:
            break
        harvest_round()
    log("CONTROL rounds=%d chunk=%dK in_range=%d" % (stats["rounds"], CHUNK // 1024, len(held)))
    print("in_range_pages=%d rounds=%d" % (len(held), stats["rounds"]))
    sys.exit(0)

flags = {"verify": False, "stop": False}
signal.signal(signal.SIGUSR1, lambda *_: flags.__setitem__("verify", True))
signal.signal(signal.SIGTERM, lambda *_: flags.__setitem__("stop", True))
signal.signal(signal.SIGINT, lambda *_: flags.__setitem__("stop", True))

with open(os.path.join(OUT, "harvest.pid"), "w") as f:
    f.write(str(os.getpid()))
cmd = open(CMDLINE).read()
log("START pid=%d seed=%#x nodsp=%s chunk=%dK rounds=%d interval=%ds min_avail=%dK"
    % (os.getpid(), SEED, any(m in cmd.split() for m in MARKERS), CHUNK // 1024, ROUNDS, INTERVAL, MIN_AVAIL))

while not flags["stop"]:
    new = 0
    if len(held) < RANGE:
        for _ in range(ROUNDS):
            if meminfo("MemAvailable") < MIN_AVAIL or len(held) >= RANGE:
                break
            new += harvest_round()
    log("HARVEST held=%d/%d new=%d rounds_total=%d avail=%dK"
        % (len(held), RANGE, new, stats["rounds"], meminfo("MemAvailable")))
    verify()
    t = time.time()
    while time.time() - t < INTERVAL and not flags["stop"]:
        if flags["verify"]:
            flags["verify"] = False
            verify("on-demand")
        time.sleep(1)

verify("final")
log("STOP held=%d mismatches=%d moved=%d" % (len(held), stats["mismatches"], stats["moved"]))
