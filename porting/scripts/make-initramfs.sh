#!/usr/bin/env bash
#
# Build a minimal initramfs that reaches an interactive shell.
#
# Usage: make-initramfs.sh <output.cpio.gz> [busybox-binary]
#
# The point of stage 1 is to prove the kernel gets all the way to userspace, so
# this deliberately contains nothing but a statically linked busybox and a
# handful of mounts. If you see the banner and get a '#', the SoC bring-up
# (GIC + arch timer + PL011 + PSCI SMP) is working end to end.
#
set -euo pipefail

OUT="${1:-}"
BUSYBOX="${2:-}"

if [[ -z "$OUT" ]]; then
	echo "usage: $0 <output.cpio.gz> [busybox-binary]" >&2
	exit 2
fi

if [[ -z "$BUSYBOX" ]]; then
	BUSYBOX="$(command -v busybox || true)"
fi
if [[ -z "$BUSYBOX" || ! -x "$BUSYBOX" ]]; then
	echo "error: no busybox binary found; pass one as \$2" >&2
	exit 2
fi

# A dynamically linked busybox is useless without the matching libc on the
# image, so refuse it up front rather than producing an initramfs that panics
# with "unable to open initial console" or a loader error.
if command -v file >/dev/null 2>&1; then
	if ! file -L "$BUSYBOX" | grep -q "statically linked"; then
		echo "error: $BUSYBOX is not statically linked" >&2
		exit 2
	fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
mkdir -p "$ROOT"/{bin,sbin,etc,proc,sys,dev,tmp,root}
chmod 1777 "$ROOT/tmp"

cp "$BUSYBOX" "$ROOT/bin/busybox"
chmod 755 "$ROOT/bin/busybox"

# busybox --install needs to run natively, so the CI job must provide a
# busybox for the *build host* too; fall back to hand-written applet links if
# it cannot be executed here.
if "$BUSYBOX" --install -s "$ROOT/bin" 2>/dev/null; then
	echo "==> installed busybox applet symlinks"
else
	echo "==> busybox not runnable on host; creating applet links manually"
	for applet in sh ls cat echo mount umount mkdir dmesg uname sleep \
	              ifconfig ip ps free df grep; do
		ln -sf busybox "$ROOT/bin/$applet"
	done
fi
ln -sf busybox "$ROOT/bin/sh"
ln -sf ../bin/busybox "$ROOT/sbin/init" 2>/dev/null || true

cat > "$ROOT/init" <<'EOF'
#!/bin/sh
# Hi3798M V300 stage-1 init.
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null

echo
echo "==================================================="
echo " Hi3798M V300 (hi3798mv300) - kernel reached userspace"
echo "==================================================="
echo " kernel : $(uname -a)"
echo " cpus   : $(grep -c ^processor /proc/cpuinfo)"
echo " console: $(cat /proc/cmdline)"
echo
echo "Dropping to a shell. 'poweroff -f' to exit."
echo

exec setsid sh -c 'exec sh </dev/ttyAMA0 >/dev/ttyAMA0 2>&1'
EOF
chmod 755 "$ROOT/init"

echo "==> packing $OUT"
( cd "$ROOT" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 ) > "$OUT"
echo "==> $(du -h "$OUT" | cut -f1) written"
