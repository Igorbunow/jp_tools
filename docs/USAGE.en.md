# Jetson tools: usage and board profiles

[Русская версия](USAGE.ru.md) · [Project overview](../README.md)

This guide covers the Debian host, L4T deployment, flashing, and adding board profiles.

## 1. Host and dependencies

The host environment targeted by this repository is **Debian GNU/Linux 13 (Trixie), x86_64**. Run the scripts from a regular account with working `sudo` access. Do not run the entire setup as root: the scripts request elevated access for operations that need it. NVIDIA's Jetson Linux R36.5 release notes list Ubuntu 20.04/22.04 x86_64 as supported host systems, so Debian support here is a community-maintained compatibility layer, not upstream certification ([NVIDIA R36.5 release notes](https://docs.nvidia.com/jetson/archives/r36.5/ReleaseNotes/Jetson_Linux_Release_Notes_r36.5.pdf)).

Install the packages used by the setup and Debian compatibility scripts:

```bash
sudo apt-get update
sudo apt-get install -y \
  git pv tar bzip2 sudo \
  abootimg xmlstarlet gdisk parted cpio gzip binutils \
  sshpass openssh-client
```

If `sudo` is not installed yet, run `apt-get` as root (for example, from `su -`) to install it first, then use the command above.

| Debian package | Purpose |
| --- | --- |
| `git` | Clones this repository. It is not needed when using a source archive. |
| `pv` | Shows extraction progress in `setup_jetson.sh`. |
| `tar`, `bzip2` | Extracts NVIDIA `.tbz2` release archives. |
| `sudo` | Runs L4T setup, privileged file operations, and flashing. |
| `abootimg`, `xmlstarlet`, `gdisk`, `parted`, `cpio`, `gzip` | Host tools checked by `setup_debian.sh` for L4T recovery-image generation. The `sgdisk` command is provided by `gdisk`. |
| `binutils` | Provides the `strings` command used by L4T tooling. |
| `sshpass`, `openssh-client` | Host SSH utilities expected by the L4T scripts; `ssh-keygen` is provided by `openssh-client`. |

`setup_debian.sh` checks and installs any missing packages in its patch-tool list. Core utilities such as Bash, `awk`, `sed`, `grep`, `find`, `install`, `md5sum`, and `mount` are expected from a normal Debian installation. An unrelated APT repository error may be reported; the script will still attempt to install packages from available indexes.

### Optional QEMU chroot

The optional chroot stage needs `qemu-user-static`. `setup_jetson.sh` installs it automatically if the stage is selected and the `qemu-aarch64-static` binary is missing. Use `--skip-qemu` to skip the stage.

### Optional OP-TEE warning-suppression build

Only needed for `b_conf/suppress_uefi_auth_warnings.sh`:

```bash
sudo apt-get install -y make python3 device-tree-compiler patch ripgrep binutils
```

You also need NVIDIA's AArch64 Buildroot cross-toolchain, with
`aarch64-buildroot-linux-gnu-gcc` under `$CROSS_COMPILE_AARCH64_PATH/bin/`.
This toolchain is not installed by the command above and is not distributed by
this repository.

## 2. Get the NVIDIA release files

Download the L4T Driver Package and Sample Root Filesystem for the **same L4T release**. Place both `.tbz2` files in the directory containing `setup_jetson.sh`:

```text
Jetson_Linux_<L4T-release>_aarch64.tbz2
Tegra_Linux_Sample-Root-Filesystem_<L4T-release>_aarch64.tbz2
```

For example, JetPack 6.2.3 uses L4T R36.5.2 in this project's release history:

```text
Jetson_Linux_R36.5.2_aarch64.tbz2
Tegra_Linux_Sample-Root-Filesystem_R36.5.2_aarch64.tbz2
```

Use the filenames supplied by NVIDIA for your target release. The scripts do not download NVIDIA archives. `public_sources.tbz2` is optional and is extracted only if you place it beside the setup script under that exact name.

## 3. Deploy an L4T tree

Run from the repository root. The example explicitly selects JetPack 6.2.3, the matching L4T archive release, and the no-carrier-EEPROM AGX Orin devkit profile:

```bash
./setup_jetson.sh \
  --jetpack-version 6.2.3 \
  --version R36.5.2 \
  --board jetson-agx-orin-devkit-noeeprom \
  --skip-qemu
```

Version options are different:

- `--version` selects an L4T release token such as `R36.5.2`, matching the NVIDIA archive filenames.
- `--jetpack-version` selects the profile family, such as `6.2.3`.

If `--version` is omitted, the newest matching L4T/rootfs archive pair is selected. If `--jetpack-version` is omitted, the script uses the name of the directory containing `setup_jetson.sh`. When the repository is cloned into a generic directory such as `jp_tools`, pass `--jetpack-version` explicitly.

The default deployment directory is `./Linux_for_Tegra`; change it with `--dir PATH`. The script extracts L4T and rootfs, runs `apply_binaries.sh`, creates the requested default user, copies `root_fs/`, optionally extracts public sources, installs the selected `b_conf` payload, then applies Debian compatibility patches.

If `Linux_for_Tegra` already exists, interactive mode offers reuse or removal. `--force` removes it and rebuilds from the archives; this deletes all content under that deployment path. Back up any files you need first. In batch mode (`-y`), an existing deployment is reused unless `--force` is set.

Without `--skip-qemu`, the script asks whether to enter a QEMU chroot at the end. In silent mode (`-y`) confirmations are accepted, so combine `-y` with `--skip-qemu` for a non-interactive deployment that should not open a chroot shell.

### Default user and root UART login

The script runs NVIDIA's `tools/l4t_create_default_user.sh` before setting UART login behavior. By default, it installs a systemd getty drop-in that enables passwordless root login on `ttyTCU0` for debugging. Disable or remove this setting by adding the flag to your deployment command, for example:

```bash
./setup_jetson.sh --jetpack-version 6.2.3 --version R36.5.2 \
  --board jetson-agx-orin-devkit-noeeprom --skip-qemu --no-root-uart-login
```

This option is applied after user creation and the optional QEMU step. Passwordless root access is intended for controlled development hardware; turn it off for deployed devices.

## 4. Prepare and flash the board

List profiles that resolve for the selected JetPack version:

```bash
./b_conf/flash_jetson.sh --list --jetpack-version 6.2.3
```

Review the selected profile's `COMPATIBILITY.md`. For a dry run, which lists the payload and flash commands without copying files or writing the device:

```bash
./b_conf/flash_jetson.sh \
  --board jetson-agx-orin-devkit-noeeprom \
  --mode full \
  --jetpack-version 6.2.3 \
  --dry-run
```

Put the Jetson into USB Recovery mode and connect it to the host before running the command without `--dry-run`. The utility checks the USB device IDs first. For Orin it recognizes NVIDIA vendor ID `0955` with Recovery product IDs `7023`, `7223`, `7323`, `7423`, `7523`, or `7623`; a normal-mode `0955:7020` device is not treated as Recovery. NVIDIA documents these Recovery IDs in its [Jetson Linux R36.4.3 quick-start guide](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/IN/QuickStart.html). If no Recovery device is found in an interactive session, choose retry after reconnecting/re-entering Recovery or quit. Batch mode exits immediately. After detection, the script installs the selected profile files and requests confirmation before writing device partitions.

NVIDIA's release guide also documents running `sudo tools/l4t_flash_prerequisites.sh` from the extracted BSP before flashing. The helper's contents vary by release; this project provides the Debian-specific packages and fixes described above ([NVIDIA flashing guide](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport.html)).

Available modes:

| Mode | Operation |
| --- | --- |
| `full` | Runs `sudo ./flash.sh <board> <rootdev>`. |
| `dtb` | Writes `A_kernel-dtb` and then `B_kernel-dtb`. |
| `rootfs` | Writes only the `APP` partition. |

The default root device is `mmcblk0p1`. Specify another device with `--rootdev DEVICE` if the target configuration requires it. Examples:

```bash
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode full --jetpack-version 6.2.3
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode dtb --jetpack-version 6.2.3
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode rootfs --jetpack-version 6.2.3
```

`--yes` skips the interactive write confirmation and is intended for an explicitly controlled batch run. The script also refuses to overwrite an existing BSP file when the selected profile contains different data at the same path. Resolve the collision deliberately or use a clean L4T deployment; do not overwrite vendor files blindly.

To call NVIDIA's script directly after profile/setup preparation:

```bash
cd Linux_for_Tegra
sudo ./flash.sh jetson-agx-orin-devkit-noeeprom mmcblk0p1
```

For the IDS 10G/4-Ethernet profile on the matching JetPack 6.2.x BSP:

```bash
cd Linux_for_Tegra
sudo ./flash.sh jetson-agx-orin-10g_4eth_pci_nvme_dp mmcblk0p1
```

The latter profile has only been validated against its documented 6.2.3 source set; read its compatibility journal before using it with another 6.2.x release.

## 5. Add a board profile

Choose the narrowest selector that reflects actual validation:

```text
b_conf/
  common/<profile>/                 # intended to work across JetPack families
  5.1.7/<profile>/                   # one exact JetPack release
  6.2.x/<profile>/                  # intended for the 6.2 family
  6.x/<profile>/                    # intended for all JetPack 6 releases
  7.x/<profile>/                    # intended for all JetPack 7 releases
```

The selector checks, in order, `<major>.<minor>.<patch>`, `<major>.<minor>.x`, `<major>.x`, and `common`. For example, JetPack `6.2.3` tries `6.2.3/<profile>`, `6.2.x/<profile>`, `6.x/<profile>`, then `common/<profile>`.

Each package is a complete payload; the selector does not merge files from multiple packages. A package must contain:

```text
b_conf/<selector>/<profile>/
  COMPATIBILITY.md
  Linux_for_Tegra/
    <profile>.conf
    ... custom BCT, pinmux, GPIO, DTB, or other referenced files ...
```

Recommended workflow:

1. Start from a working vendor BSP for the exact JetPack release and identify the correct base board configuration. Keep NVIDIA's files intact; add a new uniquely named `<profile>.conf` that sources the appropriate base profile and overrides only what the board needs.
2. Put every custom file referenced by the profile inside its package under the corresponding `Linux_for_Tegra/` path. Do not copy vendor files that the target BSP already supplies.
3. Add `COMPATIBILITY.md`. Record the hardware/carrier revision, intended JetPack and L4T versions, source of the profile, prerequisites, exact checks run, results, and tests still outstanding. Distinguish source inspection/DTB compilation/flash dry-run from a real flash and hardware boot.
4. If binary DTBs are included, add reproducible source/build information and SHA-256 checksums. Avoid claiming a whole version family is verified after testing a single release.
5. Check selector results and shell tests:

   ```bash
   ./b_conf/flash_jetson.sh --list --jetpack-version 6.2.3
   bash tests/x86/test_b_conf_selector.sh
   bash tests/x86/test_jetson_flasher.sh
   ```

6. Run `--dry-run`, inspect the resolved package and payload, and validate the profile against the matching BSP before using a physical board. Update the compatibility journal with the result.

The installer adds missing files only. If a destination already exists with different bytes, installation stops rather than replacing it. Keep packages focused so the selector cannot silently choose incompatible board data.

## 6. Optional OP-TEE warning suppression

The optional patch changes two test-key warning calls from `IMSG` to `DMSG`; with NVIDIA's default T234 OP-TEE log level they are omitted. Error messages are retained. This affects logging only and does not enable UEFI variable protection.

Build a candidate image without installing it:

```bash
export CROSS_COMPILE_AARCH64_PATH=/path/to/nvidia/aarch64-buildroot-toolchain
./b_conf/suppress_uefi_auth_warnings.sh --build
```

The tool extracts only the OP-TEE source archive for the current BSP, applies the patch in a temporary directory, builds OP-TEE, and validates warning/error strings. `--install` performs the build again, validates the result, asks before replacement, and installs it with a backup:

```bash
sudo --preserve-env=CROSS_COMPILE_AARCH64_PATH \
  ./b_conf/suppress_uefi_auth_warnings.sh --install
```

The installer asks before replacement and saves the original image as `tos-optee_t234.img.before-quiet-uefi-warnings`. Restore it with:

```bash
sudo ./b_conf/suppress_uefi_auth_warnings.sh --restore
```

Flash/reflash the device after installing the image. The change is not active on a board until the rebuilt TOS image is flashed. Build success and hardware boot must be validated separately.

## 7. Troubleshooting and validation

- **No matching profile:** pass the correct `--jetpack-version`, and check selector directory spelling and the required `<profile>.conf` file.
- **No matching archive pair:** ensure both NVIDIA archives use the same exact L4T release token and are beside `setup_jetson.sh`.
- **Profile collision:** inspect the differing BSP destination. Use a clean BSP when starting over, or deliberately reconcile the custom file; the installer protects differing vendor files.
- **Flash tool does not find the target:** verify USB Recovery mode, USB data connection, host permissions, and the selected board/root-device arguments.
- **Host patching fails:** review package installation output and the first failing command. `setup_debian.sh` modifies the extracted BSP's recovery-image script and, for the custom IDS 10G profile, its RCM/BCT configuration.
- **OP-TEE build stops early:** ensure the NVIDIA toolchain path contains the expected cross-compiler and that `device-tree-compiler`, `make`, Python 3, `patch`, and `ripgrep` are installed.

The x86 shell tests exercise profile selection and guarded flash command construction; they do not replace validation against each vendor BSP or a hardware flash/boot test.

## License

Project files are distributed under the MIT License in the repository root. NVIDIA and other third-party files retain their own notices and licenses.
