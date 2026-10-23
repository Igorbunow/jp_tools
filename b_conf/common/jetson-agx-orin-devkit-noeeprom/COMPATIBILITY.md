# `jetson-agx-orin-devkit-noeeprom` compatibility journal

This profile sources NVIDIA's `jetson-agx-orin-devkit.conf` and changes only
`MB2_BCT` to a board-specific MB2 BCT. The BCT sets
`cvb_eeprom_read_size = <0x0>`; CVM/module EEPROM reads remain enabled.

| JetPack | L4T tree | Profile source + BCT compile | `flash.sh --no-flash` | Hardware boot without carrier EEPROM |
| --- | --- | --- | --- | --- |
| 5.1.7 | R35.6.5 | Passed | Passed | Not yet verified |
| 6.2 | Installed BSP | Passed | Not run | Not yet verified |
| 6.2.2 | Installed BSP | Passed | Not run | Not yet verified |
| 6.2.3 | Installed BSP | Passed | Not run | Not yet verified |
| 7.2.1 | Installed BSP | Passed | Not run | Not yet verified |

The R35 dry run selected the `t186ref/BCT` variant. The other releases
selected the `generic/BCT` variant. This journal records host-side checks;
successful boot on the physical carrier still needs confirmation.
