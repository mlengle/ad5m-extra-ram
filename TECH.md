# extra-ram: technical notes

How the reserved memory of the FlashForge AD5M (Allwinner R528 / sun8iw20; 128 MB board with stock firmware 3.1.5, 256 MB board with 3.1.9) is laid out, and the exact commands extra-ram uses to free it. For users see [README.md](README.md) / [README.ru.md](README.ru.md).

## 1. The reserved range

U-Boot passes `sunxi.dtb` (boot-resource partition, `mmc 0:1`) to the kernel. Its `/memreserve/` table (the FDT header block, not `/reserved-memory` nodes) has four entries:

| # | Address | Size | Owner |
|---|---|---|---|
| 0 | `0x41900000` | 1 MB | OP-TEE NSEC_SHM (first part; overlapped by entry 1) |
| 1 | `0x41900000` | 7 MB | OP-TEE 3.7 carve-out: NSEC_SHM 2 MB, TEE_RAM 1 MB, TA_RAM 4 MB |
| 2 | `0x42000000` | 1 MB | DSP0 firmware |
| 3 | `0x42100000` | 64 KB | DSP `share_space` |

Together: `0x41900000–0x4210FFFF`, 8256 KB.

OP-TEE layout (from the OP-TEE image tables in `boot_package`):

| Region | Address | Size | Used on the printer |
|---|---|---|---|
| NSEC_SHM | `0x41900000` | 2 MB | no: the kernel has no OP-TEE driver, nothing talks to the TEE |
| **TEE_RAM** | `0x41B00000` | 1 MB | **yes**: OP-TEE code `0x49000`, data and stack `0xB7000`; the PSCI handlers live here |
| TA_RAM | `0x41C00000` | 4 MB | no: no trusted applications are loaded |

The DSP is started by the stock `bootcmd` (`run setargs_mmc boot_dsp0 boot_uImage`, where `boot_dsp0` = `sunxi_flash read 43000000 ${dsp0_partition};bootr 43000000 0 0`). Linux does not use it: sound goes through Linux itself, and the DSP clock/bus-gate registers read 0 even on a stock boot.

**Why TEE_RAM must stay reserved.** Linux uses PSCI (secure monitor calls into OP-TEE) for `CPU_OFF`/`CPU_ON` and for reboot/poweroff. Freeing all 8 MB lets the page allocator overwrite TEE_RAM, and the first PSCI call (taking `cpu1` offline, reboot) hangs the SoC. With TEE_RAM kept, `cpu1` hotplug, reboots and a one-hour print were verified on the printer.

Result: 8256 − 1024 = **7232 KB** freed.

| Board | `MemTotal` stock | `MemTotal` with the mode |
|---|---|---|
| 128 MB (3.1.5) | 110404 kB | 117636 kB (measured) |
| 256 MB (3.1.9) | 240352 kB (computed: 247584 − 7232) | 247584 kB (measured, zmod's own mode, §6) |

## 2. The one-shot U-Boot boot

Vendor U-Boot 2018.05 without hush has no `if`, and a failed `run` aborts the rest of `bootcmd` (the printer then sits on the logo). So selection is done with data, never with a command that can fail. extra-ram writes five variables in one `fw_setenv -s` call, `bootcmd` last:

```
bootcmd   = setenv bootcmd run setargs_mmc boot_dsp0 boot_uImage;saveenv;run setargs_mmc xram_main
xram_main = part list mmc 0;fatload mmc 0:1 0x43000000 uImage;fatload mmc 0:1 0x44864e70 sunxi.dtb;
            setenv xram_sel xram_skip;setenv xram_crc none;
            mw.l 0x44864e00 0;crc32 0x44864e70 ${filesize} 0x44864e00;setexpr.l xram_crc *0x44864e00;
            setexpr xram_sel sub ^e82291d2$ xram_del ${xram_crc};
            run xram_boot
xram_boot = fdt addr 0x44864e70;fdt resize;<zmod eMMC edits, if any>;
            run ${xram_sel};bootm 0x43000000 - 0x44864e70;run setargs_mmc boot_uImage
xram_del  = fdt rsvmem delete 3;fdt rsvmem delete 2;fdt rsvmem delete 1;fdt rsvmem delete 0;
            fdt rsvmem add 0x41b00000 0x100000;setenv bootargs ${bootargs} xram_on
xram_skip = setenv bootargs ${bootargs} xram_skip
```

(Line breaks added for reading; the stored values are single lines.)

Step by step:

1. **One-shot.** `bootcmd` first restores the stock `bootcmd` and saves the environment. Whatever happens next (hang, power cycle), the following boot is a stock one.
2. **No DSP.** `boot_dsp0` is not run, so the DSP firmware is not loaded into `0x42000000`.
3. **CRC gate.** `crc32` of the loaded `sunxi.dtb` goes to a scratch word in the gap below the dtb (`0x44864e00`, cleared first). `setexpr.l` reads it into `xram_crc`. The printer's U-Boot prints it as plain hex without leading zeros (`e82291d2`). `setexpr … sub` turns `xram_sel` into `xram_del` only on an exact match; otherwise it stays `xram_skip`. No command fails on a mismatch.
4. **Edit.** `xram_del` deletes the four entries (highest index first, so indices do not shift), adds back TEE_RAM only, and appends the marker `xram_on` to the kernel command line. `xram_skip` only appends `xram_skip`.
5. **Boot.** `bootm` with the edited dtb. If `bootm` returns, the stock `boot_uImage` runs as a fallback.

On zmod with eMMC 50 MHz / DDR52 enabled, `xram_boot` also carries zmod's own `fdt rm` / `fdt set … max-frequency` edits and its `zmod_emmc_50` / `zmod_emmc_ddr` marker, copied verbatim from `boot_zmod`. That way zmod sees a successful 50 MHz boot. Only exact `boot_zmod` strings from the table `XR_ZMOD_KNOWN` in `src/lib.sh` are accepted.

## 3. Linux side

`/etc/init.d/S45xram` → `extra-ram boot` (synchronous, early):

- **Safety check.** It runs on every boot with `xram_on`, before anything else. TEE_RAM is checked in two sources:
  - `/sys/firmware/fdt` (`/memreserve/` must contain `0x41b00000/0x100000`, and no other entry may overlap the old range `0x41900000–0x4210FFFF`; entries outside it are U-Boot's own, see §5);
  - `/sys/kernel/debug/memblock/reserved` (a range must cover `0x41b00000–0x41bfffff`).

  If either source shows it missing, the hook writes the stock `bootcmd`, disables the mode and reboots (`reboot`, then `reboot -f`).
- **Accounting.**
  - `xram_on`: the boot is counted as successful.
  - `xram_skip`: `sunxi.dtb` changed, a normal boot, not a failure.
  - Armed but no marker: the boot did not reach the system. 2 such boots in a row disable the mode.
- **Re-arming** runs in the background (`extra-ram arm-wait`). It waits until zmod's `emmc.sh` has finished in this boot (zmod rewrites `bootcmd`) and until uptime ≥ 180 s, so a boot that hangs early leaves the stock `bootcmd`. It then re-checks the firmware: `sunxi.dtb` md5 and CRC, and the OP-TEE md5 in both `boot_package` copies (sectors 32800 and 24576). Only after that does it write the variables again.

Freed pages can be seen in `/sys/kernel/debug/memblock/reserved`: the range `0x41900000–0x4210ffff` is gone, only `0x41b00000–0x41bfffff` remains. `extra-ram test` allocates physical pages from the freed range (via `/proc/self/pagemap`) and checks that their contents stay intact and they do not move. It also cycles `cpu1` offline/online to exercise PSCI.

## 4. Commands at a glance

| Action | Command (run by extra-ram) |
|---|---|
| read state | `fw_printenv -n bootcmd`, `fw_printenv -n boot_zmod` |
| arm | `fw_setenv -s <file>` with `xram_main`, `xram_boot`, `xram_del`, `xram_skip`, `bootcmd` |
| disarm | `fw_setenv bootcmd 'run setargs_mmc boot_dsp0 boot_uImage'`, or zmod's armed `bootcmd` when its `boot_zmod` is known |
| uninstall | disarm, read `bootcmd` back, then `fw_setenv -s` deleting every `xram_*` variable |
| verify (Linux) | `/proc/cmdline`, `/sys/firmware/fdt`, `/sys/kernel/debug/memblock/reserved`, `/proc/meminfo` |
| firmware check | mount boot-resource read-only, `md5sum sunxi.dtb`, OP-TEE md5 from `boot_package` on `/dev/mmcblk0` |
| zmod's own mode (§6) | `grep zmod_xram_on` in zmod's `emmc.sh` and `/proc/cmdline`, `fdt rsvmem` in `fw_printenv -n boot_zmod`; read `xr_state.txt`, `disable_extra_ram.txt` |

zmod's files and its U-Boot variables (`boot_zmod`, `zmod_*`) are only ever read.

## 5. The 256 MB board

Data from a 256 MB printer (`xram-collect-20261109-111545`, collected with `tools/collect.sh`), stock firmware 3.1.9, kernel `5.4.61 #52 SMP PREEMPT Wed Aug 23 15:33:33 CST 2023`, U-Boot `2018.05(08/25/2023-17:05:54)`:

| What | 256 MB board | Same as 128 MB / 3.1.5? |
|---|---|---|
| RAM | `memory@40000000` reg `0x40000000 0x10000000`, `androidboot.dramsize=256` | no (128 MB: `0x08000000`) |
| `sunxi.dtb` md5 | `c4aabbae50d6f56c8db2109804456ed2` (so the CRC is `e82291d2` too) | yes |
| its `/memreserve/` | the four entries of §1 | yes |
| `boot_package` | copies at sectors 32800 and 24576 (also found by scanning the first 32 MB) | yes |
| OP-TEE md5 (both copies) | `5ed6ffabbadb9926c7d44a9b4b833683`, 300248 bytes at offset `0xec800` | yes |
| U-Boot environment | `boot_uImage`, `boot_dsp0`, `setargs_mmc` as on 3.1.5; `fw_env.config` `/dev/mmcblk0p2` + `p3`, `0x20000` | yes |
| partitions | `boot-resource@mmcblk0p1 … UDISK@mmcblk0p7` | yes |

So `XR_KNOWN` matches unchanged, and every address extra-ram uses (`0x43000000` kernel, `0x44864e70` dtb, `0x44864e00` CRC scratch word, `0x41b00000` TEE_RAM) is the one the stock `boot_uImage` and OP-TEE use on both boards. The only 128 MB assumption was the install-time refusal above `MemTotal` 163840 kB, which is gone.

With the mode active (§6) the board showed:

- memblock: `0x41900000–0x4210ffff` gone, `0x41b00000..0x41bfffff` reserved, `cpu1` online;
- the live `/sys/firmware/fdt` `/memreserve/` has three entries: `0x41b00000/0x100000` (TEE_RAM), `0x4c864e70/0xe190` (U-Boot's relocated copy of the dtb itself) and `0x4c8ee000/0x177000` (`disp_reserve=1536000,0x4c8ee000`, the boot-logo framebuffer). The last two are above the old range, so the safety check does not count them as unexpected.

Not yet run on a 256 MB board: extra-ram's own `xram_main` boot (the CRC gate in U-Boot) and `extra-ram test`. The harvester of `extra-ram test` allocates a fixed 16 × 1 MB, so on 256 MB it may hold fewer pages of the freed range; its PASS only needs more than zero.

## 6. zmod's own mode (`zmod_xram_on`)

zmod 1.7 (upstream branch `1.7` from 2026-11-09, `.shell/emmc.sh` md5 `b92335adf36faf9c5b5af4818d5d7ebf`) frees the same memory itself. It is enabled by default and adds the edits of `xram_del` to its eMMC edits in `boot_zmod`. On the 256 MB printer (DDR52, method A):

```
boot_zmod = fdt rm /soc@3000000/sdmmc@4020000 mmc-hs200-1_8v;fdt set /soc@3000000/sdmmc@4020000 max-frequency <0x2faf080>;
            fdt rsvmem delete 3;fdt rsvmem delete 2;fdt rsvmem delete 1;fdt rsvmem delete 0;fdt rsvmem add 0x41b00000 0x100000;
            setenv bootargs ${bootargs} zmod_emmc_ddr zmod_xram_on;run boot_uImage
bootcmd   = setenv bootcmd run setargs_mmc boot_dsp0 boot_uImage;saveenv;run setargs_mmc boot_dsp0 boot_zmod
```

State is in `/opt/config/mod_data/emmc/`: `xr_state.txt` (`trial`/`ok`/`fail`), `xr_fails.txt` (fail after 3), and the switch `disable_extra_ram.txt`. Differences from extra-ram:

| | extra-ram | zmod's mode |
|---|---|---|
| firmware gate | `sunxi.dtb` md5 + OP-TEE md5 in both `boot_package` copies (Linux), dtb CRC (U-Boot) | `sunxi.dtb` md5 (Linux) |
| DSP firmware | not loaded (`boot_dsp0` is not run) | loaded by `boot_dsp0` into `0x42000000`, then that range is unreserved |
| TEE_RAM check after boot | `/sys/firmware/fdt` and memblock (§3) | `41b00000` in memblock |

**extra-ram stands down on such a zmod.** `xr_zmod_native` (`src/lib.sh`) detects it when zmod's `emmc.sh` mentions `zmod_xram_on`, `boot_zmod` contains `fdt rsvmem`, or the cmdline carries `zmod_xram_on`. It counts even with `disable_extra_ram.txt`. Then:

- `install` refuses before touching anything (the reason is printed, with zmod's switch);
- the boot hook still accounts for our last boot, then sets `last=zmod_native` and starts no `arm-wait`; `xr_arm_now` refuses the same way;
- `check` shows zmod's mode instead (active with `MemTotal` and the TEE_RAM check, or not active with `xr_state.txt` / `disable_extra_ram.txt`) and suggests `extra-ram uninstall`;
- `uninstall` works as before.

Why this variant is not added to `XR_ZMOD_KNOWN`: its edits, copied into `xram_boot`, already delete the four entries, so `xram_del` would then run `fdt rsvmem delete 3` on a one-entry table. That command fails, and the vendor U-Boot then stays on the logo. zmod would also count every extra-ram boot (its eMMC marker without `zmod_xram_on`) as a failure of its own mode. Its `boot_zmod` is also built from flags (method A/B, 50 MHz/DDR52, eMMC on/off, mode on/off), so a verbatim table could not cover it. `grep -w xram_on` does not match `zmod_xram_on` (`_` is a word character), so the safety check of §3 never acts on zmod's boots.

## 7. Sources and references

- the `/memreserve/` table of the stock `sunxi.dtb` (boot-resource partition) and of the live `/sys/firmware/fdt`;
- the OP-TEE image header and its memory tables inside `boot_package` (`/dev/mmcblk0`, sectors 32800 and 24576);
- the vendor U-Boot environment (`fw_printenv`) and the behaviour of the vendor U-Boot 2018.05, tried on the printer
- boot and memory experiments on the printer
- the read-only data collection of a 256 MB printer (`tools/collect.sh`, archive `xram-collect-20261109-111545`) and zmod's `.shell/emmc.sh` of upstream branch `1.7` (<https://github.com/ghzserg/zmod>, the mirror `ghzserg/z_ff5m`), md5 `b92335adf36faf9c5b5af4818d5d7ebf`

Public documentation for the formats and commands involved:

- Devicetree Specification, "Memory Reservation Block" (the `/memreserve/` entries, `off_mem_rsvmap`): <https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html>
- U-Boot `fdt` command (`fdt addr`; `fdt rsvmem` and `fdt resize` are not described there, see `cmd/fdt.c` in the U-Boot sources): <https://docs.u-boot.org/en/latest/usage/cmd/fdt.html>
- U-Boot `setexpr` command (`setexpr.l name *addr`, `setexpr name sub`): <https://docs.u-boot.org/en/latest/usage/cmd/setexpr.html>
- Linux PSCI devicetree binding (`CPU_ON`/`CPU_OFF` through `smc`): <https://www.kernel.org/doc/Documentation/devicetree/bindings/arm/psci.yaml>
- Linux `pagemap`, `kpagecount`, `kpageflags` (used by `extra-ram test`): <https://docs.kernel.org/admin-guide/mm/pagemap.html>
- OP-TEE core architecture (memory and shared memory): <https://optee.readthedocs.io/en/latest/architecture/core.html>
