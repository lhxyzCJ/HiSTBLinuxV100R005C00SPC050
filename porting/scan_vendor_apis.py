#!/usr/bin/env python3
"""
Scan the HiSTB vendor driver tree for kernel APIs that were removed or whose
semantics changed between Linux 4.4 and Linux 6.18 LTS.

This yields the raw data needed to schedule a BSP forward-port: which
subsystems are cheap to move, and which need a rewrite.

Usage:
    scan_vendor_apis.py <scan-root> [more roots...] > report.md
"""

import os
import re
import sys
from collections import defaultdict

# (id, regex, severity, note)
# severity: BLOCKER = will not compile, MAJOR = compiles but behaves wrong,
#           MINOR = deprecation warning / cleanup
RULES = [
    # ---- timers / timekeeping ----
    ("init_timer",        r"\binit_timer\s*\(",           "BLOCKER", "removed in 5.15; use timer_setup()"),
    ("setup_timer",       r"\bsetup_timer\s*\(",          "BLOCKER", "removed in 5.15; use timer_setup()"),
    ("struct timespec",   r"\bstruct\s+timespec\b",       "BLOCKER", "removed in 5.6; use timespec64 / ktime_t"),
    ("do_gettimeofday",   r"\bdo_gettimeofday\s*\(",      "BLOCKER", "removed in 5.11; use ktime_get_real_ts64()"),
    ("getnstimeofday",    r"\bgetnstimeofday\s*\(",       "BLOCKER", "removed in 5.11; use ktime_get_real_ts64()"),
    ("current_kernel_time", r"\bcurrent_kernel_time\s*\(", "BLOCKER", "removed in 5.6"),
    ("get_seconds",       r"\bget_seconds\s*\(",          "MAJOR",   "removed in 5.6"),
    ("jiffies_to_timeval", r"\bjiffies_to_timeval\s*\(",  "BLOCKER", "removed in 5.6"),

    # ---- procfs / sysfs ----
    ("create_proc_entry", r"\bcreate_proc_entry\s*\(",    "BLOCKER", "removed in 3.10; use proc_create()"),
    ("create_proc_read_entry", r"\bcreate_proc_read_entry\s*\(", "BLOCKER", "removed in 3.10"),
    ("proc_create_data",  r"\bproc_create_data\s*\(",     "MINOR",   "signature evolved; check proc_ops"),
    ("struct file_operations ioctl", r"\.ioctl\s*=",      "BLOCKER", "removed in 2.6.36; use .unlocked_ioctl"),
    ("proc_ops",          r"\bstruct\s+file_operations\b.*proc", "MINOR", "procfs moved to struct proc_ops in 5.6"),

    # ---- char/block registration ----
    ("register_chrdev",   r"\bregister_chrdev\s*\(",      "MINOR",   "deprecated; use alloc_chrdev_region + cdev"),
    ("struct class create owner", r"\bclass_create\s*\(\s*THIS_MODULE", "BLOCKER", "owner arg dropped in 6.4"),

    # ---- user access ----
    ("access_ok 3-arg",   r"\baccess_ok\s*\(\s*[A-Za-z_]+\s*,", "BLOCKER", "type arg dropped in 5.0"),
    ("set_fs",            r"\bset_fs\s*\(",               "BLOCKER", "removed in 5.10"),
    ("get_fs",            r"\bget_fs\s*\(",               "BLOCKER", "removed in 5.10"),
    ("verify_area",       r"\bverify_area\s*\(",          "BLOCKER", "removed"),
    ("__copy_from_user (3-arg, no check)", r"__copy_from_user\s*\(", "MINOR", "check the 3rd arg usage"),
    ("probe_kernel_read", r"\bprobe_kernel_read\s*\(",    "BLOCKER", "removed in 5.8; use copy_from_kernel_nofault()"),
    ("probe_kernel_write", r"\bprobe_kernel_write\s*\(",  "BLOCKER", "removed in 5.8; use copy_to_kernel_nofault()"),

    # ---- memory ----
    ("get_user_pages",    r"\bget_user_pages\s*\(",       "BLOCKER", "removed in 5.8; use pin_user_pages()"),
    ("ioremap_nocache",   r"\bioremap_nocache\s*\(",      "MINOR",   "folded into ioremap() in 5.6"),
    ("ioremap_cached",    r"\bioremap_cached\s*\(",       "MINOR",   "folded into ioremap_cache() in 5.6"),
    ("kmap_atomic",       r"\bkmap_atomic\s*\(",          "MAJOR",   "deprecated in 5.11; use kmap_local_page()"),
    ("__get_free_pages",  r"\b__get_free_pages\s*\(",     "MINOR",   "check GFP flags"),
    ("vmalloc_to_page",   r"\bvmalloc_to_page\s*\(",      "MINOR",   "still present, semantics stable"),

    # ---- driver model ----
    ("platform_driver.remove int", r"\.remove\s*=\s*[A-Za-z_][A-Za-z0-9_]*\s*,", "MAJOR", "returns void since 6.11"),
    ("struct device_driver probe", r"\.probe\s*=",        "MINOR",   "signatures stable, check per-bus"),
    ("MODULE_SUPPORTED_DEVICE", r"\bMODULE_SUPPORTED_DEVICE\b", "BLOCKER", "removed in 5.13"),
    ("bus_register notify", r"\bstruct\s+bus_type\b",     "MAJOR",   "bus_type changed over 5.x/6.x"),
    ("dev_attrs",         r"\bdev_attrs\b",               "BLOCKER", "removed in 4.13; use device_groups"),

    # ---- interrupts ----
    ("irq_handler_t old", r"\birq_handler_t\b",           "MINOR",   "signature stable"),
    ("request_irq flags", r"\brequest_irq\s*\(",          "MINOR",   "check IRQF_ flags"),
    ("enable_irq_wake",   r"\benable_irq_wake\s*\(",      "MINOR",   "stable"),
    ("irq_to_gpio",       r"\birq_to_gpio\s*\(",          "BLOCKER", "removed in 3.18"),

    # ---- GPIO (legacy integer API largely removed) ----
    ("gpio_request",      r"\bgpio_request\s*\(",         "MAJOR",   "legacy API; use gpiod_* (unreliable on non-DT)"),
    ("gpio_direction_output", r"\bgpio_direction_output\s*\(", "MAJOR", "legacy API; use gpiod_*"),
    ("gpio_free",         r"\bgpio_free\s*\(",            "MAJOR",   "legacy API; use gpiod_*"),
    ("of_get_named_gpio_flags", r"\bof_get_named_gpio_flags\s*\(", "MAJOR", "removed in 6.x; use of_get_named_gpio()"),

    # ---- clock framework ----
    ("clk_prepare_enable", r"\bclk_prepare_enable\s*\(",   "MINOR",   "stable"),
    ("clk_register",      r"\bclk_register\s*\(",         "MAJOR",   "CLK_IS_BASIC / clk_hw migration"),
    ("clkdev_add",        r"\bclkdev_add\s*\(",           "BLOCKER", "removed; use clk_hw_register + of_clk"),

    # ---- dma ----
    ("dma_alloc_coherent", r"\bdma_alloc_coherent\s*\(",  "MINOR",   "stable"),
    ("pci_alloc_consistent", r"\bpci_alloc_consistent\s*\(", "BLOCKER", "removed; use dma_alloc_coherent()"),
    ("pci_dma_mapping_error", r"\bpci_dma_mapping_error\s*\(", "BLOCKER", "removed in 4.8"),
    ("dma_set_mask",      r"\bdma_set_mask\s*\(",         "MINOR",   "stable"),
    ("dma_cache_sync",    r"\bdma_cache_sync\s*\(",       "MAJOR",   "removed in 5.14"),

    # ---- net ----
    ("ndo_do_ioctl",      r"\.ndo_do_ioctl\s*=",          "BLOCKER", "removed in 5.15; use ndo_siocdevprivate"),
    ("ndo_ioctl",         r"\.ndo_ioctl\s*=",             "BLOCKER", "removed in 5.15"),
    ("netdev_alloc_skb",  r"\bnetdev_alloc_skb\s*\(",     "MINOR",   "stable"),
    ("init_net",          r"\binit_net\b",                "MINOR",   "stable"),
    ("ether_setup",       r"\bether_setup\s*\(",          "MINOR",   "stable"),

    # ---- misc removed helpers ----
    ("create_singlethread_workqueue", r"\bcreate_singlethread_workqueue\s*\(", "BLOCKER", "removed in 5.17; use alloc_workqueue()"),
    ("create_workqueue",  r"\bcreate_workqueue\s*\(",     "BLOCKER", "removed in 5.17"),
    ("sleep_on",          r"\bsleep_on\s*\(",             "BLOCKER", "removed long ago"),
    ("interruptible_sleep_on", r"\binterruptible_sleep_on\s*\(", "BLOCKER", "removed long ago"),
    ("smp_call_function", r"\bsmp_call_function\s*\(",    "MAJOR",   "interrupts now disabled by default"),
    ("on_each_cpu",       r"\bon_each_cpu\s*\(",          "MINOR",   "stable"),
    ("strict_strtol",     r"\bstrict_strtol\s*\(",        "BLOCKER", "removed in 3.5; use kstrtol()"),
    ("simple_strtoul",    r"\bsimple_strtoul\s*\(",       "MINOR",   "deprecated; use kstrtoul()"),
    ("da9052_",           r"\bda9052_",                   "MINOR",   "sample rule"),

    # ---- V4L2 / media (heavily used by vfmw/vo/vdec) ----
    ("v4l2 ioctl ops",    r"\bstruct\s+v4l2_ioctl_ops\b", "MAJOR",   "many op signatures changed"),
    ("v4l2_subdev_ops",   r"\bstruct\s+v4l2_subdev_ops\b", "MAJOR",  "ops structs reorganised"),
    ("vb2_queue",         r"\bstruct\s+vb2_queue\b",      "MAJOR",   "vb2 API reworked in 5.x"),
    ("video_device",      r"\bstruct\s+video_device\b",   "MAJOR",   "fops handling changed"),
    ("media_entity",      r"\bmedia_entity_init\s*\(",    "BLOCKER", "removed in 4.20; use media_entity_pads_init()"),
    ("soc_camera",        r"\bsoc_camera\b",              "BLOCKER", "framework removed in 5.8"),

    # ---- fbdev / drm ----
    ("fb_info",           r"\bstruct\s+fb_info\b",        "MAJOR",   "fb_ops signatures changed (6.0+)"),
    ("register_framebuffer", r"\bregister_framebuffer\s*\(", "MINOR", "stable"),
    ("drm_driver",        r"\bstruct\s+drm_driver\b",     "MAJOR",   "GEM/atomic reworks"),

    # ---- TEE / SMC (hisi-specific glue) ----
    ("arm_smccc_smc",     r"\barm_smccc_smc\s*\(",        "MINOR",   "stable since 4.17"),
    ("__raw_writel (no barrier)", r"__raw_writel\s*\(",   "MINOR",   "prefer writel_relaxed"),

    # ---- init/exit boilerplate ----
    ("module_init",       r"\bmodule_init\s*\(",          "MINOR",   "stable"),
    ("late_initcall",     r"\blate_initcall\s*\(",        "MINOR",   "stable"),
]

COMPILED = [(n, re.compile(p), s, note) for (n, p, s, note) in RULES]

SRC_EXT = (".c", ".h")


def iter_sources(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for fn in filenames:
            if fn.endswith(SRC_EXT):
                yield os.path.join(dirpath, fn)


def subsystem_of(path, root):
    """Group by the first path component below root that looks like a driver dir."""
    rel = os.path.relpath(path, root)
    parts = rel.split(os.sep)
    # skip 'drv'/'src' style container segments
    for i, p in enumerate(parts):
        if p not in ("drv", "src", "include", "api"):
            return p
    return parts[0]


def main():
    roots = sys.argv[1:] or ["."]
    hits = defaultdict(lambda: defaultdict(int))   # subsystem -> rule -> count
    sev_count = defaultdict(int)
    rule_total = defaultdict(int)
    rule_files = defaultdict(set)
    files_scanned = 0

    for root in roots:
        root = os.path.abspath(root)
        if not os.path.isdir(root):
            print(f"skip (not a dir): {root}", file=sys.stderr)
            continue
        for path in iter_sources(root):
            files_scanned += 1
            try:
                with open(path, "r", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            sub = subsystem_of(path, root)
            for name, rx, sev, _note in COMPILED:
                n = len(rx.findall(text))
                if n:
                    hits[sub][name] += n
                    rule_total[name] += n
                    rule_files[name].add(path)
                    sev_count[sev] += n

    print("# Vendor BSP kernel-API drift: Linux 4.4 -> 6.18 LTS\n")
    print(f"Scanned **{files_scanned}** C/H files under: "
          f"{', '.join('`' + r + '`' for r in roots)}\n")

    print("## Severity summary (raw hits)\n")
    print("| Severity | Hits | Meaning |")
    print("|---|---:|---|")
    print(f"| BLOCKER | {sev_count['BLOCKER']} | will not compile |")
    print(f"| MAJOR   | {sev_count['MAJOR']} | compiles, silently misbehaves |")
    print(f"| MINOR   | {sev_count['MINOR']} | deprecation / cleanup |")
    print()

    print("## Worst-off rule -> affected files\n")
    print("| Rule | Severity | Files affected | Raw hits |")
    print("|---|---|---:|---:|")
    ranked = sorted(rule_total.items(), key=lambda kv: -len(rule_files[kv[0]]))
    sev_of = {r[0]: r[2] for r in RULES}
    note_of = {r[0]: r[3] for r in RULES}
    for name, total in ranked:
        print(f"| `{name}` | {sev_of[name]} | {len(rule_files[name])} "
              f"| {total} |")
    print()

    print("## BLOCKER impact per subsystem\n")
    print("Subsystems ranked by number of distinct blocker rules present. "
          "This is the forward-port cost estimate.\n")
    print("| Subsystem | BLOCKER rules | BLOCKER hits | Top blockers |")
    print("|---|---:|---:|---|")
    rows = []
    for sub, rules in hits.items():
        blk = {n: c for n, c in rules.items() if sev_of[n] == "BLOCKER"}
        if not blk:
            continue
        rows.append((sub, len(blk), sum(blk.values()), blk))
    rows.sort(key=lambda r: (-r[1], -r[2]))
    for sub, nrules, nhits, blk in rows:
        top = ", ".join(f"`{k}`" for k, _ in
                        sorted(blk.items(), key=lambda kv: -kv[1])[:3])
        print(f"| `{sub}` | {nrules} | {nhits} | {top} |")
    print()

    print("## Rule notes\n")
    for name, _rx, sev, note in RULES:
        if rule_total.get(name):
            print(f"- **{name}** ({sev}): {note}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
