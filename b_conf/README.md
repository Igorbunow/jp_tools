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

Batch examples:

```bash
./b_conf/flash_jetson.sh --list
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode full --yes
./b_conf/flash_jetson.sh --board jetson-agx-orin-10g_4eth_pci_nvme_dp --mode dtb --yes
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode rootfs --dry-run
```

`full` calls `flash.sh`; `dtb` writes `A_kernel-dtb` and then `B_kernel-dtb`;
`rootfs` writes only `APP`. The default root device is `mmcblk0p1`. Use
`--jetpack-version VERSION` when the release directory name does not match the
BSP version. `--dry-run` prints selected files and commands without installing
or flashing. `--yes` bypasses the interactive USB Recovery and data-write
confirmation in batch mode.

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
