# Compatibility record

- Profile: IDS AGX Orin, 10G + 4 PCIe RTL8111 + RGMII + x4 NVMe + DP.
- Source: `/opt/nvidia/jp/6.2.3/b_conf` and the matching
  `/opt/nvidia/jp/6.2.3/Linux_for_Tegra` MB2 BCT source.
- Declared platform: JetPack 6.2.3 / L4T R36.5.2.
- Intended selector: `6.2.x`.

## Validation history

| JetPack | Result | Evidence |
| --- | --- | --- |
| 6.2.3 | Source-package validation passed | Profile config and all custom references were matched to source files; custom 32-bit and 64-bit DTB SHA-256 values match `CHECKSUMS_10g_4eth_pci_nvme_dp.sha256` from the source bundle. |
| Other 6.2.x releases | Not independently tested | The family selector is used for convenience; validate against the exact BSP before flashing. |

The package includes the MB2 BCT file selected by the profile config and its
EEPROM override include. The vendor BSP's referenced base BCT files remain
provided by the target BSP.
