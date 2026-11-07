# extra-ram: +7 MB of RAM for the FlashForge AD5M (128 MB)

[Русский](README.ru.md)

## What it is

`extra-ram` gives the printer back about 7 MB of RAM that sits unused on a 128 MB AD5M (where it comes from is explained in the next section):

| | MemTotal |
|---|---|
| normal boot | 110,404 kB |
| with extra-ram | 117,636 kB (+7,232 kB) |

The kernel gets these pages entirely as free memory, so `MemAvailable` grows by about the same 7.1 MB.
Compared with 110 MB this looks like a small gain, but compared with the typical amount of free memory during a print 7 MB becomes noticeable. For comparison:
(estimate from earlier `MemAvailable` measurements on the printer without extra-ram):

| Moment | `MemAvailable` without extra-ram | +7.1 MB is |
|---|---|---|
| printing, typical | 20–30 MB | +24…35 % |

It is a small standalone set of shell scripts. It is installed over SSH, runs next to zmod and **changes nothing in zmod** (neither its files nor its U-Boot variables). Any failure is cured by a power cycle: the printer then boots as usual.

## Where the memory comes from

When the printer is switched on, a boot loader (U-Boot) runs first and then starts Linux. Together with Linux it hands over a description of the hardware, the file `sunxi.dtb` ("sunxi" is the name of the Allwinner processor family the printer is built on). Among other things this file lists memory areas that Linux must not touch: they are booked for other programs.

The stock firmware books about 8 MB this way, for two things the printer does not use:

- **DSP** (1 MB + 64 KB): a separate small processor inside the chip for audio processing. The printer does not use it; sound goes the usual way through Linux.
- **OP-TEE** (7 MB): a small "secure" program from the chip maker. It runs next to Linux in an isolated mode and is meant for storing keys, content protection and the like. The printer uses none of that, but one part of it is still needed: Linux switches processor cores on and off and reboots the system through OP-TEE. The program with its data takes 1 MB. The other 6 MB are an area for exchanging data with Linux (2 MB) and room for "trusted applications" (4 MB); the printer uses neither: its kernel does not even have a driver for talking to OP-TEE.

`extra-ram` removes these bookings and keeps only the 1 MB where OP-TEE lives. Without it the printer freezes at the first processor-core operation; this was verified on a printer. That frees 8 − 1 ≈ 7 MB (7,232 kB exactly).

## How it works

The script writes a few U-Boot variables of its own (`xram_*`) and arms a **one-shot** boot. U-Boot checks the checksum (CRC) of `sunxi.dtb`, removes the extra bookings from the `/memreserve/` table, adds back only the 1 MB of OP-TEE (TEE_RAM) and starts the kernel. If the CRC does not match (the file is not the verified one), the boot is a normal one. After the boot, Linux checks that TEE_RAM is booked and arms the next one-shot boot again, 3 minutes after the boot (a hang before that leaves the stock `bootcmd`). The `install` command arms at once.

The memory layout and the exact U-Boot and Linux commands are described in [TECH.md](TECH.md).

## Supported

- **zmod** on a 128 MB AD5M: the main supported system. zmod's eMMC 50 MHz / DDR52 works together with extra-ram (details below).
- **Firmware**: only one is in the verified list for now (`sunxi.dtb` md5 `c4aabbae50d6f56c8db2109804456ed2`). On any other firmware the installation refuses (see "If your firmware is not in the list").
It looks like FlashForge firmware updates never change this file, so extra-ram will very likely work on any 5M/5M Pro firmware, but we will know for sure only after wider testing by users.
- **Rooted stock firmware and Forge-X**: experimental only, with the `--experimental` flag. It has **not been tested** on a printer.
- 256 MB boards are not supported (the installation refuses).

## Installation

In short:

1. Log in to the printer over SSH and download extra-ram from GitHub.
2. Run `sh install.sh`: it checks the printer and the firmware, installs the files and arms the mode for the next boot.
3. Reboot the printer.
4. Check the result with `/opt/extra-ram/extra-ram check`. The changed memory size shows in the system command `free -k` or in zmod's `MEM` macro.
5. Optionally, run the memory test `/opt/extra-ram/extra-ram test` (about 11 minutes, the printer must be idle).

In detail:

You need SSH access as root. Log in to the printer and download extra-ram from GitHub with `curl`. On zmod, `curl` comes from Entware; if the printer says `curl: not found`, install it first:

```sh
opkg update && opkg install curl
```

Then download and run the installer (the printer's `tar` cannot unpack `.tar.gz` by itself, hence `gzip -dc`):

```sh
cd /tmp
curl -fsSL https://github.com/mlengle/ad5m-extra-ram/archive/refs/heads/main.tar.gz | gzip -dc | tar xf -
cd ad5m-extra-ram-main && sh install.sh
```

If you have rooted stock firmware, it most likely has no Entware (no `curl` and no `opkg`). In that case, download the archive on a computer and pass it straight to the printer (Linux, macOS or `cmd` on Windows; plain `scp` does not work, the printer has no `sftp-server`):

```sh
curl -fsSL https://github.com/mlengle/ad5m-extra-ram/archive/refs/heads/main.tar.gz | ssh root@<printer> "cd /tmp && gzip -dc | tar xf -"
```

then run `cd /tmp/ad5m-extra-ram-main && sh install.sh` on the printer.

`install.sh` copies the files to `/opt/extra-ram`, installs the init script `/etc/init.d/S45xram` and runs `extra-ram install`, which checks that:

- it is run as root;
- zmod has finished its eMMC check (`emmc.sh`) in this boot (otherwise it refuses with "try again in a few minutes");
- the printer is not printing (via Moonraker);
- `MemTotal` is at most 160 MB (a 128 MB board);
- the firmware is in the list (`sunxi.dtb` and OP-TEE in both copies of `boot_package`);
- which system is installed (zmod, Forge-X, no modification);
- `bootcmd` is the stock one, zmod's armed one or ours (a foreign `bootcmd` is a refusal);
- on zmod: it records the current 50 MHz / DDR52 state as "at install time";
- the required tools exist (`fw_printenv`, `fw_setenv` with `-s`, `md5sum`, `hexdump`, `mount`) and the file `/etc/fw_env.config` exists and the root filesystem has room.

Then the mode is armed for the next boot. After that:

```sh
reboot
# after the boot:
/opt/extra-ram/extra-ram check
```

The `extra-ram` command lives in `/opt/extra-ram/` and is not added to `PATH`; if you like, `alias extra-ram=/opt/extra-ram/extra-ram`.

Message language: Russian if `/opt/config/mod_data/lang.cfg` contains `language: ru`, otherwise English. `XRAM_LANG=ru|en` overrides it.

**Upgrading** extra-ram itself: download the new version the same way as for installation and run `sh install.sh` again. This is an ordinary re-install: it overwrites the files, repeats all the checks and arms the mode. The failure counter is reset to 0 and a disable after failures (`fail`) is cleared; only the zmod 50 MHz / DDR52 state recorded at the first install and the system type are kept. The firmware list is updated with the files.

**Experimental installation** (not zmod): `sh install.sh --experimental`. The installer prints a warning and asks for `yes` (or add `--yes`). The "experimental" status is stored and shown by `check`. If zmod is installed on that system later, extra-ram switches to the zmod rules.

## Commands

Run everything as root: `/opt/extra-ram/extra-ram <command>`.

| Command | What it does |
|---|---|
| `install [--experimental] [--yes]` | checks, writes the state, arms. Running it again after the mode was disabled (`fail`) enables it again |
| `check` | a report, changes nothing (see below) |
| `test [--force]` | memory test, about 11 minutes, only on an idle printer and only when the mode is active in this boot |
| `uninstall` | disarms, restores the stock `bootcmd`, removes the `xram_*` variables, the init script, `/opt/extra-ram` and `/etc/extra-ram` |

The internal commands `boot` and `arm-wait` are called by the init script; you do not need to run them.

### `check`

It prints a few lines:

- **Extra RAM**: active (`MemTotal`, TEE_RAM reserved), or not active and why: the CRC of `sunxi.dtb` did not match in U-Boot (firmware changed), the boot did not reach the system, the mode was disabled after two failures, unexpected reservations, and so on;
- **eMMC 50 MHz / DDR52** (zmod only): same as at install or changed, and what to do (see below);
- **whether the mode is armed for the next boot**: yes, or no with the reason;
- for an experimental installation: a reminder that it was not tested.

Event log: `/etc/extra-ram/extra-ram.log`.

### `test`

The memory test (about 11 minutes; the printer must stay idle):

1. the second core (`cpu1`) is taken offline and back right after the start (a PSCI call through OP-TEE);
2. for 10 minutes a page "harvester" runs: it takes memory from the freed range, fills it with a pattern and checks that the data stays intact and the pages do not move;
3. three more `cpu1` offline/online cycles.

The last output line is `RESULT PASS` or `RESULT FAIL`. The exit code is 0 only on `RESULT PASS`. The test needs `/usr/bin/python3`. If Moonraker is unreachable, the test does not start without `--force`. Logs are in `/etc/extra-ram/test/`.

**If the printer hangs at the `cpu1` step, OP-TEE is not protected.** Power-cycle the printer: the boot will be a normal one. Send the output of `check` to the author.

## How it combines with zmod's eMMC 50 MHz / DDR52

- If zmod has already enabled 50 MHz, the extra-ram boot carries the **same eMMC edits** as `boot_zmod`, in the same boot. So after the boot zmod sees its own marker and the 50 MHz clock and counts the boot as successful. Conditions: zmod's `state.txt` is `ok` and `boot_zmod` matches one of the known strings (zmod 1.7; DDR52 and plain 50 MHz). If zmod is testing 50 MHz itself right now (`state.txt` is not `ok`), extra-ram is not armed, so the failures do not mix, and is armed after the test. If zmod's arming strings (`bootcmd` or `boot_zmod`) are not in the list of known ones (for example a new zmod version), the installation refuses (when zmod's own boot is armed at that moment), and an existing installation stops arming; `check` says so and shows the md5 of `emmc.sh`. New zmod versions are added to the list in `src/lib.sh`, the same way as firmware.
- If zmod does not use 50 MHz (`disable.txt`, `state=fail`, no `emmc.sh` or `boot_zmod`), extra-ram arms without eMMC edits. This is the normal supported case.
- extra-ram arms only after zmod's `emmc.sh` has finished in the current boot (a background wait of up to 15 minutes) and not earlier than 3 minutes after the boot: otherwise zmod would overwrite `bootcmd`.
- extra-ram's U-Boot variables are its own (`xram_main`, `xram_boot`, `xram_del`, `xram_skip`), so removing zmod does not touch them and no reference to a missing variable is left behind.

**If the extra-ram boot hangs** and you then power-cycle, zmod sees its one-shot boot without the marker and counts a 50 MHz failure: **it drops DDR52 at once** (deletes `ddr.txt`) and 50 MHz after 3 failures. extra-ram's own counter disables the mode after **two** failures in a row, i.e. before 50 MHz is given up.

`check` compares zmod's current state with the one recorded at install and tells you what to do:

- 50 MHz was lost (`state.txt` became `fail`): delete the files in `/opt/config/mod_data/emmc/` (keep `disable.txt` if you created it yourself) and reboot twice so zmod repeats its test;
- afterwards, for DDR52 create `/opt/config/mod_data/emmc/ddr.txt` and reboot;
- only DDR52 was lost (`state.txt` is `ok`): create `ddr.txt` and reboot.

extra-ram itself never changes zmod's files.

## If your firmware is not in the list

The installation refuses and prints a line with everything needed: the md5 of `sunxi.dtb`, the md5 of OP-TEE in both copies of `boot_package` and the `/memreserve/` table. Send that output to the author: <https://github.com/mlengle/ad5m-extra-ram/issues>. The author will check the firmware and add it to the list; after that it is enough to update the files on the printer (`sh install.sh`).

## Accepted risk: a firmware update while armed

U-Boot checks only the CRC of `sunxi.dtb`; OP-TEE is checked in Linux when arming. If an update (stock, or installing another mod) reboots the printer while the mode is armed and `sunxi.dtb` stays the same, one boot goes through with an unverified OP-TEE. If the new OP-TEE has a different TEE_RAM layout, the first PSCI call (`cpu1` offline, reboot) hangs the printer. A power cycle gives a normal boot, and the next arming checks OP-TEE again and refuses. According to Forge-X documentation, the stock `sunxi.dtb` and kernel did not change in 3.1.3–5.1.7; there is no data about OP-TEE. It is wiser to run `extra-ram uninstall` before a firmware update.

## Recovery

- **Any hang during boot: power-cycle the printer.** The boot is one-shot, so the printer boots as usual. extra-ram counts a failure; after two failures in a row it disables itself (`check` shows "the mode is disabled"). It can be enabled again only with `extra-ram install`.
- After a boot with the marker but without TEE_RAM, the boot hook immediately restores the stock `bootcmd`, disables the mode and reboots the printer.
- Removal: `extra-ram uninstall`, then reboot. If zmod armed its own 50 MHz boot under us, its state is `ok` and `boot_zmod` is a known one, the uninstall gives it back so the 50 MHz boot is not lost. Otherwise the stock `bootcmd` is restored (if zmod was updated, its old armed bootcmd could refer to a variable that no longer exists and hang the boot).
- If `uninstall` could not restore `bootcmd` or read it back (the stock one or zmod's armed one), it removes nothing and asks you to repeat it.

## Where things are

| Path | What |
|---|---|
| `/opt/extra-ram/` | code (`extra-ram`, `lib.sh`, `test/`) |
| `/etc/extra-ram/` | state, the `extra-ram.log` log, test results |
| `/etc/init.d/S45xram` | init script (calls `extra-ram boot`) |

Everything is on the root filesystem: `/data` is not mounted yet when init scripts run.

## License

MIT, see [LICENSE](LICENSE). You may use, modify and distribute the code, including commercially, as long as you keep the copyright notice and the license text.
