#!/usr/bin/env bash
#
# Build a minimal initramfs that reaches an interactive shell.
#
# Usage: make-initramfs.sh <output.cpio.gz> [busybox-binary]
#
# The point of stage 1 is to prove the kernel gets all the way to userspace, so
# this deliberately contains almost nothing: a statically linked busybox and a
# handful of mounts. If the banner appears and you get a '#', the SoC bring-up
# (GIC + arch timer + PL011 + PSCI SMP) is working end to end.
#
# Environment:
#   EXPECTED_ARCH   ELF machine name the busybox must be, default AArch64.
#                   Set to empty to skip the check (only for host-native use).
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
	echo "       note it must be built for the TARGET, not for this host" >&2
	exit 2
fi

for tool in cpio gzip; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "error: $tool is required but not installed" >&2
		exit 2
	}
done

# ---------------------------------------------------------------------------
# Architecture check.
#
# An initramfs can only execute binaries of its own architecture. An earlier
# revision of this script checked linkage but never architecture, and CI duly
# packed the *runner's* x86-64 /bin/busybox into an arm64 image. The arm64
# kernel rejected it with ENOEXEC, every init path failed, and the boot would
# have died with "No working init found" -- while the pipeline stayed green and
# the artifact was labelled verified.
#
# Linkage alone is not enough, and neither is `file` (which reports the class
# but was only ever asked about "statically linked"). Compare the ELF machine.
# ---------------------------------------------------------------------------
EXPECTED_ARCH="${EXPECTED_ARCH-AArch64}"

elf_machine() {
	if command -v readelf >/dev/null 2>&1; then
		readelf -h "$1" 2>/dev/null |
			awk -F: '/^[[:space:]]*Machine:/{sub(/^[[:space:]]+/, "", $2); print $2; exit}'
		return
	fi
	# Fallback: e_machine is the two bytes at offset 18. Print both byte orders
	# so the caller can match whichever the host's od produces.
	od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'
}

if [[ -n "$EXPECTED_ARCH" ]]; then
	machine="$(elf_machine "$BUSYBOX")"
	if [[ -z "$machine" ]]; then
		echo "error: cannot determine the ELF machine of $BUSYBOX" >&2
		echo "       install binutils (readelf) and retry" >&2
		exit 2
	fi
	case "$machine" in
		# readelf's name for 0xb7, or the raw bytes either way round.
		"$EXPECTED_ARCH"|b700|00b7|AArch64) ;;
		*)
			echo "error: busybox is '$machine' but this initramfs targets '$EXPECTED_ARCH'" >&2
			echo "       an $EXPECTED_ARCH kernel cannot exec a '$machine' binary;" >&2
			echo "       the boot would panic with 'No working init found'." >&2
			echo "       build busybox with the target cross-compiler, or set" >&2
			echo "       EXPECTED_ARCH= to override deliberately." >&2
			exit 2
			;;
	esac
	echo "==> busybox architecture: $machine (target $EXPECTED_ARCH)"
fi

# A dynamically linked busybox is useless without the matching libc on the
# image, so refuse it up front rather than producing an initramfs that panics
# with a loader error.
if command -v file >/dev/null 2>&1; then
	if ! file -L "$BUSYBOX" | grep -Eq "statically linked|static-pie linked"; then
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

# Applet symlinks.
#
# `busybox --install` is only usable when the binary can execute on the build
# host, which is exactly NOT the case in a cross build -- so treat the explicit
# list as the primary path and use --install only as a bonus. An earlier
# version had this inverted and its fallback list omitted `setsid`, which /init
# needs, so the fallback path produced an init that could not reach a shell.
#
# This list must cover every command /init below runs. Adding a command there
# without adding it here breaks the cross build silently.
APPLETS="sh ls cat echo mount umount mkdir mknod dmesg uname sleep
	 ifconfig ip ps free df grep sed awk cut tr head tail wc
	 setsid poweroff reboot halt sync chmod ln rm cp mv
	 date uptime more less vi ping"

echo "==> creating applet symlinks"
for applet in $APPLETS; do
	ln -sf busybox "$ROOT/bin/$applet"
done
ln -sf busybox "$ROOT/bin/sh"

# Optional: let busybox itself create the full set when it happens to be
# runnable here (native builds). Failures are expected and harmless cross-arch.
if "$BUSYBOX" --install -s "$ROOT/bin" >/dev/null 2>&1; then
	echo "==> additionally installed busybox's own applet set"
fi

# /sbin/init and /bin/sh must exist so that the kernel's fallback init search
# paths resolve if /init is ever skipped.
ln -sf ../bin/busybox "$ROOT/sbin/init"

cat > "$ROOT/init" <<'EOF'
#!/bin/sh
# Hi3798M V300 stage-1 init -- runs as PID 1.
#
# PID 1 must not exit: the kernel turns that into "Attempted to kill init" and
# panics. So every path here ends in something that does not return.
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev 2>/dev/null

CONSOLE=/dev/ttyAMA0
[ -c "$CONSOLE" ] || CONSOLE=/dev/console

echo
echo "==================================================="
echo " Hi3798M V300 (hi3798mv300) - kernel reached userspace"
echo "==================================================="
echo " kernel : $(uname -a)"
echo " cpus   : $(grep -c ^processor /proc/cpuinfo)"
echo " console: $(cat /proc/cmdline)"
echo " tty    : $CONSOLE"
echo
echo "Dropping to a shell. 'poweroff -f' to exit."
echo

# setsid gives the shell its own session so job control works. BusyBox's setsid
# forks and its parent exits 0 even when the child fails, so it is deliberately
# NOT exec'd: if it returns we fall through to a plain shell instead of letting
# init exit.
if command -v setsid >/dev/null 2>&1; then
	setsid sh -c "exec sh <$CONSOLE >$CONSOLE 2>&1"
fi
echo "init: setsid unusable, falling back to a plain shell on $CONSOLE"
exec sh <"$CONSOLE" >"$CONSOLE" 2>&1
EOF
chmod 755 "$ROOT/init"

# Pack atomically: writing straight to $OUT leaves a truncated archive behind
# if cpio fails, and a truncated initramfs is worse than none because it looks
# like a successful build.
TMP_OUT="${OUT}.tmp.$$"
echo "==> packing $OUT"
if ! ( cd "$ROOT" && find . -print0 | cpio --null -o --format=newc 2>"$WORK/cpio.err" | gzip -9 ) > "$TMP_OUT"; then
	echo "error: packing failed" >&2
	cat "$WORK/cpio.err" >&2 || true
	rm -f "$TMP_OUT"
	exit 1
fi

# Final sanity gate: the archive must actually contain /init.
#
# Decompress to a file first. Piping gzip into `grep -q` looks natural and is
# wrong: grep -q exits at the first match, which closes the pipe, which SIGPIPEs
# gzip, and under `set -o pipefail` the resulting 141 turns a SUCCESSFUL match
# into a failing pipeline. On this script's first real run that produced a
# false "does not contain /init" for a perfectly good archive.
gzip -dc "$TMP_OUT" > "$WORK/plain.cpio"
if ! grep -aq '\./init' "$WORK/plain.cpio"; then
	echo "error: packed archive does not contain /init" >&2
	rm -f "$TMP_OUT"
	exit 1
fi

mv "$TMP_OUT" "$OUT"
echo "==> $(du -h "$OUT" | cut -f1) written"
