# H96 Max M20 — device tree

The factory tree is `stock/h96max-m20/board.dtb`, entry 5 of the Amlogic multi-DTB container
(`gxlx2` / `p291` / `2g`). The candidate mainline tree is `meson-gxlx-s905l-p271.dtb`, shipped in
official Armbian's `meson64` set — the only `gxlx` tree in mainline.

Both were sorted through the patched `dtc` (`-s -I dtb -O dts`) and compared by node path. The
bindings differ completely, a vendor 4.9 tree against mainline, so the comparison is by address.

## Same silicon, renamed by the binding change

| Function | Factory             | Mainline       | Address      |
| -------- | ------------------- | -------------- | ------------ |
| eMMC     | `emmc@d0074000`     | `mmc@74000`    | `0xd0074000` |
| SD slot  | `sd@d0072000`       | `mmc@72000`    | `0xd0072000` |
| SDIO     | `sdio@d0070000`     | `mmc@70000`    | `0xd0070000` |
| USB 3    | `dwc3@c9000000`     | `usb@c9000000` | `0xc9000000` |
| USB PHY  | `usb2phy@d0078000`  | `phy@78000`    | `0xd0078000` |
| IR       | `rc@c8100580`       | `ir@580`       | `0xc8100580` |
| SARADC   | `saradc`            | `adc@8680`     | `0xc1108680` |
| GPU      | `mali@d00c0000`     | `gpu@c0000`    | `0xd00c0000` |
| Ethernet | `ethernet@c9410000` | same           | `0xc9410000` |

The four buses rename the same way — `aobus`, `cbus`, `periphs` and `hiubus` all become `bus@`.

The eMMC is 8-bit and non-removable in both, the SD slot 4-bit removable, and the SDIO controller
4-bit non-removable with `sd-uhs-sdr50`, `keep-power-in-suspend` and an `mmc-pwrseq` — which suits
the MT7668 running SDR50 at 50 MHz.

## What mainline adds

`hdmi-tx@c883a000`, `cec@100`, `vpu@d0100000`, `video-codec@c8820000`, two `audio-controller`s,
`crypto@c883e000`, `rng@0`, `rtc@a8` and `ethernet-phy@8` — blocks the vendor tree either describes
through its own bindings or leaves out.

## What has no mainline counterpart

| Missing          | Factory node                      |
| ---------------- | --------------------------------- |
| LEDs             | `gpioleds`, `sysled`              |
| IR key table     | `gpio_keypad`, `key_0`–`key_18`   |
| Wi-Fi / BT power | `wifi`, `bt-dev`, `wifi_pwm_conf` |
| Thermal sensor   | `aml-sensor@0`                    |

Nothing lights without an LED node. The IR receiver is present, so only the key map is board data.
`mmc@70000` already carries an `mmc-pwrseq`, so the Wi-Fi gap may be smaller than it looks. ❓
Whether mainline has a thermal sensor for this SoC is untested.

The vendor key store — `unifykey`, `efusekey`, `securitykey`, `defendkey` — has no mainline analogue
and needs none: seventeen of the nineteen slots on this box are empty.

## Where they genuinely differ

| Difference      | Factory      | Mainline p271      | Consequence                              |
| --------------- | ------------ | ------------------ | ---------------------------------------- |
| RAM in the tree | 2 GB variant | `0x40000000`, 1 GB | half the memory unless U-Boot patches it |
| SoC compatible  | `gxlx2`      | `meson-gxlx`       | no `gxlx2` compatible exists mainline    |
| Board           | `p291`       | `p271`             | a development board, not this box        |

The factory container carries `gxlx`/`p271` **and** `gxlx2`/`p291` entries side by side, so the two
platforms are siblings and the SoC gap is small. Every block a boot depends on — storage, USB,
Ethernet, serial — is present at the same address.

## How the tree is built

`stock/h96max-m20/board.dtb` is the base, as on every other board: `build-board-dts.sh` decompiles
it with the patched `dtc` and applies `firmware/h96max-m20/board.patch`. The tree describes this
board and the board has not changed — what changes is the driver that reads it, so the patch says
what each modern binding needs and why.

The mainline `meson-gxlx-s905l-p271.dtb` is the **reference** for what a node should look like,
never the base: p271 is a different board.

| Hunk            | Reason                                                        |
| --------------- | ------------------------------------------------------------- |
| `reset@4404`    | `meson-gx-mmc` takes a reset line; the vendor tree has none   |
| `clkc_AO`       | `meson-gx-uart` needs a `pclk` from the AO clock controller   |
| `uart_AO`       | three named clocks where the vendor had one `clk_uart`        |
| `sd_emmc_a/b/c` | mainline gate numbers and a reset; board properties untouched |

Node names stay as the vendor wrote them — Linux binds on `compatible`, not on names, so renaming
would be churn without a reason.

What the vendor tree already gets right, and the patch therefore leaves alone: the clock controller
is `amlogic,gxl-clkc`, an exact mainline match; the MMC nodes already carry mainline's `"core"`,
`"clkin0"`, `"clkin1"` clock names; the CPUs use `enable-method = "psci"`; and the GIC is
`arm,cortex-a15-gic`, which mainline still supports.

## Pinctrl: one word per controller

The vendor tree names the SoC variant in the binding:

| Node          | Stock                                | Patched                             |
| ------------- | ------------------------------------ | ----------------------------------- |
| `pinctrl@14`  | `amlogic,meson-gxlx-aobus-pinctrl`   | `amlogic,meson-gxl-aobus-pinctrl`   |
| `pinctrl@4b0` | `amlogic,meson-gxlx-periphs-pinctrl` | `amlogic,meson-gxl-periphs-pinctrl` |

Mainline's driver table has no `gxlx` entry, so neither controller bound, no pin group existed, and
`sd`, `sdio` and `emmc` all sat in deferred probe naming a supplier that never appeared — which is
what kept Wi-Fi off, the MT7668 being an SDIO part.

Nothing else had to change. The stock groups are already written the way mainline reads them —
`mux { groups; function; }` — and every name they use (`emmc_ds`, `sdio_d0`–`d3`, `sdio_clk`,
`sdio_cmd`, `sdcard_*`, functions `emmc`/`sdio`/`sdcard`) is in mainline's GXL pin data verbatim.
The bank registers match too; only `gpio-ranges` is absent, which costs GPIO-by-pin lookups and so
the LEDs, not pin muxing.

## Every remaining vendor compatible, corrected

Diffing against mainline's `meson-gxl-s905x-libretech-cc.dtb` node by node, matched on unit address,
found sixteen compatibles that differ. Two were the pinctrl pair above; the other fourteen bound no
driver at all, three of them on nodes that are `status = "okay"`:

| Node                          | Stock                  | Patched                                              |
| ----------------------------- | ---------------------- | ---------------------------------------------------- |
| `cpu@0`–`cpu@3`               | + `arm,armv8`          | `arm,cortex-a53` alone; `arm,armv8` is deprecated    |
| `serial@4e0`                  | `amlogic, meson-uart`  | `amlogic,meson-gx-uart`, `amlogic,meson-ao-uart`     |
| `serial@84c0` `@84dc` `@8700` | `amlogic, meson-uart`  | `amlogic,meson-gx-uart`                              |
| `i2c@8500` `@87c0` `@87e0`    | `amlogic,meson-gx-i2c` | `amlogic,meson-gxbb-i2c`                             |
| `pwm@550`                     | `amlogic,gx-ao-pwm`    | `amlogic,meson-gxbb-pwm-v2`, `amlogic,meson8-pwm-v2` |
| `pwm@8550` `@86c0`            | `amlogic,gx-ee-pwm`    | same as above                                        |

The console was never affected: it is `uart_AO` at `4c0`, which this patch already carried, and the
boot log shows `c81004c0.serial: ttyAML0 … is a meson_uart`. The four vendor-spelled UARTs are its
idle siblings.

Two more were wrong about the silicon rather than about spelling, and neither shares a unit address
with the mainline board, so only a sweep of every compatible found them:

| Node      | Stock                | Patched              | Why                                                 |
| --------- | -------------------- | -------------------- | --------------------------------------------------- |
| `arm_pmu` | `arm,cortex-a15-pmu` | `arm,cortex-a53-pmu` | these are A53s; the A15 model maps the wrong events |
| `timer`   | `arm,armv7-timer`    | `arm,armv8-timer`    | same driver entry, but this core is ARMv8           |

Two further live nodes carried vendor spellings at addresses mainline does not use — `pwm@8640`
(`status = "okay"`) and `i2c@8d20` — and take the same replacements as their siblings above.

What is left has no mainline counterpart at all: about 85 vendor compatibles covering the Android
multimedia stack, `ion`, `secmon`, `unifykey`, the DVB and codec nodes, and the Android partition
descriptions. Those are the remainder of the port, not mis-spellings, and they are left alone.

## What made the storage and clocks work

| Node          | Change                                    | Without it                                   |
| ------------- | ----------------------------------------- | -------------------------------------------- |
| `clkc`        | `clocks = <&xtal>`, drop the vendor `reg` | every PLL recalculates as 0 Hz               |
| `emmc` `sdio` | a pinctrl state named `default`           | Linux muxes nothing; the bus is unconfigured |
| `emmc`        | 200 MHz → 50 MHz                          | HS200 timing on a 3.3 V rail                 |
| `sdio`        | 100 MHz → 50 MHz                          | SDR104 timing on a 3.3 V rail                |
| both          | `vmmc-supply`/`vqmmc-supply`              | "no support for card's volts"; no card       |
| `sdio`        | `mmc-pwrseq-simple` + `pwm-clock`         | no 32 kHz clock for the radio                |

**`cap-sdio-irq` is not set, deliberately.** The vendor caps list asks for `MMC_CAP_SDIO_IRQ` and
the factory tree does not, and with it the part's firmware events arrive late or not at all: the
first scan after load returns nothing, association never completes, and a connection that does form
runs at ~320 ms with 10-20% loss. Without it the host falls back to `ksdioirqd` polling and the same
box associates in 3 s at 11 ms. Both Wi-Fi drivers and `btmtksdio` were affected.

**`default` is the only pinctrl state Linux applies.** The vendor names its states for its own
driver's lookup — `emmc_clk_cmd_pins`, `sdio_all_pins` — so none of them is applied at probe. The
eMMC survived that only because the bootloader had already muxed its pins; the SDIO bus, which no
bootloader touches, was electrically dead. The eMMC's first state is also the wrong one to promote:
it muxes clk and cmd alone, and the eight data lines are in `emmc_conf_pull_up`.

**The clock controller is the one that mattered most.** Mainline's `gxl-clkc` takes its regmap from
the parent syscon and its reference from `clocks = <&xtal>`. The vendor node has neither, and
without the crystal every PLL parent resolves to nothing: `fixed_pll`, `sys_pll` and every
`fclk_divN` read 0 Hz while the hardware was running normally, because BL2 had programmed it. The
eMMC ran at 201 kB/s until this was fixed, and at 45 MB/s after.

## The 32 kHz sleep clock needs clk81, not the crystal

Both halves of the combo chip run their low-power timing off the 32.768 kHz clock the SoC feeds them
on GPIOX_16. It is generated by a PWM, and the PWM can only divide its parent by a whole number:

| Parent             | Best divisor | Result      | Error    |
| ------------------ | ------------ | ----------- | -------- |
| `xtal`, 24 MHz     | 732          | 32786.89 Hz | +577 ppm |
| `clkc 0x0c`, clk81 | 5086         | 32769.69 Hz | +52 ppm  |

The factory tree reaches the same accuracy a different way, alternating two PWM channels of 733 and
732 crystal periods in an 8:12 ratio, which mainline's `pwm-clock` cannot express. Giving the PWM
clk81 as its first parent gets there with one number. Measured on the box: 30500 ns before, 30515 ns
after, against 30517.6 ns ideal.

±577 ppm is outside what these radios expect of a sleep clock; ±52 ppm is comfortably inside. This
did not by itself fix the association failure.

## Pin numbers do not carry over

The vendor's GXLX pinctrl and mainline's meson-gxl do not number the periphs bank alike: GPIOH has
13 pins there and 10 here, so every pin from BOOT upward sits three lower in mainline. A vendor pin
index copied into our tree lands on the wrong pad and the node does nothing.

| Function            | Factory property     | Vendor pin | Mainline |
| ------------------- | -------------------- | ---------- | -------- |
| combo chip power-on | `wifi/power_on_pin`  | 88         | 85       |
| Bluetooth enable    | `bt-dev/gpio_en`     | 99         | 96       |
| Wi-Fi host wake     | `wifi/interrupt_pin` | 100        | 97       |
| second LED          | `gpioleds/sys_red`   | 76         | 73       |

Read the number off a mainline tree for the same SoC, or off
`/sys/kernel/debug/pinctrl/pinctrl@4b0-pinctrl-meson/pins` on the box. Both name the pin.

`sdio_pwrseq` drives GPIOX_6 and GPIOX_17 as active-low resets, so the combo chip is powered down
and back up on every MMC power cycle. Without that the part keeps whatever state the last boot left
it in, and the firmware download fails in a different place each time.

The board has one two-pin LED. The factory tree describes two, and the second is very likely not
fitted — that tree is a generic Amlogic reference carrying blocks this box does not have.

## Still to convert
