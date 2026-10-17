# Hi3798M V300 → Linux 6.18 LTS (arm64)

Forward-port of the HiSTBLinux V100R005C00SPC050 BSP kernel from **Linux 4.4.35**
to **Linux 6.18.57 LTS**, targeting the `hi3798mv3dmm` reference board.

## Status

Honest accounting of what has and has not been proven.

| Item | State |
|---|---|
| Kernel tree fetched, sha256 verified against kernel.org | ✅ done |
| Overlay paths map onto a real 6.18.57 tree | ✅ checked |
| `apply-overlay.sh` / `make-initramfs.sh` pass `bash -n` | ✅ done |
| Workflow YAML parses | ✅ done |
| Register windows cross-checked against mainline `hi3798cv200` | ✅ done |
| Vendor API drift quantified across 11 466 files | ✅ done |
| **Kernel compiles** (CI run 38997330115, 22m34s, all steps green) | ✅ **done** |
| **`Image` is a valid arm64 boot image** (magic `ARMd`, 47.4 MiB) | ✅ verified |
| **Device tree built and carries the right bindings** | ✅ verified |
| **initramfs built** (1.06 MiB static busybox) | ✅ verified |
| **Boots on hardware** | ❌ not yet |

Build artifacts of the verified run:

| Artifact | Size | Check |
|---|---|---|
| `Image` | 47.4 MiB | header magic `0x644d5241` (`ARMd`); `image_size` 48.2 MiB, the delta being BSS |
| `hi3798mv300-hi3798mv3dmm.dtb` | 3.3 KiB | `compatible = "hisilicon,hi3798mv300"`; `serial@{8b00000,8b02000,8b03000}` bound to `arm,pl011` |
| `initramfs.cpio.gz` | 1.06 MiB | static busybox |
| `kernel.config` | — | `Linux/arm64 6.18.57` |

All three binaries pass `sha256sum -c SHA256SUMS`.

> **Still unproven: everything past the compiler.** The kernel has never been
> executed. Compilation confirms the device trees and configuration are
> self-consistent, but says nothing about whether the firmware hands control
> to a 64-bit kernel, whether PSCI is actually implemented, or whether the
> memory map is right. See Risks — those are all hardware questions.
>
> Two configuration traps were found and fixed while getting this green, both
> of which fail *silently* rather than loudly:
> - `CONFIG_PSCI_FW` does not exist; the symbol is `ARM_PSCI_FW`.
> - `CONFIG_COMPAT_VDSO` additionally requires `CROSS_COMPILE_COMPAT` to point
>   at a 32-bit ARM toolchain, so CI installs `gcc-arm-linux-gnueabihf`.
>
> Note also that `ARM_GIC`, `ARM_GIC_V3`, `ARM_GIC_V5` and `ARM_PSCI_FW` are
> unconditionally `select`ed by `config ARM64` and cannot be disabled from a
> fragment. The device tree decides which GIC actually binds.

## Why this port is tractable

The 4.4 BSP device tree was audited node by node. Most of the silicon on the
boot path is **standard ARM IP with mainline drivers already present**:

| Block | Compatible in the BSP DTS | Mainline driver |
|---|---|---|
| Debug console | `arm,pl011` | `SERIAL_AMBA_PL011` ✅ |
| Interrupt controller | `arm,cortex-a9-gic` | `arm,gic-400` (GICv2) ✅ |
| Timers | `arm,armv7-timer` | `arm,armv8-timer` ✅ |
| GPIO | `arm,pl061` | `GPIO_PL061` ✅ |
| Watchdog | `arm,sp805-wdt` | `ARM_SP805_WATCHDOG` ✅ |
| SPI | `arm,pl022` | `SPI_PL022` ✅ |
| USB | `generic-{ehci,ohci,xhci}` | mainline ✅ |
| SATA | `generic-ahci` | `AHCI_PLATFORM` ✅ |

More importantly, the **MV300 and the mainline-supported CV200 sibling share
register layouts**, verified by diffing the two device trees:

| Block | BSP `hi3798mv300.dts` | mainline `hi3798cv200.dtsi` | Match |
|---|---|---|---|
| GIC distributor | `0xf1001000` | `0xf1001000` | identical |
| CRG (clock/reset) | `0xf8a22000` | `0xf8a22000` | identical |
| PERICTRL | `0xf8a20000` | `0xf8a20000` | identical |
| UART0 | `0xf8b00000`, SPI 49 | `0xf8b00000`, SPI 49 | identical |
| UART2 | `0xf8b02000`, SPI 51 | `0xf8b02000`, SPI 51 | identical |
| UART3 | `0xf8b03000`, SPI 52 | — | — |

That is what makes this a port rather than a from-scratch bring-up: the
`hi3798cv200.dtsi` and `crg-hi3798cv200.c` already in mainline are usable
blueprints, and `dt-bindings/clock/histb-clock.h` already exists upstream.

## ARM32 vs ARM64

The BSP builds 32-bit (`CFG_HI_32BIT_SYSTEM=y`). This port moves to **arm64**,
which the Cortex-A53 supports natively.

The usual objection to that move — "the whole userspace is AArch32" — is
mostly neutralised by `CONFIG_COMPAT=y` in
`porting/config/hi3798mv300.config`. A 32-bit ARM EL0 binary runs unmodified
on an arm64 kernel, so the existing rootfs and vendor `.so` files stay usable.
What must be ported is the **kernel-side** `source/msp` modules, which have to
be rebuilt against 6.18 regardless of the word size.

The real cost of arm64 is on the firmware side — see Risks.

## Layout

```
porting/
├── README.md                  this file
├── api-drift-report.md        generated: 4.4 → 6.18 API breakage census
├── scan_vendor_apis.py        the scanner that produces the above
├── config/
│   └── hi3798mv300.config     kernel config fragment (merged over arm64 defconfig)
├── overlay/                   copied verbatim into the kernel tree
│   └── arch/arm64/boot/dts/hisilicon/
│       ├── hi3798mv300.dtsi             SoC-level
│       └── hi3798mv300-hi3798mv3dmm.dts board-level
└── scripts/
    ├── apply-overlay.sh       overlay + idempotent DTS Makefile append
    └── make-initramfs.sh      static busybox initramfs that lands in a shell
.github/workflows/
└── kernel-6.18.yml            the only build path
```

The 1.7 GiB kernel tree is **not** in git. CI downloads and verifies
`linux-6.18.57.tar.xz` and applies `porting/overlay/` on top, so bumping to a
newer 6.18.y (or a later LTS) is a tarball swap rather than a merge.

## How to build

Locally: **don't.** Push and let CI do it.

```
Actions → kernel-6.18-hi3798mv300 → Run workflow
  kernel_version: 6.18.57     (any 6.x.y; sha256 is verified against
                               kernel.org's published sums)
```

Artifacts: `Image`, `hi3798mv300-hi3798mv3dmm.dtb`, `initramfs.cpio.gz`,
`kernel.config`, `SHA256SUMS`.

The workflow deliberately builds **device trees before the kernel Image** — a
DTS error then costs seconds instead of a full kernel build. Note that the
DTBs must go through the kernel's cpp+dts pipeline because the sources use
`#include <dt-bindings/...>`; plain `dtc` cannot resolve those.

## Stage 1 — reach a userspace shell

Scope of this commit. Delivers enough SoC support to reach a shell over the
PL011 debug UART:

- 4 × Cortex-A53, PSCI enable-method
- GIC-400, `arm,armv8-timer`
- UART0/2/3 as PL011, console on UART0 at 115200 8n1
- 1 GiB of memory (matches `…DDR3-1866_1GB_16bitx2_4layers.reg`)

**Clocks are deliberately fixed-clock placeholders.** The BSP fed the PL011s
from `clk_75m`; keeping that shape means the console comes up without waiting
on a CRG driver port. Replacing them is the first task of stage 2.

Expected boot line:

```
console=ttyAMA0,115200 earlycon=pl011,0xf8b00000
```

## Stage 2 — make it a usable board

Ordered by dependency, not by size:

1. **CRG driver.** Port `hi3798mv2x/clk-hi3798mv200.c` (311 lines) as a
   `crg-hi3798mv300.c` modelled on mainline `crg-hi3798cv200.c`, plus the
   per-peripheral clock drivers (`clk-hiusb2`, `clk-hiusb3`, `clk-hipcie`,
   `clk-hiahci`, `clk-higpu`). This unblocks everything else, and is why it
   is first.
2. **eMMC/SD** — `hi3798mv300,himciv200`, needed for a real rootfs.
3. **Ethernet** — the BSP uses `hisilicon,hieth` at `0xf9c30000`, which is
   *not* the same block as CV200's `hisi-gmac-v2` at `0xf9840000`. Expect
   real work here, not a rename.
4. Peripherals: I2C (`hisilicon,hi-i2c`), SPI, IR (`hix5hd2-ir`), USB PHYs,
   PCIe, SATA, thermal, `chiptrim`.

## Stage 3 — the media stack

This is the large one and is **out of scope** for the current effort.
`source/msp/drv` is 262 MB across 1 735 `.c` files, all written against 4.4
APIs. See `api-drift-report.md` for the census; headline numbers:

- **1 071 BLOCKER hits** (will not compile), 668 MAJOR, 988 MINOR
- The single worst offender is `set_fs()`/`get_fs()`, removed in 5.10 —
  **96 files**. The BSP uses the old "point userspace at kernel memory"
  trick instead of `copy_to_user()`. Each site needs a real replacement,
  so this is not a mechanical sed.
- Worst subsystems by distinct blocker rules: `wifi` (16),
  `gpu` (10), `bluetooth` (6), `vfmw` (5)

Suggested order for stage 3, cheapest-first: `keyled`/`ir`/`adac` (1 rule
each) → `demux`/`vi`/`adsp` → `vdec`/`venc` → `vo`/`vpss`/`hdmi` → `vfmw` →
`gpu`/`wifi` (these last two are effectively rewrites).

## Risks

Ranked by how likely they are to invalidate the approach, not by effort.

1. **Firmware may not boot an arm64 image.** This is the big one, and it
   cannot be settled without the board. The mv300 board configuration is
   32-bit (`CFG_HI_32BIT_SYSTEM=y`, `CFG_ARM_HISTBV320_LINUX=y`,
   `CFG_HI_LOADER_SUPPORT` unset). Switching the kernel to arm64 requires the
   boot chain — HiSilicon bootloader and, if present, ARM Trusted Firmware —
   to load and enter a 64-bit kernel. If it only ever enters AArch32, this
   port needs a matching 64-bit bootloader first. **Verify with the existing
   bootloader before investing in stage 2.**
2. **PSCI is assumed, not confirmed.** The BSP device tree declares
   `arm,psci-0.2`, but the 4.4 kernel did not use it — `mach-hi3798mv2x`
   carried custom `smp_ops`. arm64 has no such fallback: SMP requires working
   PSCI. If the firmware lacks it, the board may boot single-core only.
3. **The memory node is a first guess.** `reg = <0x0 0x0 0x0 0x40000000>`
   assumes a flat 1 GiB from 0. The BSP reserves windows for MMZ, TEE and the
   bootloader; those may need `reserved-memory` nodes. Symptoms would be
   random corruption rather than a clean failure.
4. **Cache geometry in the DT is informational.** The L2 `cache-size` in
   `hi3798mv300.dtsi` mirrors the CV200 4×A53 cluster and is only a hint; the
   kernel reads the real values from CLIDR/CCSIDR. Not a functional risk.
5. **`CONFIG_COMPAT` is load-bearing** for the "userspace keeps working"
   claim above. If the stage-1 config loses it, 32-bit userspace stops
   running — worth pinning in review.
