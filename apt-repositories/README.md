# Custom APT repository profiles

Profiles let an operator opt in to a repository set for a target root filesystem whose configured APT sources cannot be reached. They are read by `setup_jetson.sh` only when explicitly enabled with `--force-repositories` or `JETSON_FORCE_CUSTOM_REPOSITORIES=1`.

## Profile selection

The target `/etc/os-release` is read without executing it. The script first looks for an exact OS and codename match, then for an OS-wide default:

```text
apt-repositories/
└── <ID>/
    ├── <VERSION_CODENAME>/
    │   ├── *.list
    │   ├── *.sources
    │   └── sources.list
    └── default/
        └── ...
```

For example, a profile for Ubuntu Noble is `apt-repositories/ubuntu/noble/`; a fallback for all Ubuntu codenames is `apt-repositories/ubuntu/default/`. The exact codename profile takes priority. Files use APT's native one-line `.list` or Deb822 `.sources` format. `sources.list` is also accepted.

## Behavior and safety

The fallback checks the existing repositories first. A custom profile is considered only after that update fails and only with the explicit opt-in. For Ubuntu and Debian, the profile's sources are added while recognized official Ubuntu/Debian entries are disabled; NVIDIA and all other third-party sources remain enabled. For other APT-based distributions, no automatic source rewriting is attempted. Such a profile must contain a `replace-files` manifest naming the exact existing source files to replace, relative to `/etc/apt`, for example:

```text
sources.list.d/vendor-mirror.sources
```

Each manifest entry must be `sources.list` or a simple `.list`/`.sources` filename directly under `sources.list.d/`. A matching file in the profile replaces that target; if no matching profile file exists, the listed target is removed. Unlisted source files are preserved. Additional profile source files are installed alongside the existing sources.

Every candidate is validated with `apt-get -o APT::Update::Error-Mode=any update`, so transient or partial repository failures are not treated as success. If the custom candidate fails, Ubuntu/Debian then get an automatic official archive candidate. Only known official Ubuntu/Debian URIs are rewritten; suites, components, architecture filters, signing options, URI scheme, and unrelated sources are preserved. Debian archive entries receive a source-scoped `Check-Valid-Until: no` setting. A candidate is kept only after validation succeeds. If all candidates fail, original APT source files are restored and package upgrade/install is skipped.

Archive locations may not carry every suite or package version. The script does not guess a different codename. If no candidate validates, correct the target rootfs source configuration or add an operator-reviewed profile.

## Enable a profile

Interactive runs keep custom profiles disabled unless requested:

```bash
./setup_jetson.sh --force-repositories
```

For a batch run:

```bash
JETSON_FORCE_CUSTOM_REPOSITORIES=1 ./setup_jetson.sh -y --skip-qemu --apt-upgrade
```

The option only controls custom-profile use. Automatic Ubuntu/Debian archive fallback remains available after an APT update error regardless of this option.
