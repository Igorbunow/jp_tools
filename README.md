# Jetson Linux tools for Debian 13

**English** | [Русский](README.ru.md)

Utilities and board configuration profiles for preparing and flashing NVIDIA Jetson Linux (L4T) on a **Debian 13 (Trixie) x86_64 host**. The repository automates host compatibility fixes, L4T deployment from NVIDIA archives, board-profile installation, and selected flash operations.

> This is a community project and is not an official NVIDIA product. NVIDIA's Jetson Linux R36.5 release notes list Ubuntu 20.04/22.04 x86_64 as supported host systems; Debian 13 compatibility here is provided by this project and is not NVIDIA certification. Review the selected board profile and compatibility record before flashing hardware. See the [NVIDIA release notes](https://docs.nvidia.com/jetson/archives/r36.5/ReleaseNotes/Jetson_Linux_Release_Notes_r36.5.pdf).

## What is included

- `setup_jetson.sh` — deploys a matching L4T and Sample Root Filesystem archive pair, applies NVIDIA binaries, creates the default user, installs the selected board profile, applies Debian host fixes, and configures optional UART root autologin.
- `setup_debian.sh` — installs required host packages and patches L4T scripts for Debian compatibility.
- `b_conf/` — board profiles, compatibility journals, profile selector, and flashing utilities.
- `b_conf/flash_jetson.sh` — lists profiles for a JetPack version, checks USB Recovery before installing a profile, and flashes a complete image, both DTB slots, or only rootfs. Interactively, it offers retry or quit if Recovery is absent.
- `b_conf/suppress_uefi_auth_warnings.sh` — optional OP-TEE source patch/build/install helper for the two test UEFI key warnings.

## Requirements

- Debian GNU/Linux 13 (Trixie), x86_64.
- Internet access and `sudo` access for package installation and L4T setup.
- NVIDIA Jetson Linux (L4T) and Sample Root Filesystem archives for the same release. Download them from NVIDIA and place both beside `setup_jetson.sh`.
- Enough free disk space for the archives, extracted BSP, and root filesystem. Check available space with `df -h`; the required amount depends on release, archive sizes, and deployment directory.
- For flashing, a supported Jetson connected in USB Recovery mode and the correct board profile.

Install the host dependencies:

```bash
sudo apt-get update
sudo apt-get install -y \
  git pv tar bzip2 sudo \
  abootimg xmlstarlet gdisk parted cpio gzip binutils \
  sshpass openssh-client
```

`setup_debian.sh` checks for and installs the L4T patching packages from this list. `qemu-user-static` is installed automatically only if you enter the optional QEMU chroot; it can also be installed manually. See the [full usage guide](docs/USAGE.en.md) for package roles, setup commands, profile management, and recovery steps.

## Quick start

Clone this repository and put the matching NVIDIA archives in its root directory. Specify both the JetPack version used to select a profile and, optionally, the exact L4T archive release:

```bash
./setup_jetson.sh \
  --jetpack-version 6.2.3 \
  --version R36.5.2 \
  --board jetson-agx-orin-devkit-noeeprom \
  --skip-qemu
```

The archive names must be `Jetson_Linux_R36.5.2_aarch64.tbz2` and `Tegra_Linux_Sample-Root-Filesystem_R36.5.2_aarch64.tbz2` for this example. Use the exact version tokens present in your downloaded filenames. If `--version` is omitted, the script selects the newest matching archive pair.

Before flashing, inspect the profile and confirm that the board is in USB Recovery mode:

```bash
./b_conf/flash_jetson.sh --list --jetpack-version 6.2.3
./b_conf/flash_jetson.sh \
  --board jetson-agx-orin-devkit-noeeprom \
  --mode full \
  --jetpack-version 6.2.3
```

The flashing utility asks for confirmation before writing. `--yes` is available for unattended use and bypasses that confirmation; use it only when the target and Recovery state have already been verified.

## Board profiles

Profiles live under `b_conf/`. The selector prefers an exact JetPack version, then a `major.minor.x` family, then `major.x`, then `common`. A package is a complete payload for that profile; packages are not merged. Each profile should include a `COMPATIBILITY.md` journal. See [Adding and maintaining board profiles](docs/USAGE.en.md#adding-a-board-profile) (English) and [Добавление профиля платы](docs/USAGE.ru.md#добавление-профиля-платы) (Russian).

The current `6.2.x` profiles were sourced from JetPack 6.2.3; the family selector does not mean every 6.2 release was tested. Check each profile's compatibility journal before use.

## Security notes

- `setup_jetson.sh` enables passwordless `root` login on the `ttyTCU0` UART console by default for debugging. Disable it with `--no-root-uart-login` when it is not required.
- `--force` removes an existing `Linux_for_Tegra` deployment before rebuilding it. Back up any data you need first.
- The optional OP-TEE warning patch only hides two test-key warnings at the default T234 log level. It does **not** enable UEFI variable protection or replace the test key.

## Documentation

- [Detailed usage and board-profile guide (English)](docs/USAGE.en.md)
- [Подробное руководство (русский)](docs/USAGE.ru.md)
- [Board configuration bundle notes](b_conf/README.md)

## License

This project is licensed under the [MIT License](LICENSE). Third-party NVIDIA files retain their original license and copyright notices.
