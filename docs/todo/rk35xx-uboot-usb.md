# USB in our U-Boot

Family-wide. Our U-Boot is mainline `v2026.10` + `generic-rk3528_defconfig`:
`# CONFIG_USB is not set`, `CONFIG_NO_NET=y`. Once it runs, serial is the only interface; the
factory U-Boot it replaces served rockusb.

**Until this is done, never write to an SD-less box without serial attached.**

## What it buys, in order of value

1. **`ums`:** the eMMC as a USB block device, so `dd`, `mount`, `fsck` and `cp` work on one file or
   one partition instead of a full-disk transfer. The trigger exists already: every tree declares
   `mode-ums = <0x5242c30c>`, and mainline's `setup_boot_mode()` answers it with `ums mmc 0`, so
   `sudo reboot ums` needs only the Kconfig and the USB nodes.
2. **USB host boot:** kernel, DTB and rootfs from a stick, the SD substitute on a board with no
   slot. U-Boot itself still loads from eMMC: the factory SPL boots only mmc and spi.
3. **`rockusb`:** mainline's `f_rockusb.c` has no 32 MiB read limit; that is a Rockchip-downstream
   addition. A better Loader mode than the box shipped with, and no patch.

As rescue it covers one case only, Linux dead with U-Boot alive: a dead U-Boot takes `ctrl+b` to the
BootROM, a dead SPL takes the CLK short, as before.

## Scope

| Change                       | A board with SD | The 3518D, no SD         |
| ---------------------------- | --------------- | ------------------------ |
| USB PHY + controllers + VBUS | optional        | required                 |
| `bootcount` / `altbootcmd`   | useful          | most valuable: no button |

- **Nodes:** mainline's `rk3528.dtsi` has no USB controller or PHY. The factory tree has them,
  `boards/h96max-3518d/factory_board.dts`: `dwc3@fe500000`, `usb@ff100000` (EHCI), `usb@ff140000`
  (OHCI), `usb2-phy@ffdf0000`, `combphy@ffdc0000`. The controllers are SoC-level and shared; the
  VBUS regulators are per board, and a wrong OTG GPIO fails silently with no VBUS: pin 18 on the
  R69, 12 on the H96 Max boards.
- **Sockets on the 3518D:** USB-C is OTG (`dwc3`, the gadget side); USB-A is the EHCI/OHCI pair, so
  a boot stick there needs EHCI and OHCI.
- **Config:** `radxa-e20c-rk3528_defconfig`, the same SoC, is the template, plus `USB_OHCI_HCD` and
  `USB_OHCI_GENERIC`:

```
CONFIG_USB=y                         CONFIG_USB_GADGET=y
CONFIG_USB_XHCI_HCD=y                CONFIG_USB_GADGET_DOWNLOAD=y
CONFIG_USB_DWC3=y                    CONFIG_USB_FUNCTION_ROCKUSB=y
CONFIG_USB_DWC3_GENERIC=y            CONFIG_CMD_ROCKUSB=y
CONFIG_USB_EHCI_HCD=y                CONFIG_CMD_USB=y
CONFIG_USB_EHCI_GENERIC=y            CONFIG_CMD_USB_MASS_STORAGE=y
CONFIG_PHY_ROCKCHIP_INNO_USB2=y      CONFIG_DM_REGULATOR_GPIO=y
CONFIG_PHY_ROCKCHIP_NANENG_COMBOPHY=y
```

## Falling back to rockusb without Linux

| Failure                             | Covered by                                                   |
| ----------------------------------- | ------------------------------------------------------------ |
| No bootable media                   | `bootcmd = "bootflow scan -lb; rockusb 0 mmc 0"`             |
| Boots, Linux never comes up healthy | `bootcount` + `bootlimit` + `altbootcmd = "rockusb 0 mmc 0"` |

`BOOTCOUNT_SYSCON` into a GRF scratch register survives a warm or watchdog reset and clears on power
loss. Userspace clears it once healthy. A hung kernel advances it only if U-Boot autostarts the
watchdog before handing off.

`reboot loader` is ❌: mainline's `setup_boot_mode()` handles only `BOOT_FASTBOOT` and `BOOT_UMS`.
`reboot maskrom` already covers a booted OS, so it is not worth a code patch.

## Next

- Port the nodes and the config; confirm the FIT still fits its 2 MiB slot.
- ❓ whether `ums` reaches the eMMC on this SoC, or only an SD.
- The rk3528 USB nodes are SoC-level, so they are worth sending to mainline.
