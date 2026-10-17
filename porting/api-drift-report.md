# Vendor BSP kernel-API drift: Linux 4.4 -> 6.18 LTS

Scanned **11466** C/H files under: `source/msp`, `source/component`

Reproduce with:

```
python3 porting/scan_vendor_apis.py source/msp source/component \
    > porting/api-drift-report.md
```

## Read this before quoting any number below

This census is a **heuristic upper bound on porting work, not a measurement of
it**, and an independent audit found errors in both directions:

- **"Hits" are regex matches, not code sites.** `set_fs` and `get_fs` match
  the *same* 96 files (587 hits between them), so the BLOCKER total counts one
  body of work twice. Per-rule file counts sum to 522 against 1071 hits.
- **Some BLOCKER rules are wrong.** `create_workqueue`,
  `create_singlethread_workqueue` and `ndo_do_ioctl` still exist in 6.18
  (`include/linux/workqueue.h:596,601`, `include/linux/netdevice.h:1431`) —
  101 phantom blockers. `\.ioctl\s*=` matches 22 times and finds zero real
  `file_operations` sites.
- **Some severities are inverted.** `ioremap_nocache` is filed MINOR
  ("folded into ioremap") but is *gone* from 6.18 — 142 hits that will not
  compile. `get_seconds` is filed MAJOR and is likewise gone.
- **The port targets arm64 and these rules do not know it.** There are no
  arch-specific rules at all, yet `#include <mach/...>` alone is 198 hits
  across 108 files and cannot compile on arm64. `struct timeval` (176 hits /
  94 files) is also missing: 6.18 guards it behind `#ifndef __KERNEL__`.
- **The scan roots sum mutually exclusive driver trees.**
  `source/component/wifi/drv/Makefile:21` selects one of ~25 wifi families;
  `source/msp/drv/gpu/Makefile:20` selects `utgard` xor `midgard`. So the
  subsystem totals aggregate code that is never compiled together.
- **Comment, string, `#if 0` and patch-payload text are all counted**, and
  ~215 of the 11466 files are userspace (openssl, freetype, harfbuzz, ...)
  where kernel-API drift is meaningless.

Roughly 28-38% of the 2727 raw hits correspond to real work. Treat the
subsystem ranking as a hypothesis to be re-derived after the rules are fixed
(see "Fixing the census" in `README.md`), not as a schedule.

## Severity summary (raw hits)

| Severity | Hits | Meaning |
|---|---:|---|
| BLOCKER | 1071 | will not compile |
| MAJOR   | 668 | compiles, silently misbehaves |
| MINOR   | 988 | deprecation / cleanup |

## Worst-off rule -> affected files

| Rule | Severity | Files affected | Raw hits |
|---|---|---:|---:|
| `module_init` | MINOR | 126 | 127 |
| `set_fs` | BLOCKER | 96 | 396 |
| `get_fs` | BLOCKER | 96 | 191 |
| `struct device_driver probe` | MINOR | 92 | 111 |
| `platform_driver.remove int` | MAJOR | 75 | 92 |
| `simple_strtoul` | MINOR | 71 | 359 |
| `ioremap_nocache` | MINOR | 69 | 142 |
| `init_timer` | BLOCKER | 61 | 68 |
| `do_gettimeofday` | BLOCKER | 54 | 105 |
| `init_net` | MINOR | 44 | 59 |
| `struct timespec` | BLOCKER | 42 | 73 |
| `gpio_free` | MAJOR | 41 | 122 |
| `gpio_request` | MAJOR | 38 | 99 |
| `gpio_direction_output` | MAJOR | 29 | 106 |
| `ndo_do_ioctl` | BLOCKER | 28 | 48 |
| `create_workqueue` | BLOCKER | 24 | 29 |
| `create_singlethread_workqueue` | BLOCKER | 22 | 24 |
| `request_irq flags` | MINOR | 21 | 34 |
| `struct file_operations ioctl` | BLOCKER | 20 | 22 |
| `proc_ops` | MINOR | 20 | 67 |
| `proc_create_data` | MINOR | 19 | 21 |
| `setup_timer` | BLOCKER | 18 | 30 |
| `create_proc_entry` | BLOCKER | 18 | 18 |
| `access_ok 3-arg` | BLOCKER | 17 | 25 |
| `irq_handler_t old` | MINOR | 16 | 21 |
| `get_seconds` | MAJOR | 13 | 22 |
| `ether_setup` | MINOR | 13 | 13 |
| `struct class create owner` | BLOCKER | 9 | 9 |
| `pci_alloc_consistent` | BLOCKER | 9 | 14 |
| `fb_info` | MAJOR | 7 | 214 |
| `register_chrdev` | MINOR | 5 | 9 |
| `kmap_atomic` | MAJOR | 5 | 12 |
| `__get_free_pages` | MINOR | 5 | 5 |
| `late_initcall` | MINOR | 4 | 4 |
| `clk_prepare_enable` | MINOR | 4 | 4 |
| `getnstimeofday` | BLOCKER | 4 | 13 |
| `enable_irq_wake` | MINOR | 3 | 3 |
| `on_each_cpu` | MINOR | 2 | 3 |
| `get_user_pages` | BLOCKER | 2 | 4 |
| `netdev_alloc_skb` | MINOR | 2 | 2 |
| `MODULE_SUPPORTED_DEVICE` | BLOCKER | 1 | 1 |
| `register_framebuffer` | MINOR | 1 | 1 |
| `drm_driver` | MAJOR | 1 | 1 |
| `dma_set_mask` | MINOR | 1 | 1 |
| `__raw_writel (no barrier)` | MINOR | 1 | 1 |
| `dma_alloc_coherent` | MINOR | 1 | 1 |
| `interruptible_sleep_on` | BLOCKER | 1 | 1 |

## BLOCKER impact per subsystem

Subsystems ranked by number of distinct blocker rules present. This is the forward-port cost estimate.

| Subsystem | BLOCKER rules | BLOCKER hits | Top blockers |
|---|---:|---:|---|
| `wifi` | 16 | 746 | `set_fs`, `get_fs`, `do_gettimeofday` |
| `gpu` | 10 | 51 | `struct timespec`, `do_gettimeofday`, `get_user_pages` |
| `bluetooth` | 6 | 42 | `setup_timer`, `set_fs`, `create_workqueue` |
| `vfmw` | 5 | 29 | `set_fs`, `get_fs`, `do_gettimeofday` |
| `aiao` | 5 | 5 | `MODULE_SUPPORTED_DEVICE`, `struct file_operations ioctl`, `create_singlethread_workqueue` |
| `hdmi` | 4 | 16 | `set_fs`, `get_fs`, `do_gettimeofday` |
| `venc` | 4 | 12 | `set_fs`, `init_timer`, `get_fs` |
| `vdec` | 3 | 30 | `set_fs`, `get_fs`, `init_timer` |
| `frontend` | 3 | 24 | `set_fs`, `do_gettimeofday`, `get_fs` |
| `advca` | 3 | 20 | `do_gettimeofday`, `set_fs`, `get_fs` |
| `vo` | 3 | 19 | `set_fs`, `get_fs`, `do_gettimeofday` |
| `omxvdec` | 3 | 14 | `set_fs`, `get_fs`, `struct class create owner` |
| `directfb` | 3 | 9 | `struct file_operations ioctl`, `struct class create owner`, `struct timespec` |
| `hifb` | 3 | 5 | `do_gettimeofday`, `create_workqueue`, `create_singlethread_workqueue` |
| `vpss` | 2 | 12 | `set_fs`, `get_fs` |
| `keyled` | 1 | 8 | `init_timer` |
| `drmengine` | 1 | 7 | `struct timespec` |
| `ir` | 1 | 6 | `init_timer` |
| `klad` | 1 | 3 | `struct file_operations ioctl` |
| `pvr` | 1 | 3 | `struct timespec` |
| `adac` | 1 | 2 | `init_timer` |
| `cc` | 1 | 2 | `struct timespec` |
| `jpeg` | 1 | 1 | `struct timespec` |
| `demux` | 1 | 1 | `create_singlethread_workqueue` |
| `adsp` | 1 | 1 | `init_timer` |
| `vi` | 1 | 1 | `init_timer` |
| `avplay` | 1 | 1 | `struct timespec` |
| `omx` | 1 | 1 | `struct timespec` |

## Rule notes

- **init_timer** (BLOCKER): removed in 5.15; use timer_setup()
- **setup_timer** (BLOCKER): removed in 5.15; use timer_setup()
- **struct timespec** (BLOCKER): removed in 5.6; use timespec64 / ktime_t
- **do_gettimeofday** (BLOCKER): removed in 5.11; use ktime_get_real_ts64()
- **getnstimeofday** (BLOCKER): removed in 5.11; use ktime_get_real_ts64()
- **get_seconds** (MAJOR): removed in 5.6
- **create_proc_entry** (BLOCKER): removed in 3.10; use proc_create()
- **proc_create_data** (MINOR): signature evolved; check proc_ops
- **struct file_operations ioctl** (BLOCKER): removed in 2.6.36; use .unlocked_ioctl
- **proc_ops** (MINOR): procfs moved to struct proc_ops in 5.6
- **register_chrdev** (MINOR): deprecated; use alloc_chrdev_region + cdev
- **struct class create owner** (BLOCKER): owner arg dropped in 6.4
- **access_ok 3-arg** (BLOCKER): type arg dropped in 5.0
- **set_fs** (BLOCKER): removed in 5.10
- **get_fs** (BLOCKER): removed in 5.10
- **get_user_pages** (BLOCKER): removed in 5.8; use pin_user_pages()
- **ioremap_nocache** (MINOR): folded into ioremap() in 5.6
- **kmap_atomic** (MAJOR): deprecated in 5.11; use kmap_local_page()
- **__get_free_pages** (MINOR): check GFP flags
- **platform_driver.remove int** (MAJOR): returns void since 6.11
- **struct device_driver probe** (MINOR): signatures stable, check per-bus
- **MODULE_SUPPORTED_DEVICE** (BLOCKER): removed in 5.13
- **irq_handler_t old** (MINOR): signature stable
- **request_irq flags** (MINOR): check IRQF_ flags
- **enable_irq_wake** (MINOR): stable
- **gpio_request** (MAJOR): legacy API; use gpiod_* (unreliable on non-DT)
- **gpio_direction_output** (MAJOR): legacy API; use gpiod_*
- **gpio_free** (MAJOR): legacy API; use gpiod_*
- **clk_prepare_enable** (MINOR): stable
- **dma_alloc_coherent** (MINOR): stable
- **pci_alloc_consistent** (BLOCKER): removed; use dma_alloc_coherent()
- **dma_set_mask** (MINOR): stable
- **ndo_do_ioctl** (BLOCKER): removed in 5.15; use ndo_siocdevprivate
- **netdev_alloc_skb** (MINOR): stable
- **init_net** (MINOR): stable
- **ether_setup** (MINOR): stable
- **create_singlethread_workqueue** (BLOCKER): removed in 5.17; use alloc_workqueue()
- **create_workqueue** (BLOCKER): removed in 5.17
- **interruptible_sleep_on** (BLOCKER): removed long ago
- **on_each_cpu** (MINOR): stable
- **simple_strtoul** (MINOR): deprecated; use kstrtoul()
- **fb_info** (MAJOR): fb_ops signatures changed (6.0+)
- **register_framebuffer** (MINOR): stable
- **drm_driver** (MAJOR): GEM/atomic reworks
- **__raw_writel (no barrier)** (MINOR): prefer writel_relaxed
- **module_init** (MINOR): stable
- **late_initcall** (MINOR): stable
