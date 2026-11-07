# extra-ram: technical notes

How the reserved memory of the FlashForge AD5M (128 MB, Allwinner sunxi, stock firmware 3.1.5) is laid out, and the exact commands extra-ram uses to free it. For users see [README.md](README.md) / [README.ru.md](README.ru.md).

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

Result: 8256 − 1024 = **7232 KB** freed. `MemTotal` 110404 → 117636 kB.

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
  - `/sys/firmware/fdt` (`/memreserve/` must contain exactly `0x41b00000/0x100000`);
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

zmod's files and its U-Boot variables (`boot_zmod`, `zmod_*`) are only ever read.

## 5. Sources and references

- the `/memreserve/` table of the stock `sunxi.dtb` (boot-resource partition) and of the live `/sys/firmware/fdt`;
- the OP-TEE image header and its memory tables inside `boot_package` (`/dev/mmcblk0`, sectors 32800 and 24576);
- the vendor U-Boot environment (`fw_printenv`) and the behaviour of the vendor U-Boot 2018.05, tried on the printer
- boot and memory experiments on the printer

Public documentation for the formats and commands involved:

- Devicetree Specification, "Memory Reservation Block" (the `/memreserve/` entries, `off_mem_rsvmap`): <https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html>
- U-Boot `fdt` command (`fdt addr`; `fdt rsvmem` and `fdt resize` are not described there, see `cmd/fdt.c` in the U-Boot sources): <https://docs.u-boot.org/en/latest/usage/cmd/fdt.html>
- U-Boot `setexpr` command (`setexpr.l name *addr`, `setexpr name sub`): <https://docs.u-boot.org/en/latest/usage/cmd/setexpr.html>
- Linux PSCI devicetree binding (`CPU_ON`/`CPU_OFF` through `smc`): <https://www.kernel.org/doc/Documentation/devicetree/bindings/arm/psci.yaml>
- Linux `pagemap`, `kpagecount`, `kpageflags` (used by `extra-ram test`): <https://docs.kernel.org/admin-guide/mm/pagemap.html>
- OP-TEE core architecture (memory and shared memory): <https://optee.readthedocs.io/en/latest/architecture/core.html>
