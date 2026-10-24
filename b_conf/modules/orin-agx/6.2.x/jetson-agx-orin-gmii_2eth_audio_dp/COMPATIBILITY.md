# Compatibility record

- Profile: IDS AGX Orin, GMII + 2 Ethernet + audio + DP.
- Source: `/opt/nvidia/jp/6.2.3/b_conf`.
- Declared platform: JetPack 6.2.3 / L4T R36.5.2.
- Intended selector: `6.2.x`.

## Validation history

| JetPack | Result | Evidence |
| --- | --- | --- |
| 6.2.3 | Source-package validation passed | The profile config's custom pinmux, pad-voltage, GPIO-default and 32-bit/64-bit DTB files are present in this package. |
| Other 6.2.x releases | Not independently tested | The family selector is used for convenience; validate against the exact BSP before flashing. |

No full flash or hardware boot test is recorded for this package.
