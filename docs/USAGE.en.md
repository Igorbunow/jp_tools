# Jetson tools: usage and board profiles

[Русская версия](USAGE.ru.md) · [Project overview](../README.md)

This guide covers the Debian host, L4T deployment, flashing, and adding board profiles.

## 1. Host and dependencies

The host environment targeted by this repository is **Debian GNU/Linux 13 (Trixie), x86_64**. Run the scripts from a regular account with working `sudo` access. Do not run the entire setup as root: the scripts request elevated access for operations that need it. NVIDIA's Jetson Linux R36.5 release notes list Ubuntu 20.04/22.04 x86_64 as supported host systems, so Debian support here is a community-maintained compatibility layer, not upstream certification ([NVIDIA R36.5 release notes](https://docs.nvidia.com/jetson/archives/r36.5/ReleaseNotes/Jetson_Linux_Release_Notes_r36.5.pdf)).

Install the packages used by the setup and Debian compatibility scripts:

```bash
sudo apt-get update
sudo apt-get install -y \
  git pv tar bzip2 sudo util-linux patch \
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
| `util-linux` | Provides `setpriv`, used to clear host supplementary groups before entering the rootfs chroot. |
| `patch` | Applies optional release-specific rootfs patches stored under `rootfs-fixes/`. |
| `abootimg`, `xmlstarlet`, `gdisk`, `parted`, `cpio`, `gzip` | Host tools checked by `setup_debian.sh` for L4T recovery-image generation. The `sgdisk` command is provided by `gdisk`. |
| `binutils` | Provides the `strings` command used by L4T tooling. |
| `sshpass`, `openssh-client` | Host SSH utilities expected by the L4T scripts; `ssh-keygen` is provided by `openssh-client`. |

`setup_debian.sh` checks and installs any missing packages in its patch-tool list. Core utilities such as Bash, `awk`, `sed`, `grep`, `find`, `install`, `md5sum`, and `mount` are expected from a normal Debian installation. An unrelated APT repository error may be reported; the script will still attempt to install packages from available indexes.

### Optional QEMU chroot

The optional chroot stage needs `qemu-user-static`. `setup_jetson.sh` installs it automatically if the stage is selected and the `qemu-aarch64-static` binary is missing. Use `--skip-qemu` to skip the interactive shell. Before entering the chroot or starting an APT operation, the script checks the temporary rootfs `/etc/resolv.conf`; if it has no active `nameserver` line, it adds `8.8.8.8` and `1.1.1.1`. Override these fallback addresses with a whitespace-separated `JETSON_QEMU_NAMESERVERS` value, for example `JETSON_QEMU_NAMESERVERS="9.9.9.9 149.112.112.112"`. An existing nameserver entry is preserved as-is. APT commands always run with `LANG=C`, `LC_ALL=C`, and `LANGUAGE=C`, so they do not inherit a host locale that is missing from the target rootfs. Debian may still print `debconf: delaying package configuration, since apt-utils is not installed`; that message is informational and does not indicate an APT failure. QEMU mounts are cleaned during normal completion and on handled termination signals; each mount actually removed is reported with a warning. On exit, the script scans the current `Linux_for_Tegra` deployment and warns before unmounting any remaining mounts below it, deepest-first, including stale NVIDIA loop mounts. If a normal unmount fails, the script warns and tries a lazy detach; cleanup failure is reported as an error. It preserves the deployment directory mount itself and mounts outside the deployment.

QEMU APT and interactive sessions share a per-deployment lock and record the active phase. On a normal exit, APT failure, or handled signal, mounts and the original resolver are restored before the lock is released. If a previous run left a live session or cleanup artifacts, interactive mode asks before terminating/recovering it. Batch mode stops safely unless `--force-qemu-cleanup` is supplied; that flag permits termination of the recorded `setup_jetson.sh` process and cleanup of its rootfs mounts/resolver state. Do not use the flag while another setup run is intentionally active.

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

Download the L4T Driver Package and Sample Root Filesystem for the **same L4T release**. By default, place both `.tbz2` files in `/opt/nvidia/jp/6.2.3`:

```text
Jetson_Linux_<L4T-release>_aarch64.tbz2
Tegra_Linux_Sample-Root-Filesystem_<L4T-release>_aarch64.tbz2
```

For example, JetPack 6.2.3 uses L4T R36.5.2 in this project's release history:

```text
Jetson_Linux_R36.5.2_aarch64.tbz2
Tegra_Linux_Sample-Root-Filesystem_R36.5.2_aarch64.tbz2
```

Use the filenames supplied by NVIDIA for your target release. The scripts do not download NVIDIA archives. `public_sources.tbz2` is optional and is extracted only if present in the archive directory under that exact name.

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

The default archive directory and deployment base directory are both `/opt/nvidia/jp/6.2.3`, producing `/opt/nvidia/jp/6.2.3/Linux_for_Tegra`. Set `--archive-dir PATH` and `--deploy-dir PATH` (or `JETSON_ARCHIVE_DIR` and `JETSON_DEPLOY_DIR`) to use separate locations. If only one is set, it becomes the shared path for both. The legacy `--dir PATH` remains an alias for `--deploy-dir`. `./setup_jetson.sh --print-paths` displays the resolved paths without starting deployment. Project resources such as `root_fs/`, `b_conf/`, and `setup_debian.sh` are always taken from the repository. The setup script extracts L4T and rootfs, runs `apply_binaries.sh`, creates the requested default user, copies the overlay, optionally extracts public sources, installs the selected `b_conf` payload, then applies Debian compatibility patches to the chosen L4T tree.

Before rootfs APT validation, setup normalizes a remaining NVIDIA repository `<SOC>` token from the selected board configuration (or the rootfs boot-control file if available). This covers releases where NVIDIA defers that substitution until first boot. Release-specific rootfs overlays can be added under [`rootfs-fixes/`](../rootfs-fixes/README.md), layered by JetPack selector, distribution ID, and codename. The resulting rootfs gets `/etc/jetson-image-info` with JetPack, L4T, distribution, and board-profile details.

On Ubuntu Noble, empty `bin.usr-is-merged`, `lib.usr-is-merged`, and `sbin.usr-is-merged` directories are part of the `base-files` usr-merge transition. They are expected package-managed paths, not temporary setup artifacts; keep them as shipped. Ubuntu lists `usr-is-merged` as a virtual package provided by `base-files` ([package index](https://packages.ubuntu.com/noble/usr-is-merged)).

Before rootfs APT validation, setup normalizes a remaining NVIDIA repository `<SOC>` token from the selected board configuration (or the rootfs boot-control file if available). This covers releases where NVIDIA defers that substitution until first boot. Release-specific rootfs overlays can be added under [`rootfs-fixes/`](../rootfs-fixes/README.md), layered by JetPack selector, distribution ID, and codename. The resulting rootfs gets `/etc/jetson-image-info` with JetPack, L4T, distribution, and board-profile details.

On Ubuntu Noble, empty `bin.usr-is-merged`, `lib.usr-is-merged`, and `sbin.usr-is-merged` directories are part of the `base-files` usr-merge transition. They are expected package-managed paths, not temporary setup artifacts; keep them as shipped. Ubuntu lists `usr-is-merged` as a virtual package provided by `base-files` ([package index](https://packages.ubuntu.com/noble/usr-is-merged)).

Debian compatibility patches are applied by default. When running on a host release that supports NVIDIA's tools, you can manually skip this step with `--skip-debian-patches` or `JETSON_SKIP_DEBIAN_PATCHES=1`. The environment variable accepts only `0` (default, apply patches) or `1` (skip). The script does not detect the host OS or change this choice automatically. For example:

```bash
JETSON_SKIP_DEBIAN_PATCHES=1 ./setup_jetson.sh --jetpack-version 6.2.3 --version R36.5.2
# or
./setup_jetson.sh --skip-debian-patches --jetpack-version 6.2.3 --version R36.5.2
```

Example with separate storage:

```bash
./setup_jetson.sh --archive-dir /srv/jetson/downloads --deploy-dir /opt/nvidia/jp/6.2.3 \
  --jetpack-version 6.2.3 --version R36.5.2 --skip-qemu
```

`setup_debian.sh` accepts `--l4t-dir PATH` (or `JETSON_L4T_DIR`) for a direct path to the target `Linux_for_Tegra`. `b_conf/flash_jetson.sh` accepts the same `--l4t-dir`, or `--deploy-dir PATH` to select `PATH/Linux_for_Tegra`; it also honors `JETSON_L4T_DIR` and `JETSON_DEPLOY_DIR`.

### Environment variables

The scripts also show these settings in their `--help` output:

| Variable | Used by | Purpose |
| --- | --- | --- |
| `JETSON_ARCHIVE_DIR`, `JETSON_DEPLOY_DIR` | `setup_jetson.sh`; `JETSON_ARCHIVE_DIR` also helps `b_conf/flash_jetson.sh` match older deployed L4T releases to an archive pair | Archive source and deployment base paths. If only one is set for setup, it supplies both. |
| `JETSON_L4T_DIR` | `setup_debian.sh`, `b_conf/flash_jetson.sh` | Exact `Linux_for_Tegra` directory; command-line `--l4t-dir` takes precedence. |
| `JETPACK_VERSION` | `setup_jetson.sh`, `b_conf/flash_jetson.sh` | Select/override the JetPack compatibility version. The flasher otherwise reads `/etc/jetson-image-info`, then tries BSP/archive path evidence. |
| `L4T_VERSION` | `setup_jetson.sh` | Select the matching L4T archive pair. |
| `JETSON_BOARD`, `JETSON_USER`, `JETSON_PASS`, `JETSON_HOST` | `setup_jetson.sh` | Default board profile and created user's name, password, and hostname. |
| `JETSON_SKIP_DEBIAN_PATCHES` | `setup_jetson.sh` | `1` skips host compatibility patches; default `0` applies them. |
| `JETSON_APT_UPGRADE`, `JETSON_APT_PACKAGES_FILE` | `setup_jetson.sh` | Enable batch rootfs APT update/upgrade and select its package list. |
| `JETSON_FORCE_CUSTOM_REPOSITORIES` | `setup_jetson.sh` | `1` permits configured custom APT profiles after repository validation fails. |
| `JETSON_QEMU_NAMESERVERS` | `setup_jetson.sh` | Space-separated fallback DNS servers for rootfs `/etc/resolv.conf`. |
| `JETSON_USB_SYSFS_ROOT` | `b_conf/flash_jetson.sh` | USB sysfs directory used to detect a board in Recovery; defaults to `/sys/bus/usb/devices`. |
| `JETSON_ROOTFS_SIZE` | `b_conf/flash_jetson.sh` | Optional APP/rootfs partition size (for example `8GiB`) or `max`; values above a known BSP maximum are rejected unless `--force-rootfs-size` is supplied. |
| `CROSS_COMPILE_AARCH64_PATH`, `TMPDIR` | `b_conf/suppress_uefi_auth_warnings.sh` | Required NVIDIA AArch64 Buildroot toolchain directory and temporary workspace parent (defaults to `/tmp`). |

`cleanup.sh` and `b_conf/select_config.sh` do not use environment variables. `b_conf/flash_jetson.sh` detects JetPack from the deployed rootfs `/etc/jetson-image-info`; for older images it can match the BSP's L4T release to the pair in `JETSON_ARCHIVE_DIR`, then falls back to version-named paths. It prints the detected version and its source. If none is available, only `common/` profiles are listed; set `JETPACK_VERSION` or pass `--jetpack-version` to override detection.

If `Linux_for_Tegra` already exists, interactive mode offers reuse or removal. `--force` removes it and rebuilds from the archives; this deletes all content under that deployment path. Back up any files you need first. In batch mode (`-y`), an existing deployment is reused unless `--force` is set.

In interactive mode, the script separately asks whether to run `apt-get update`, `apt-get upgrade -y`, and install the packages listed in `qemu-packages.txt` inside the target rootfs. The default list contains `mc` and `vim`; use one Debian package name per line, with blank lines and `#` comments allowed. Select a different list with `--apt-packages-file PATH` or `JETSON_APT_PACKAGES_FILE`.

Before APT runs, the script normalizes the leading blank lines and comments in NVIDIA's `nv-power-adapter-check` PAM profile. This avoids Perl warnings from `pam-auth-update` on profiles whose preamble it does not parse correctly.

Repository validation is displayed as its own numbered step before the separate rootfs package update step. Before upgrading or installing packages, the script validates all configured repositories with strict `apt-get -o APT::Update::Error-Mode=any update`. If this fails, it can try a matching custom repository profile, but only when explicitly enabled with `--force-repositories` or `JETSON_FORCE_CUSTOM_REPOSITORIES=1`. Profiles live under `apt-repositories/<OS ID>/<codename>/`, with `<OS ID>/default/` as a fallback. On Ubuntu and Debian, their profile sources replace only recognized official distro entries; NVIDIA and other third-party sources remain enabled. If that candidate also fails, the script tries the official Ubuntu/Debian archive endpoints. Other APT-based distributions are never rewritten automatically; custom profiles for them use an explicit `replace-files` manifest. A validated candidate is retained, while complete failure restores the original sources and skips upgrade/install. See [apt-repositories/README.md](../apt-repositories/README.md) for profile formats, manifest rules, and examples.

During the QEMU APT upgrade/install operation, setup temporarily pins `nvidia-l4t-*` packages to prevent BSP upgrades. NVIDIA package maintainer scripts can require the real board's `/proc/device-tree/compatible` and storage layout, which are unavailable in QEMU; on JetPack 6.2.2 this caused `nvidia-l4t-core`'s pre-install script to fail and left a partial package upgrade. The temporary preference is removed after success or failure and is also recovered during the next QEMU session if a process was forcibly terminated. The target's BSP packages remain at the versions supplied by the selected JetPack release.

For a non-interactive run, opt into the APT operation explicitly with `--apt-upgrade` or `JETSON_APT_UPGRADE=1`. Combine it with `-y --skip-qemu` to update and configure the rootfs without opening an interactive shell:

```bash
./setup_jetson.sh -y --skip-qemu --apt-upgrade \
  --apt-packages-file ./qemu-packages.txt \
  --jetpack-version 6.2.3 --version R36.5.2
```

Without that opt-in, batch mode does not run APT updates. The APT operation uses non-interactive `apt-get` flags and stops if package-list validation or any APT command fails.

After the APT prompt/action, interactive mode asks whether to enter the QEMU chroot shell unless `--skip-qemu` is set. In silent mode (`-y`) the shell is entered automatically unless skipped, so combine `-y --skip-qemu --apt-upgrade` for a fully automated APT update without opening a shell. UART root autologin is applied after both optional steps, even if an optional step fails.

### Default user and root UART login

The script runs NVIDIA's `tools/l4t_create_default_user.sh` before setting UART login behavior. By default, it installs a systemd getty drop-in that enables passwordless root login on `ttyTCU0` for debugging. Disable or remove this setting by adding the flag to your deployment command, for example:

```bash
./setup_jetson.sh --jetpack-version 6.2.3 --version R36.5.2 \
  --board jetson-agx-orin-devkit-noeeprom --skip-qemu --no-root-uart-login
```

This option is applied after user creation and both optional QEMU/APT steps. Passwordless root access is intended for controlled development hardware; turn it off for deployed devices.

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

The default root device is `mmcblk0p1`. Specify another device with `--rootdev DEVICE` if the target configuration requires it. The utility prints the rootfs partition size before flashing. By default it uses the selected BSP/profile setting, which may intentionally be a smaller debug size; it does not treat that default as the maximum. Override it with `--rootfs-size 16GiB` or `JETSON_ROOTFS_SIZE=16GiB`. Use `--rootfs-size max` or `JETSON_ROOTFS_SIZE=max` to select a known limit from the BSP's shared board configuration or a profile `ROOTFS_SIZE` metadata file. If a profile can target modules with different capacities and its maximum cannot be determined, use `--force-rootfs-size 16GiB`; this also overrides a known limit and prints a warning. Without that option, explicit sizes above a known limit or with an unknown limit are rejected before profile installation or flashing. Full and rootfs modes pass the chosen size to `flash.sh` as `-S` and `IDS_ROOTFS_SIZE`; DTB-only mode reports the configured size but does not write rootfs. `JETSON_DEPLOY_DIR` selects `PATH/Linux_for_Tegra`; `JETSON_L4T_DIR` selects the exact BSP path and takes precedence. The flasher reads JetPack from the deployed image metadata, so the deployment directory may have any name. Examples:

```bash
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode full --rootfs-size 16GiB
JETSON_ROOTFS_SIZE=max ./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode full
./b_conf/flash_jetson.sh --board jetson-agx-orin-devkit-noeeprom --mode full --force-rootfs-size 16GiB
```

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
