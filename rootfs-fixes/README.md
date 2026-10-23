# Rootfs release fixes

This tree contains declarative overlays for root filesystem issues that depend
on the JetPack release, target distribution, or distribution codename. The
setup script applies matching layers after BSP deployment and board-profile
installation, and before rootfs APT validation.

Directory layout:

```text
rootfs-fixes/
  common/<os-id>/{default,<codename>}/{files/,patches/}
  <jetpack-version>/<os-id>/{default,<codename>}/{files/,patches/}
```

The `default` distro directory applies to every codename for that OS. Version
selectors may be exact (`6.2.3`), minor family (`6.2.x`), major family
(`6.x`), or an exact major/minor (`6.2`, when `JETPACK_VERSION=6.2`). Layers
apply from common to broad to specific, so a more specific file can replace a
less specific copy. `files/` paths are relative to the rootfs and preserve the
source file mode. Symlink destinations are rejected. `patches/` accepts
`*.patch` files in `patch -p1` format; patches already applied are skipped.

Use this mechanism only for target-rootfs contents. Repository normalization
for NVIDIA's literal `<SOC>` placeholder is a built-in idempotent fix because
the SoC identifier comes from the selected BSP board configuration (or
`/etc/nv_boot_control.conf` when already present). It maps documented NVIDIA
chip IDs to their `t210`, `t186`, `t194`, and `t234` repository components.

No release-specific overlay is currently needed for the inspected JetPack
5.1.7, 6.2, 6.2.2, or 6.2.3 rootfs trees. Add a layer only when a reproducible
release/distro defect is found, and document the affected release and test
evidence alongside it.
