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
| **initramfs built, with a target-architecture busybox** | ✅ verified *after a fix — see below* |
| **Board can enter the kernel this produces** | ❌ **no — boot chain not delivered** |
| **Boots on hardware** | ❌ not yet |

Build artifacts of the verified run:

| Artifact | Size | Check |
|---|---|---|
| `Image` | 47.4 MiB | header magic `0x644d5241` (`ARMd`); `image_size` 48.2 MiB, the delta being BSS |
| `hi3798mv300-hi3798mv3dmm.dtb` | 3.3 KiB | `compatible` contains `hisilicon,hi3798mv300`; `serial@{8b00000,8b02000,8b03000}` bound to `arm,pl011`; uart0 `okay` |
| `initramfs.cpio.gz` | 1.06 MiB | static **aarch64** busybox |
| `kernel.config` | — | `Linux/arm64 6.18.57` |

> **Correction: the first two runs shipped a broken initramfs, and this table
> called it verified.** CI packed the *runner's* x86-64 `/bin/busybox` into an
> arm64 initramfs. The arm64 kernel cannot exec it (`ENOEXEC`), every init
> path fails, and the boot dies with "No working init found" — while the
> pipeline stayed green across two runs. The only check in place verified
> *static linking*, never *architecture*.
>
> This is the failure mode the audit was aimed at, and it is the reason
> `make-initramfs.sh` now asserts the ELF machine, CI cross-builds busybox
> with `aarch64-linux-gnu-gcc` instead of trusting a host binary, and a
> "Verify artifact contents" step inspects what is actually inside the
> archive. Everything below marked "verified" is verified *by that check*,
> not by a file existing.

The build is deterministic where it matters. A second run (38998979429) was
made after removing a dead `CONFIG_ARM_GIC_V3=n` line to confirm it changed
nothing:

| Output | run 38997330115 | run 38998979429 | Verdict |
|---|---|---|---|
| `.config` | `edd876a7…` | `edd876a7…` | byte-identical |
| DTB | `97dd1e31…` | `97dd1e31…` | bit-identical |
| `Image` | `89be6fef…` | `51292938…` | differs **only** in the embedded build timestamp (`Sat Oct 17 03:26:02` vs `03:51:55 UTC 2026`); same size, same compiler, same version |

So the `Image` and `initramfs.cpio.gz` hashes are *not* reproducible across
runs — the kernel embeds a build date and cpio records file times. Compare
`.config` or the DTB when checking whether a change altered behaviour.

> **Still unproven: everything past the compiler.** The kernel has never been
> executed. Compilation confirms the device trees and configuration are
> self-consistent, but says nothing about whether the firmware hands control
> to a 64-bit kernel, whether PSCI is actually implemented, or whether the
> memory map is right. See Risks — those are all hardware questions.
>
> Three configuration traps were found while getting this green. All three
> fail *silently* rather than loudly, which is why each now has an explicit
> assertion rather than a comment:
> - `CONFIG_PSCI_FW` does not exist; the symbol is `ARM_PSCI_FW`.
> - `CONFIG_COMPAT_VDSO` additionally requires `CROSS_COMPILE_COMPAT` to point
>   at a 32-bit ARM toolchain, so CI installs `gcc-arm-linux-gnueabihf`.
> - `CONFIG_VT=n` was silently discarded: `VT` is promptless while `EXPERT` is
>   off, so Kconfig ignores the value and the shipped kernel has `VT=y`.
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
| GPIO | `arm,pl061` | `GPIO_PL061` ✅ |
| Watchdog | `arm,sp805-wdt` | `ARM_SP805_WATCHDOG` ✅ |
| SPI | `arm,pl022` | `SPI_PL022` ✅ |
| USB | `generic-{ehci,ohci,xhci}` | mainline ✅ |
| SATA | `generic-ahci` | `AHCI_PLATFORM` ✅ |

**The system timer is the exception, and an earlier revision of this file got
it wrong.** The BSP's `arm,armv7-timer` node is `#if 0`'d out
(`hi3798mv300.dts:416-425`) and the shipped kernel runs a vendor timer instead
(`CONFIG_TIMER_HISP804=y`, `timer@hisp804` at `0xf8a29000`; defconfig:951).
There is **no mainline hisp804 driver**, so the architected timer is this
port's only clocksource and it has no fallback. It should work — a Cortex-A53
always integrates the generic timer, cv200 uses the byte-identical node, and
firmware programs `CNTFRQ` to 24 MHz — but that is a hardware checkpoint, not
a verified fact. Do not add `clock-frequency`: `CNTFRQ` is authoritative.

More importantly, the **MV300 and the mainline-supported CV200 sibling share
register layouts**, verified by diffing the two device trees:

| Block | BSP `hi3798mv300.dts` | mainline `hi3798cv200.dtsi` | Match |
|---|---|---|---|
| GIC distributor | `0xf1001000` | `0xf1001000` | identical |
| GIC CPU interface | `0xf1002000` | `0xf1002000` | identical |
| CRG (clock/reset) | `0xf8a22000` | `0xf8a22000` | identical, **but not implemented here** |
| PERICTRL | `0xf8a20000` | `0xf8a20000` | identical, **but not implemented here** |
| UART0 | `0xf8b00000`, SPI 49 | `0xf8b00000`, SPI 49 | identical |
| UART2 | `0xf8b02000`, SPI 51 | `0xf8b02000`, SPI 51 | identical |
| UART3 | `0xf8b03000`, SPI 52 | *cv200 has no uart3* | BSP-only |

Two caveats an earlier revision of this file glossed over. The CRG and
PERICTRL rows describe hardware that genuinely matches, but stage 1 does not
instantiate either node — it uses fixed-clock placeholders — so they are not
part of the delivered port. And `uart3` has no cv200 counterpart, so its
provenance is the BSP alone, not a cross-check.

Also unverified: the GICH/GICV windows (`0xf1004000`/`0xf1006000`) are copied
from cv200 as ARM's standard GIC-400 layout. No BSP or ATF source attests them
for this SoC. Impact is nil on this boot flow — `irq-gic.c` maps only regions
0/1, and regions 2/3 are read solely by the KVM vGIC, which needs HYP mode
while this loader enters EL1.

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

1. **The boot chain is not delivered, and without it the artifacts cannot be
   entered at all.** This is no longer a "might not work" risk — it is a known
   gap. This board's loader only reaches AArch64 through a FIP:
   `source/boot/fastboot/common/load_fip.c:230-320` requires BL31 plus a BL33
   that is a *legacy uImage with the DTB appended*, memmoves BL31 to
   `0x4400000`, sets `AARCH_MODE`, and enters BL33 at EL1. CI produces a bare
   `Image` and a standalone `.dtb`, which that loader has no way to start.
   Worse, `CFG_HI_CHIP_TYPE=hi3798mv300` is passed to ATF as `PLAT`, and the
   ATF tree contains only `hi3796mv200`, `hi3798cv200` and `hi3798mv200` —
   so **no BL31 can currently be built for that name**.
   Fix: build BL31 from the `hi3798mv200` plat, package BL33 as a uImage with
   the DTB appended, ship `fip.bin`. Only then is the DT's PSCI block
   meaningful.
2. **PSCI is asserted, not confirmed — and the BSP never used it.** The 4.4
   kernel had `# CONFIG_ARM_PSCI is not set` (defconfig:454) and did SMP by
   poking SCU/reset registers from 32-bit code (`mach-hi3798mv2x/platsmp.c`).
   arm64 has no such fallback. The DT's `arm,psci-0.2` node is correct *on a
   BL31 boot* and actively harmful without one: `psci_dt_init()` runs whenever
   the node exists, issues `PSCI_VERSION` by SMC, and if that fails
   `cpu_psci_cpu_prepare()` silently refuses CPUs 1-3. Expect a single-core
   boot with no obvious error rather than a clean failure.
3. **The MMZ carve-out is unmodelled.** The vendor loader for this exact board
   reserves 380 MiB of the 1 GiB
   (`source/boot/fastboot/include/configs/hi3798mv2x.h:137`,
   `mem=1G mmz=ddr,0,0,380M`), and on a FIP boot `mem=`/`mmz=` never reach the
   kernel, so the DT memory node is the sole authority. Stage 1 is unaffected
   (initramfs, no MMZ). Any later media driver allocating from that fixed
   range would DMA over live page-allocator memory — silent corruption, not a
   clean failure. The base must be derived from `source/common/drv/mmz`, not
   guessed.
4. **The architected timer is the only clocksource and has no fallback.** The
   BSP declined to use it (`#if 0`, vendor `hisp804` instead) and no mainline
   `hisp804` driver exists. A53 always integrates the generic timer and
   firmware programs `CNTFRQ`, so this should work — but it is a hardware
   checkpoint. The boot log line to look for is
   `cp15 timer(s) running at 24.00MHz`.
5. **Nothing in this port has ever executed.** Every "verified" claim above is
   a claim about *building*, not running.
6. **The vendor media stack — the actual product functionality — is entirely
   unported**, and per `api-drift-report.md` is the larger half of the work.
7. **Cache geometry in the DT is informational.** The L2 `cache-size` mirrors
   the CV200 4×A53 cluster; on arm64 the DT wins for sysfs only, and the
   kernel's real geometry comes from CLIDR/CCSIDR. Not a functional risk.
8. **`CONFIG_COMPAT` is load-bearing** for the "userspace keeps working" claim,
   and it is conditional (`depends on ARM64_4K_PAGES || EXPERT`). The fragment
   now pins `ARM64_4K_PAGES` so a future page-size line cannot silently drop
   the entire AArch32 userspace.
