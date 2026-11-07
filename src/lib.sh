# extra-ram library: constants and pure functions, sourced by everything (busybox ash compatible).
# Every path is a variable that may be preset in the environment (the test harness does that).

# --- paths ---
: ${XR_CODE:=/opt/extra-ram}
: ${XR_STATE:=/etc/extra-ram}
: ${XR_INIT:=/etc/init.d/S45xram}
: ${XR_CMDLINE:=/proc/cmdline}
: ${XR_FDT:=/sys/firmware/fdt}
: ${XR_MEMBLOCK:=/sys/kernel/debug/memblock/reserved}
: ${XR_MEMINFO:=/proc/meminfo}
: ${XR_BOOTID:=/proc/sys/kernel/random/boot_id}
: ${XR_MMC:=/dev/mmcblk0}
: ${XR_BOOTRES:=/dev/mmcblk0p1}
: ${XR_TMP:=/tmp}
: ${XR_ZMOD_SH:=/usr/data/zmod/zmod/.shell/emmc.sh}
: ${XR_ZMOD_EMMC:=/opt/config/mod_data/emmc}
: ${XR_ZMOD_LANG:=/opt/config/mod_data/lang.cfg}
: ${XR_FORGEX:=/opt/config/mod/.shell}
: ${XR_MOONRAKER:=http://127.0.0.1:7125}

# --- verified firmware list: "dtb-md5 CRC optee-md5" triplets (firmware 3.1.5) ---
# CRC is the crc32 of sunxi.dtb as the printer's U-Boot prints it; the OP-TEE md5 is required in both
# boot_package copies (sectors in XR_PKG_SECTORS).
XR_KNOWN='c4aabbae50d6f56c8db2109804456ed2 e82291d2 5ed6ffabbadb9926c7d44a9b4b833683'
XR_PKG_SECTORS="32800 24576"

# --- zmod 1.7 strings (.shell/emmc.sh of branch 1.7), copied verbatim ---
STOCK_BOOTCMD='run setargs_mmc boot_dsp0 boot_uImage'
ARMED_BOOTCMD='setenv bootcmd run setargs_mmc boot_dsp0 boot_uImage;saveenv;run setargs_mmc boot_dsp0 boot_zmod'
EMMC_FDT='fdt rm /soc@3000000/sdmmc@4020000 mmc-hs200-1_8v;fdt rm /soc@3000000/sdmmc@4020000 mmc-ddr-1_8v;fdt set /soc@3000000/sdmmc@4020000 max-frequency <0x2faf080>;setenv bootargs ${bootargs} zmod_emmc_50'
BOOT_ZMOD_B="part list mmc 0;fatload mmc 0:1 0x43000000 uImage;fatload mmc 0:1 0x44864e70 sunxi.dtb;fdt addr 0x44864e70;fdt resize;${EMMC_FDT};bootm 0x43000000 - 0x44864e70"
EMMC_FDT_DDR='fdt rm /soc@3000000/sdmmc@4020000 mmc-hs200-1_8v;fdt set /soc@3000000/sdmmc@4020000 max-frequency <0x2faf080>;setenv bootargs ${bootargs} zmod_emmc_ddr'
BOOT_ZMOD_B_DDR="part list mmc 0;fatload mmc 0:1 0x43000000 uImage;fatload mmc 0:1 0x44864e70 sunxi.dtb;fdt addr 0x44864e70;fdt resize;${EMMC_FDT_DDR};bootm 0x43000000 - 0x44864e70"
BOOT_UIMAGE='part list mmc 0;fatload mmc 0:1 0x43000000 uImage;fatload mmc 0:1 0x44864e70 sunxi.dtb;fdt resize;bootm 0x43000000 - 0x44864e70'

# --- messages ---
# xr_msg RU EN: print the message in the selected language (XRAM_LANG=ru|en, else zmod's lang.cfg, else English)
xr_msg() {
    case "$XRAM_LANG" in
    ru) echo "$1"; return ;;
    en) echo "$2"; return ;;
    esac
    if [ -f "$XR_ZMOD_LANG" ] && grep -q "language: ru" "$XR_ZMOD_LANG" 2>/dev/null; then
        echo "$1"
    else
        echo "$2"
    fi
}

# xr_log RU EN: append the message with a timestamp to $XR_STATE/extra-ram.log (rotated at 64 KB)
xr_log() {
    mkdir -p "$XR_STATE" 2>/dev/null
    _xr_lf=$XR_STATE/extra-ram.log
    if [ -f "$_xr_lf" ] && [ "$(wc -c < "$_xr_lf")" -gt 65536 ]; then
        mv -f "$_xr_lf" "$_xr_lf.1"
    fi
    printf '%s %s\n' "$(date '+%F %T')" "$(xr_msg "$1" "$2")" >> "$_xr_lf" 2>/dev/null
}

# --- memory and firmware ---
# MemTotal in kB
xr_mem_total() {
    while read -r _xr_k _xr_v _xr_u; do
        if [ "$_xr_k" = "MemTotal:" ]; then
            echo "$_xr_v"
            return
        fi
    done < "$XR_MEMINFO"
}

# /memreserve/ entries of the dtb file $1 as " 0xaddr/0xsize" list
xr_rsvmap() {
    _xr_off=$(hexdump -s 16 -n 4 -ve '4/1 "%02x"' "$1" 2>/dev/null)
    [ -n "$_xr_off" ] || return
    for _xr_l in $(hexdump -s $((0x$_xr_off)) -n 512 -ve '16/1 "%02x" "\n"' "$1"); do
        [ "$_xr_l" = "00000000000000000000000000000000" ] && break
        printf ' 0x%x/0x%x' $((0x$(echo $_xr_l | cut -c1-16))) $((0x$(echo $_xr_l | cut -c17-32)))
    done
}

# md5 of the OP-TEE image in the boot_package copy at sector $1 of $XR_MMC; empty if not found
xr_optee_md5() {
    _xr_h=$XR_TMP/xram_pkg.$$
    dd if="$XR_MMC" bs=512 skip=$1 count=4 2>/dev/null > $_xr_h
    if [ "$(head -c 13 $_xr_h | tr -d '\000')" = "sunxi-package" ]; then
        _xr_n=$(hexdump -s 32 -n 4 -e '1/4 "%u"' $_xr_h)
        _xr_i=0
        while [ $_xr_i -lt "${_xr_n:-0}" ] && [ $_xr_i -lt 5 ]; do
            _xr_o=$((64 + _xr_i * 368))
            if [ "$(dd if=$_xr_h bs=1 skip=$_xr_o count=16 2>/dev/null | tr -d '\000')" = "optee" ]; then
                _xr_off=$(hexdump -s $((_xr_o + 64)) -n 4 -e '1/4 "%u"' $_xr_h)
                _xr_len=$(hexdump -s $((_xr_o + 68)) -n 4 -e '1/4 "%u"' $_xr_h)
                if [ $((_xr_off % 512)) -eq 0 ] && [ "$_xr_len" -gt 0 ] && [ "$_xr_len" -lt 4194304 ]; then
                    dd if="$XR_MMC" bs=512 skip=$(($1 + _xr_off / 512)) count=$(((_xr_len + 511) / 512)) 2>/dev/null | head -c $_xr_len | md5sum | cut -d' ' -f1
                fi
                break
            fi
            _xr_i=$((_xr_i + 1))
        done
    fi
    rm -f $_xr_h
}

# Is the firmware in the verified list: sunxi.dtb on boot-resource and OP-TEE in both boot_package copies.
# Sets XR_FW=ok|bad, XR_CRC (the CRC for the U-Boot check, only when ok) and XR_FWINFO (details for the log).
XR_FW=""
XR_CRC=""
XR_FWINFO=""
xr_fw_check() {
    XR_FW=bad
    XR_CRC=""
    _xr_dtb=none
    _xr_rsv=""
    _xr_mp=$XR_TMP/xram_bootres.$$
    mkdir -p $_xr_mp
    # vfat does not mount without iocharset: the kernel has no default CP936
    if mount -t msdos -o ro "$XR_BOOTRES" $_xr_mp 2>/dev/null || mount -t vfat -o ro,iocharset=utf8 "$XR_BOOTRES" $_xr_mp 2>/dev/null; then
        if [ -f $_xr_mp/sunxi.dtb ]; then
            _xr_dtb=$(md5sum < $_xr_mp/sunxi.dtb | cut -d' ' -f1)
            _xr_rsv=$(xr_rsvmap $_xr_mp/sunxi.dtb)
        fi
        umount $_xr_mp
    fi
    rmdir $_xr_mp 2>/dev/null
    _xr_tee=""
    for _xr_sec in $XR_PKG_SECTORS; do
        _xr_tee="$_xr_tee $(xr_optee_md5 $_xr_sec)"
    done
    _xr_tee=${_xr_tee# }
    XR_FWINFO="dtb=$_xr_dtb optee=$_xr_tee memreserve:$_xr_rsv"
    set -- $XR_KNOWN
    while [ $# -ge 3 ]; do
        if [ "$_xr_dtb" = "$1" ] && [ "$_xr_tee" = "$3 $3" ]; then
            XR_FW=ok
            XR_CRC=$2
            return
        fi
        shift 3
    done
}
