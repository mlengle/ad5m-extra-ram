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
: ${XR_S99MOON:=/etc/init.d/S99moon}   # zmod's init link (platform detection)
: ${XR_PROC:=/proc}                     # scanned for running commands
: ${XR_WAIT_STEP:=5}                   # poll interval of xr_zmod_wait, seconds (tests lower it)

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

# --- U-Boot variables (one-shot EXTRA_RAM boot) ---
# xr_bootcmd runs once: it restores the stock bootcmd and saves it first, so a hang or power cycle
# later returns to the stock boot; then it runs xram_main.
xr_bootcmd='setenv bootcmd run setargs_mmc boot_dsp0 boot_uImage;saveenv;run setargs_mmc xram_main'
# Scratch word for the crc32 result, inside the dtb gap below the dtb load address (0x44864e70)
XR_SCRATCH=0x44864e00
# xram_main: load, compute the dtb CRC into xram_crc (mw.l first: crc32 must not leave stale data),
# select xram_del when it matches the verified CRC, xram_skip otherwise (data-driven: no failing
# commands, no hangs on the logo screen)
XR_MAIN_PRE='part list mmc 0;fatload mmc 0:1 0x43000000 uImage;fatload mmc 0:1 0x44864e70 sunxi.dtb;setenv xram_sel xram_skip;setenv xram_crc none;mw.l '"$XR_SCRATCH"' 0;crc32 0x44864e70 ${filesize} '"$XR_SCRATCH"';setexpr.l xram_crc *'"$XR_SCRATCH"';setexpr xram_sel sub ^'
XR_MAIN_POST='$ xram_del ${xram_crc};run xram_boot'
XR_DEL='fdt rsvmem delete 3;fdt rsvmem delete 2;fdt rsvmem delete 1;fdt rsvmem delete 0;fdt rsvmem add 0x41b00000 0x100000;setenv bootargs ${bootargs} xram_on'
XR_SKIP='setenv bootargs ${bootargs} xram_skip'
XR_BOOTM='run ${xram_sel};bootm 0x43000000 - 0x44864e70;run setargs_mmc boot_uImage'

# xr_getenv NAME: value of a U-Boot variable (empty if not defined)
xr_getenv() {
    fw_printenv -n "$1" 2>/dev/null
}

# xr_env_values CRC EMMC_EDITS: set XV_MAIN, XV_BOOT, XV_DEL, XV_SKIP (the values of xram_main,
# xram_boot, xram_del, xram_skip). EMMC_EDITS may be empty.
xr_env_values() {
    XV_MAIN="${XR_MAIN_PRE}$1${XR_MAIN_POST}"
    XV_BOOT="fdt addr 0x44864e70;fdt resize;${2:+$2;}${XR_BOOTM}"
    XV_DEL=$XR_DEL
    XV_SKIP=$XR_SKIP
}

# xr_env_write NAME VALUE ...: write the variables with a single environment write (fw_setenv -s);
# an empty value deletes the variable
xr_env_write() {
    _xr_ef=$XR_TMP/xram_env.$$
    : > $_xr_ef
    while [ $# -ge 2 ]; do
        printf '%s %s\n' "$1" "$2" >> $_xr_ef
        shift 2
    done
    fw_setenv -s $_xr_ef
    _xr_rc=$?
    rm -f $_xr_ef
    return $_xr_rc
}

# xr_arm EMMC_EDITS: arm the one-shot boot (needs XR_CRC from xr_fw_check; without it nothing is
# written). The four variables and bootcmd go in one write with bootcmd last; everything is read back
# and $XR_STATE/armed is created. On any failure after the write attempt, bootcmd is rolled back: to
# the value it had before when that was the stock or zmod's armed one (so zmod's own one-shot boot
# is not disturbed), otherwise to the stock bootcmd; armed is removed and 1 is returned.
xr_arm() {
    rm -f "$XR_STATE/armed"
    [ -n "$XR_CRC" ] || return 1
    _xr_bc0=$(xr_getenv bootcmd)
    xr_env_values "$XR_CRC" "$1"
    if xr_env_write xram_main "$XV_MAIN" xram_boot "$XV_BOOT" xram_del "$XV_DEL" xram_skip "$XV_SKIP" bootcmd "$xr_bootcmd" &&
        [ "$(xr_getenv xram_main)" = "$XV_MAIN" ] && [ "$(xr_getenv xram_boot)" = "$XV_BOOT" ] &&
        [ "$(xr_getenv xram_del)" = "$XV_DEL" ] && [ "$(xr_getenv xram_skip)" = "$XV_SKIP" ] &&
        [ "$(xr_getenv bootcmd)" = "$xr_bootcmd" ] &&
        mkdir -p "$XR_STATE" 2>/dev/null && touch "$XR_STATE/armed" 2>/dev/null; then
        sync
        return 0
    fi
    rm -f "$XR_STATE/armed"
    if [ "$(xr_getenv bootcmd)" != "$_xr_bc0" ]; then
        if [ "$_xr_bc0" = "$STOCK_BOOTCMD" ] || [ "$_xr_bc0" = "$ARMED_BOOTCMD" ]; then
            fw_setenv bootcmd "$_xr_bc0"
        else
            fw_setenv bootcmd "$STOCK_BOOTCMD"
        fi
    fi
    return 1
}

# xr_disarm [ZMOD_REARM]: remove armed; if bootcmd is ours restore it: zmod's armed bootcmd when
# ZMOD_REARM=1 (zmod's own one-shot boot continues), else the stock one
xr_disarm() {
    rm -f "$XR_STATE/armed"
    sync
    if [ "$(xr_getenv bootcmd)" = "$xr_bootcmd" ]; then
        if [ "$1" = 1 ]; then
            fw_setenv bootcmd "$ARMED_BOOTCMD"
        else
            fw_setenv bootcmd "$STOCK_BOOTCMD"
        fi
    fi
    return 0
}

# xr_env_remove: delete every xram_* variable (including the runtime-only ones) in one write
xr_env_remove() {
    _xr_names=$(fw_printenv 2>/dev/null | sed -n 's/^\(xram_[A-Za-z0-9_]*\)=.*/\1/p')
    [ -n "$_xr_names" ] || return 0
    set --
    for _xr_n in $_xr_names; do
        set -- "$@" "$_xr_n" ""
    done
    xr_env_write "$@"
}

# --- platform detection and zmod eMMC adapter (zmod files and its U-Boot variables are read-only for us) ---

# xr_platform: print zmod, forgex or stock
xr_platform() {
    if [ -e "$XR_ZMOD_SH" ]; then echo zmod; return 0; fi
    _xr_l=$(readlink "$XR_S99MOON" 2>/dev/null)
    case "$_xr_l" in /usr/data/zmod*) echo zmod; return 0 ;; esac
    if [ -e "$XR_FORGEX" ]; then echo forgex; return 0; fi
    echo stock
}

# xr_zmod_state: set ZM_STATE (state.txt or none), ZM_DDR, ZM_DISABLE (0|1) and ZM_MARK (zmod_emmc_ddr,
# zmod_emmc_50 or none, from the kernel cmdline). Read-only.
xr_zmod_state() {
    ZM_STATE=""
    [ -f "$XR_ZMOD_EMMC/state.txt" ] && read -r ZM_STATE < "$XR_ZMOD_EMMC/state.txt"
    [ -n "$ZM_STATE" ] || ZM_STATE=none
    ZM_DDR=0; [ -f "$XR_ZMOD_EMMC/ddr.txt" ] && ZM_DDR=1
    ZM_DISABLE=0; [ -f "$XR_ZMOD_EMMC/disable.txt" ] && ZM_DISABLE=1
    ZM_MARK=none
    if grep -qw zmod_emmc_ddr "$XR_CMDLINE" 2>/dev/null; then ZM_MARK=zmod_emmc_ddr
    elif grep -qw zmod_emmc_50 "$XR_CMDLINE" 2>/dev/null; then ZM_MARK=zmod_emmc_50
    fi
}

# xr_zmod_edits: decide the eMMC edits for arming on zmod, from bootcmd and boot_zmod (U-Boot decides, not
# ddr.txt). Prints the edits (possibly none) and sets XR_EDITS; returns 0. Returns 1 with XR_REASON set when
# arming must not happen. Call it without a command substitution (xr_zmod_edits >/dev/null) when XR_REASON
# is needed: a subshell loses the variables.
xr_zmod_edits() {
    XR_EDITS=""; XR_REASON=""
    xr_zmod_state
    _xr_bc=$(xr_getenv bootcmd)
    if [ "$_xr_bc" = "$ARMED_BOOTCMD" ]; then
        if [ "$ZM_STATE" != ok ]; then XR_REASON=zmod_emmc_testing; return 1; fi
        _xr_bz=$(xr_getenv boot_zmod)
        if [ "$_xr_bz" = "$BOOT_ZMOD_B" ]; then XR_EDITS=$EMMC_FDT
        elif [ "$_xr_bz" = "$BOOT_ZMOD_B_DDR" ]; then XR_EDITS=$EMMC_FDT_DDR
        else XR_REASON=zmod_unknown_boot_zmod; return 1
        fi
        printf '%s\n' "$XR_EDITS"
        return 0
    fi
    if [ "$_xr_bc" = "$STOCK_BOOTCMD" ]; then echo; return 0; fi
    if [ "$_xr_bc" = "$xr_bootcmd" ]; then XR_REASON=already_armed; return 1; fi
    XR_REASON=unknown_bootcmd
    return 1
}

# xr_zmod_running: succeeds when some process has emmc.sh as a command-line argument (own shell excluded)
xr_zmod_running() {
    for _xr_p in "$XR_PROC"/[0-9]*; do
        _xr_n=${_xr_p##*/}
        [ "$_xr_n" = "$$" ] && continue
        [ -r "$_xr_p/cmdline" ] || continue
        _xr_c=$(tr '\0' ' ' < "$_xr_p/cmdline" 2>/dev/null)
        case " $_xr_c" in *" emmc.sh "*|*"/emmc.sh "*) return 0 ;; esac
    done
    return 1
}

# xr_zmod_wait [TIMEOUT]: wait (default 900 s, poll every XR_WAIT_STEP s) until zmod's emmc.sh has finished
# this boot: boot_id.txt equals the current boot id AND no emmc.sh process is left (boot_id.txt is written
# early in the run, before arming). Returns 0 at once without zmod; 1 on timeout.
xr_zmod_wait() {
    [ -e "$XR_ZMOD_SH" ] || return 0
    _xr_to=${1:-900}; _xr_el=0; _xr_st=$XR_WAIT_STEP
    case "$_xr_to" in ""|*[!0-9]*) _xr_to=900 ;; esac
    case "$_xr_st" in ''|*[!0-9]*|0) _xr_st=5 ;; esac
    while :; do
        _xr_cur=$(cat "$XR_BOOTID" 2>/dev/null)
        _xr_seen=""; [ -f "$XR_ZMOD_EMMC/boot_id.txt" ] && read -r _xr_seen < "$XR_ZMOD_EMMC/boot_id.txt"
        if [ -n "$_xr_cur" ] && [ "$_xr_seen" = "$_xr_cur" ] && ! xr_zmod_running; then return 0; fi
        [ "$_xr_el" -ge "$_xr_to" ] && return 1
        sleep "$_xr_st"
        _xr_el=$((_xr_el + _xr_st))
    done
}
