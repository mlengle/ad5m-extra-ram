#!/bin/sh
# Collect read-only data about the memory layout of an AD5M (any RAM size, any firmware) for extra-ram.
# Nothing on the printer is changed: the script writes only into /tmp (and, on zmod, a copy of the
# archive into /opt/config for download from Fluidd/Mainsail), mounts the boot-resource partition
# read-only and mounts debugfs if it is not mounted (as extra-ram itself does); both are unmounted again.
# Privacy: the live device tree is not copied (U-Boot writes bootargs into it), only its reservation
# table as text; in all text files MAC addresses and serial-number values (serial*=, snum=, sn=) are
# masked, and U-Boot variables whose names look like serial, MAC, key or password are masked.
# The archive still holds FlashForge files (sunxi.dtb, boot_package): send it privately.
#
# Usage on the printer (as root):  sh collect.sh
# Result: /tmp/xram-collect-<date>-<pid>.tar.gz

NAME=xram-collect-$(date +%Y%m%d-%H%M%S)-$$
D=/tmp/$NAME
OUT=/tmp/$NAME.tar.gz
MMC=/dev/mmcblk0
BOOTRES=/dev/mmcblk0p1
PKG_SECTORS="32800 24576"   # boot_package copies on firmware 3.1.5 (128 MB board)
MP=/tmp/xram-collect-mnt.$$
MP_MOUNTED=0
DBG_MOUNTED=0
DONE=0

# cleanup on any exit: unmount what we mounted, remove the work directory, and on failure the archive too
cleanup() {
    cd /tmp 2>/dev/null
    [ $MP_MOUNTED = 1 ] && umount "$MP" 2>/dev/null
    rmdir "$MP" 2>/dev/null
    [ $DBG_MOUNTED = 1 ] && umount /sys/kernel/debug 2>/dev/null
    rm -rf "$D"
    [ $DONE = 1 ] || rm -f "$OUT"
}
trap cleanup EXIT
trap 'echo "interrupted"; exit 1' INT TERM HUP

mkdir "$D" || { echo "cannot create $D"; exit 1; }
cd "$D" || exit 1

# run FILE CMD...: save the command, its output and errors into FILE (never stops the script)
run() {
    _f=$1; shift
    { echo "\$ $*"; "$@" 2>&1; echo "[exit $?]"; echo; } >> "$_f"
}
# cpy SRC DST: copy a file if it is readable
cpy() {
    [ -r "$1" ] && cat "$1" > "$2" 2>/dev/null
}
# rsvmap DTB: the /memreserve/ table of a flattened device tree as "0xaddr 0xsize" lines (as in lib.sh)
rsvmap() {
    _o=$(hexdump -s 16 -n 4 -ve '4/1 "%02x"' "$1" 2>/dev/null)
    [ -n "$_o" ] || { echo "cannot read $1"; return; }
    for _l in $(hexdump -s $((0x$_o)) -n 1024 -ve '16/1 "%02x" "\n"' "$1"); do
        [ "$_l" = "00000000000000000000000000000000" ] && break
        printf '0x%x 0x%x\n' $((0x$(echo $_l | cut -c1-16))) $((0x$(echo $_l | cut -c17-32)))
    done
}

echo "collecting into $D ..."

# --- system and memory ---
run system.txt date
run system.txt uname -a
run system.txt cat /proc/version
run system.txt cat /proc/cmdline
run system.txt cat /proc/cpuinfo
run system.txt cat /proc/partitions
run system.txt mount
run system.txt df -k
run system.txt uptime
for f in /etc/*version* /etc/*release* /opt/*version* /opt/PROGRAM/*version* /root/version; do
    [ -f "$f" ] && run system.txt cat "$f"
done
run system.txt ls -la /opt /opt/PROGRAM

run memory.txt free -k
run memory.txt cat /proc/meminfo
run memory.txt cat /proc/iomem
run memory.txt cat /proc/zoneinfo
run memory.txt cat /proc/buddyinfo

dmesg > dmesg.txt 2>&1

# --- device tree of the running kernel (no binary copy: /chosen/bootargs may hold a serial number) ---
{ echo "== /memreserve/ of /sys/firmware/fdt"; rsvmap /sys/firmware/fdt; echo; } >> devicetree.txt
for f in /proc/device-tree/model /proc/device-tree/compatible /proc/device-tree/memory*/reg \
         /proc/device-tree/reserved-memory/*/reg /proc/device-tree/reserved-memory/*/size; do
    [ -r "$f" ] && { echo "== $f"; hexdump -C "$f"; } >> devicetree.txt 2>&1
done
run devicetree.txt ls -R /proc/device-tree/reserved-memory

# --- memblock (debugfs) ---
if [ ! -r /sys/kernel/debug/memblock/reserved ]; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null && DBG_MOUNTED=1
fi
cpy /sys/kernel/debug/memblock/memory memblock-memory.txt
cpy /sys/kernel/debug/memblock/reserved memblock-reserved.txt
[ $DBG_MOUNTED = 1 ] && umount /sys/kernel/debug 2>/dev/null && DBG_MOUNTED=0

# --- boot-resource partition (sunxi.dtb), read-only; reuse an existing mount ---
_br=$(awk -v d="$BOOTRES" '$1 == d { print $2; exit }' /proc/mounts)
if [ -z "$_br" ]; then
    mkdir -p "$MP"
    # vfat does not mount without iocharset: the kernel has no default CP936
    if mount -t msdos -o ro "$BOOTRES" "$MP" 2>/dev/null || mount -t vfat -o ro,iocharset=utf8 "$BOOTRES" "$MP" 2>/dev/null; then
        MP_MOUNTED=1
        _br=$MP
    fi
fi
if [ -n "$_br" ]; then
    run bootres.txt ls -la "$_br"
    for f in "$_br"/*; do [ -f "$f" ] && run bootres.txt md5sum "$f"; done
    cpy "$_br/sunxi.dtb" sunxi.dtb
    { echo "== /memreserve/ of sunxi.dtb"; rsvmap sunxi.dtb; } >> bootres.txt
else
    echo "cannot mount $BOOTRES read-only" >> bootres.txt
fi
[ $MP_MOUNTED = 1 ] && umount "$MP" && MP_MOUNTED=0
rmdir "$MP" 2>/dev/null

# --- boot_package copies (4 MB each) ---
for s in $PKG_SECTORS; do
    dd if=$MMC bs=512 skip=$s count=8192 2>/dev/null > boot_package-$s.bin
    { printf 'sector %s magic: ' $s; head -c 13 boot_package-$s.bin | tr -d '\000'; echo; } >> boot_package.txt
done
# where "sunxi-package" headers are in the first 32 MB (in case this firmware puts them elsewhere)
echo "scanning the first 32 MB of eMMC for boot_package headers (about a minute) ..."
_s=0
while [ $_s -lt 65536 ]; do
    [ "$(dd if=$MMC bs=512 skip=$_s count=1 2>/dev/null | head -c 13 | tr -d '\000')" = "sunxi-package" ] &&
        echo "sunxi-package header at sector $_s" >> boot_package.txt
    _s=$((_s + 32))
done

# --- U-Boot environment (variables with sensitive names masked; values are masked below) ---
cpy /etc/fw_env.config fw_env.config
fw_printenv 2>&1 | awk -F= '{ n = tolower($1) }
    n ~ /serial|snum|(^|[_#.-])sn([_#.-]|$)|mac|ethaddr|uuid|key|pass|token|ssid|psk/ { print $1 "=<masked>"; next }
    { print }' > uboot-env.txt

# --- modifications: zmod, Forge-X, extra-ram ---
{
    echo "== zmod emmc.sh"; md5sum /usr/data/zmod/zmod/.shell/emmc.sh 2>&1
    echo "== zmod S99moon"; ls -la /etc/init.d/S99moon 2>&1
    echo "== zmod emmc state"; ls -la /opt/config/mod_data/emmc 2>&1; cat /opt/config/mod_data/emmc/state.txt 2>&1
    echo "== Forge-X"; ls -d /opt/config/mod/.shell 2>&1
    echo "== init scripts"; ls -la /etc/init.d 2>&1
    echo "== extra-ram"; ls -la /opt/extra-ram /etc/extra-ram 2>&1
    [ -x /opt/extra-ram/extra-ram ] && XRAM_LANG=en /opt/extra-ram/extra-ram check 2>&1
} > mods.txt

# --- mask MAC addresses and serial-number values in all text files (cmdline, dmesg, env, ...) ---
for f in *.txt; do
    sed -i -r \
        -e 's/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/xx:xx:xx:xx:xx:xx/g' \
        -e "s/([Ss][Ee][Rr][Ii][Aa][Ll][A-Za-z0-9_#]*=)[^ ;\"']*/\\1<masked>/g" \
        -e "s/([Ss][Nn][Uu][Mm][A-Za-z0-9_#]*=)[^ ;\"']*/\\1<masked>/g" \
        -e "s/(^|[^A-Za-z0-9])([Ss][Nn]=)[^ ;\"']*/\\1\\2<masked>/g" \
        -e 's/^(Serial[[:space:]]*:).*/\1 <masked>/' \
        "$f"
done

# --- archive (checked before the work directory is removed) ---
cd /tmp || exit 1
if ! { tar cf - "$NAME" | gzip > "$OUT"; } || ! gzip -dc "$OUT" | tar tf - > /dev/null 2>&1; then
    echo "FAILED to write $OUT (is /tmp full? df -k /tmp)"
    exit 1
fi
DONE=1
echo
echo "done: $OUT ($(wc -c < "$OUT") bytes)"
if [ -d /opt/config ]; then
    cp "$OUT" /opt/config/ && echo "copy: /opt/config/$NAME.tar.gz (Fluidd/Mainsail: Configuration files)"
fi
grep MemTotal /proc/meminfo
