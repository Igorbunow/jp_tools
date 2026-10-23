# Jetson board configuration bundles

[English usage guide](../docs/USAGE.en.md) · [Руководство на русском](../docs/USAGE.ru.md)

Each profile is stored as a package containing:

- `Linux_for_Tegra/`: files copied into the selected BSP.
- `COMPATIBILITY.md`: the compatibility and test history for that profile.

Place cross-version profiles under `common/<profile>/`. Place a complete
replacement package under a JetPack version selector when it only supports
that release family, for example `6.2.x/<profile>/`, `6.x/<profile>/`, or
`7.2.1/<profile>/`.

`setup_jetson.sh` selects one package in this order: exact version, minor
family, major family, then `common`. Packages are not merged. A versioned
package must therefore contain every file required by that profile. This
keeps a newer package from silently inheriting incompatible files.

The `6.2.x` directory currently contains separate complete packages for
`jetson-agx-orin-10g_4eth_pci_nvme_dp` and
`jetson-agx-orin-gmii_2eth_audio_dp`. They were copied from the 6.2.3
configuration set and verified against its BSP artifacts. See each package's
`COMPATIBILITY.md` for exact validation coverage; the `x` selector expresses
the intended release family, not proof of testing every 6.2 patch release.

The installer only adds missing files. If a package path collides with an
existing BSP file that has different content, setup stops and reports the
collision so the vendor file is preserved.

Version selectors use JetPack versions (`5.1.7`, `6.2.2`), not L4T release
strings (`R35.6.5`, `R36.4.4`). The default version is inferred from the
directory containing `setup_jetson.sh`; pass `--jetpack-version` when that
directory is named differently.

## Flash utility

Run `./b_conf/flash_jetson.sh` from the release directory. With no arguments
and an interactive terminal it lists compatible profiles, prompts for a
profile and operation, installs that profile's payload into `Linux_for_Tegra`,
then asks for confirmation before writing the device. `--list` prints profiles
without modifying the BSP.

Before installing a profile, the utility checks for a Jetson Orin Recovery USB
ID. In interactive mode, if no device is found, choose retry after connecting
the board in Recovery or quit. Batch runs fail immediately when Recovery is
absent. `--dry-run` skips device detection.

Batch examples:

```bash
./b_conf/flash_jetson.sh --list
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode full --yes
./b_conf/flash_jetson.sh --board jetson-agx-orin-10g_4eth_pci_nvme_dp --mode dtb --yes
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode rootfs --dry-run
```

`full` calls `flash.sh`; `dtb` writes `A_kernel-dtb` and then `B_kernel-dtb`;
`rootfs` writes only `APP`. The default root device is `mmcblk0p1`. Set
`JETSON_DEPLOY_DIR` to the base deployment directory (the utility uses its
`Linux_for_Tegra/` child), or `JETSON_L4T_DIR` to the exact BSP directory.
The utility detects JetPack from the deployed rootfs `/etc/jetson-image-info`;
for older images it can match the BSP's L4T release to the archive pair in
`JETSON_ARCHIVE_DIR`, then check version-named paths. It prints the detected
version and its source. `JETPACK_VERSION` or `--jetpack-version VERSION`
overrides detection. If no version can be inferred, only `common/` profiles
are listed. `JETSON_USB_SYSFS_ROOT` can override
the USB sysfs path used for Recovery detection (default
`/sys/bus/usb/devices`). `--dry-run` prints selected files and commands without
installing or flashing. `--yes` bypasses the interactive USB Recovery and
data-write confirmation in batch mode.

Before a full or rootfs flash, the utility prints the APP/rootfs partition
size. The default comes from the selected board configuration and may be a
smaller debug size; it is not assumed to be the maximum. Set
`--rootfs-size 16GiB` or `JETSON_ROOTFS_SIZE=16GiB` to choose a size, or use
`--rootfs-size max` / `JETSON_ROOTFS_SIZE=max` for the maximum specified by the
BSP's shared board configuration or profile `ROOTFS_SIZE` metadata. If the
maximum cannot be determined (for example, one profile targets modules with
different capacities), use `--force-rootfs-size 16GiB` to set the size. That
option also permits a size above a known limit and prints a warning. Without it,
an explicit size is rejected when it exceeds a known limit or the maximum is
unknown. The chosen size is passed to `flash.sh` with `-S` and
`IDS_ROOTFS_SIZE`. DTB-only flashes do not change rootfs size.

After every flash command and again on script exit, the utility checks for
mounts anywhere below the current `Linux_for_Tegra` deployment. If a failed or
interrupted command left one mounted, it warns, unmounts mounts deepest-first,
and detaches loop devices. If a regular unmount fails, it warns and retries
with a lazy detach; a failed lazy detach makes the script exit with an error.
The deployment directory itself and mounts outside it are preserved.
`setup_jetson.sh` applies the same exit cleanup and reports each QEMU mount it
removes.

## Optional OP-TEE test-key warning suppression

`suppress_uefi_auth_warnings.sh` provides an opt-in source patch for the two
OP-TEE test UEFI key warnings. It changes those messages from `IMSG` to
`DMSG`; with NVIDIA's default T234 OP-TEE log level they are omitted while
security error messages remain. This only changes logging and does not enable
UEFI variable protection or replace the test key.

The patch has been checked against JetPack 5.1.7, 6.2, 6.2.2, 6.2.3, and
7.2.1 source archives. Build an image without installing it using
`./b_conf/suppress_uefi_auth_warnings.sh --build`. This requires NVIDIA's
AArch64 Buildroot toolchain via `CROSS_COMPILE_AARCH64_PATH`. Install with
`sudo ./b_conf/suppress_uefi_auth_warnings.sh --install`; the original TOS is
saved beside itself, and `--restore` restores it. Flash/reflash after
installation for the change to reach the device.
