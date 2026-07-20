# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

`meraki-builder` builds replacement/custom firmware ("postmerkOS") for Cisco Meraki hardware whose stock firmware has been reverse-engineered:

- **MS220-series switches** (MIPS, Vitesse Luton/Jaguar ASIC): MS220-8(P), MS220-24(P), MS220-48(LP|FP), MS22(P), MS42(P), MS320-24(P), MS320-48(LP|FP)
- **MS225-series switches** (ARM, "Brumby" ASIC) — buildroot support exists (`buildroot/board/meraki/ms225`) but is not yet mentioned in `README.md`
- **MX80 / MX84 routers** (PowerPC, "Fullerene" kernel) — MX80 has full Docker build automation; MX84 only has an overlay + `post-build.sh`, no `buildroot-config`, so it isn't independently buildable via `docker/` yet

There is no application source code, package manager, test suite, or linter in the conventional sense. The "code" is: buildroot board configs/overlays, kernel patches, small C/shell userspace tools, and shell scripts that binary-patch flash dumps. Correctness is verified by building an image and flashing real hardware, not by automated tests.

## Repository layout

- `buildroot/board/meraki/<board>/` — per-board buildroot config (`buildroot-config`), kernel config/DTS/patches (`kernel/`, `u-boot/`), root filesystem overlay (`overlay/`), and buildroot hooks (`post-build.sh` runs inside `${TARGET_DIR}` before the image is packed; `post-image.sh` runs after, and assembles the final flashable image from `${BINARIES_DIR}`)
- `buildroot/packages/` — custom out-of-tree buildroot packages: `pd690xx` (PoE controller CLI/lib for MS220-P switches), `find_hdr` (buildroot-packaged version of the header-finder tool), and `click` (Kohler's userspace Click modular router library — present but **not currently wired into any build**: no `buildroot/patches/*.patch` registers it in `package/Config.in`, and no board's `buildroot-config` sets `BR2_PACKAGE_CLICK=y`; don't confuse it with the actual switch dataplane, see Architecture notes)
- `buildroot/patches/` — patches applied to a **stock** buildroot source tree to register the out-of-tree `pd690xx`/`find_hdr` packages above in `package/Config.in` (buildroot doesn't know about packages living outside its own tree, so these patches wire them in)
- `docker/<board>/` — `Dockerfile` (Ubuntu 18.04 + toolchain deps) and `Makefile` that orchestrate a full build: fetch a buildroot release, clone/symlink this repo's `board/meraki` and `packages/` into it, apply patches, then run buildroot's `make`. **`docker/mx80` and `docker/ms220` use different, non-interchangeable orchestration patterns** — see Build commands below.
- `nor/` — tools for the MS220 **NOR** flash build/extract path (RedBoot-based, legacy): `extract.sh` splits a raw NOR dump into named sections (`bin/loader1`, `bin/boot1`, `bin/bootubi`, ...); `make.sh` reassembles a flashable `switch-new.bin` from a kernel + squashfs + generated JFFS2; `layout-*MBkernel.txt` documents flash offset maps; `bin/` holds binaries you must supply yourself (not checked in, see `nor/bin/README.md`)
- `nand/` — tools for extracting/patching the **NAND** ramdisk (initrd) from a firmware dump: `extract.sh` locates and unpacks `ramdisk.gz` (via `find_hdr`), `make.sh` removes stock binaries/kernel modules, patches `/etc/passwd` and `/etc/inittab` to allow shell login, and repacks with `mksquashfs`
- `tools/` — `find_hdr.c` (compile with `gcc find_hdr.c -o find_hdr`, must be on `PATH`) and an equivalent `find_hdr.py`; used by the `nor`/`nand` extract scripts to locate gzip/XZ header/footer offsets in a binary dump instead of hard-coding them

## Build commands

There is no single top-level build command — pick the path for the target hardware.

**MS220/MS320/MS22/MS42 (NOR flash, current maintained path):**
```
cd docker/ms220
make deps          # downloads buildroot 2023.02.4, clones meraki-builder, symlinks board/meraki + pd690xx package, applies buildroot/patches/*.patch
make docker-image   # builds the ubuntu1804-buildroot image
docker run -it --rm -v $(pwd)/src:/src ubuntu1804-buildroot   # runs buildroot's default `make` (Dockerfile CMD); the Makefile's `all` target references a `docker-build` rule that isn't actually defined (only `docker-build-dbg`, an interactive debug shell), so drive this step manually
```
Also requires a RedBoot bootloader binary at `nor/bin/loader1` (see README) and a kernel built from [switch-11-22-ms220](https://github.com/halmartin/switch-11-22-ms220). Once buildroot produces `output/images/rootfs.squashfs`, copy it to `nor/bin/squashfs` and run `nor/make.sh` to produce `switch-new.bin`.

**MX80 (PowerPC, uses an older buildroot 2020.02.8):**
```
cd docker/mx80
make docker-build   # = docker-image + docker-build; docker-build runs the container with --entrypoint=board/meraki/mx80/buildroot.sh, which symlinks board/meraki and .config into the buildroot tree at *runtime* (unlike ms220, which patches the tree at `make deps` time) and then invokes `make`
```
Output: `output/images/ubi_image.bin`.

**Compiling `find_hdr` standalone:**
```
gcc tools/find_hdr.c -o find_hdr   # put find_hdr on PATH so nor/nand extract.sh can find it; falls back to find_hdr.py otherwise
```

**Extracting/patching a firmware dump (MS220 NAND path):**
```
cd nand && ./extract.sh <dump.bin>   # or defaults to mtd12-original.dat; produces ./ramdisk
# edit ramdisk/ contents, then:
./make.sh                            # strips stock binaries, patches passwd/inittab, repacks as bootubi.new
```

## Architecture notes

**Board variance is real, not templated.** Each board directory under `buildroot/board/meraki/` is architecture-specific and independent — `ms220` targets `mipsel`, `ms225` targets `arm` with a custom kernel tarball fetched at build time, `mx80` targets `powerpc` with the `fullerene` defconfig. Don't assume logic/scripts are shared across boards; check the specific board directory.

**The switch dataplane is Meraki's own proprietary Click-based kernel stack, extracted binary `.ko` files — not the `buildroot/packages/click` source package.** Boot order (`overlay/etc/init.d/S08kmods`, `S09clickinit`): `vtss_core.ko` (per-ASIC dir `luton26`/`jaguar`/`jaguar_dual`, `board_desc=<model>`) → `proclikefs.ko` → `merakiclick.ko` → `elts_meraki.ko` → `vc_click.ko` (per-ASIC, loaded last). These come from a Meraki firmware/GPL dump and live under `overlay/lib/modules/<mod_dir>/`; if missing, `S08kmods`' `fwcutter()` will pull them at boot from an MTD partition instead. `proclikefs`/`merakiclick` register a `click` filesystem type; `S09clickinit` does `mount -t click none /click`, decompresses `overlay/etc/switch.template.gz` (an actual Click-language router config, `require(elts_meraki)`, with placeholders like `__NUM_SWITCHPORTS__` substituted), and writes it to `/click/config` to build the router graph. Each Click element then exposes handler files under `/click/<element>/<handler>`.

**`overlay/etc/init.d/S10clickconfig` is the most important file for switch behavior.** It was written by reverse-engineering Meraki's stock `switch_brain` binary and reproduces its default (blank-config) runtime setup by writing to those Click element handler files (e.g. `/click/switch_port_table/set_vlan_allports_conf`) — most switch features (VLANs, STP, LLDP/CDP, 802.1X, IGMP/MLD snooping, PoE-adjacent config) are configured this way rather than through a conventional daemon. When touching switch runtime behavior, this is the file to read/modify, and changes should be cross-checked against the port count (`NUM_PORTS`, read from `/tmp/NUM_PORTS`) since port loops are used extensively to build per-port Click config strings.

**`overlay/bin/board_data` determines the switch model at runtime**, first by reading a product number from the EEPROM/board-config MTD partition (`product_number_to_model`), and falling back to matching `VSC74[23][457]( Dual)?` against `/proc/cpuinfo` (`get_board_cpu`) when the product number is unreadable/unknown — e.g. it disambiguates MS220-48 vs MS320-48 (same "VSC7434 Dual" ASIC) by checking for removable power supplies (`/sys/class/power_supply/cisco-mps.*`). `set_*` subcommands write back to the MTD/EEPROM and are gated behind a `$DANGERZONE` env var.

**Flash images are byte-exact and offset-sensitive.** Both `nor/make.sh` and the per-board `post-image.sh` scripts build fixed-size regions (padding kernel/squashfs/JFFS2 to hard-coded sizes like `0x800000`, `0x500000`) and concatenate them; the scripts hard-fail/warn if the final image isn't the expected total size (e.g. `16777216` bytes). When editing these, preserve the region ordering and sizes — they must match the flash layout documented in `nor/layout-*.txt` and the board's u-boot/RedBoot expectations.

**Two distinct Docker orchestration patterns exist** (`docker/ms220` vs `docker/mx80`) — don't port fixes between them assuming shared structure; see Build commands above for the difference (patch-at-deps-time vs symlink-at-container-runtime).

## Conventions

- Shell scripts are POSIX/bash, organized as small functions called in sequence at the bottom of the file (see `nand/make.sh`, `*/post-image.sh`); there's no shared shell library, logic is duplicated per board on purpose since hardware differs.
- Comments in reverse-engineered scripts (e.g. `S10clickconfig`, `board_data`) explain *why* a value/offset/workaround exists (protocol quirks, hardware bugs) — preserve that style when adding to these files rather than describing what the line does.
- Commit messages are short, imperative, and often name the board/model affected (e.g. `MS320-24P: Fix GPIO for pd690xx auto configuration on jaguar1 (VSC7434)`, `MS220: Fix minor syntax errors`).
