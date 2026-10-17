#!/usr/bin/env bash
#
# Apply the Hi3798M V300 forward-port overlay on top of a pristine Linux tree.
#
# Usage: apply-overlay.sh <kernel-tree>
#
# Everything this script touches lives under porting/overlay/, laid out with the
# same relative paths as the kernel tree. Keeping the port as an overlay rather
# than a fork means:
#   - the 1.7 GiB kernel tree never enters git,
#   - bumping to a newer 6.18.y (or a later LTS) is a tarball swap, not a merge,
#   - every change we make is reviewable as a short file list.
#
set -euo pipefail

KERNEL_TREE="${1:-}"
if [[ -z "$KERNEL_TREE" || ! -d "$KERNEL_TREE" ]]; then
	echo "usage: $0 <kernel-tree>" >&2
	exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY="$(cd "$HERE/../overlay" && pwd)"

if [[ ! -f "$KERNEL_TREE/Makefile" ]]; then
	echo "error: $KERNEL_TREE does not look like a kernel tree" >&2
	exit 2
fi

echo "==> applying overlay $OVERLAY -> $KERNEL_TREE"
(cd "$OVERLAY" && find . -type f -print0) |
	while IFS= read -r -d '' rel; do
		dest="$KERNEL_TREE/${rel#./}"
		mkdir -p "$(dirname "$dest")"
		cp "$OVERLAY/${rel#./}" "$dest"
		echo "    ${rel#./}"
	done

# The DTS Makefile is one file we cannot simply overwrite: it is a list of
# dtb-$(CONFIG_...) += lines that upstream keeps editing. Append idempotently.
DTS_MAKE="$KERNEL_TREE/arch/arm64/boot/dts/hisilicon/Makefile"
DTB_LINE='dtb-$(CONFIG_ARCH_HISI) += hi3798mv300-hi3798mv3dmm.dtb'
if [[ -f "$DTS_MAKE" ]]; then
	if grep -qF "$DTB_LINE" "$DTS_MAKE"; then
		echo "    (dtb line already present)"
	else
		printf '%s\n' "$DTB_LINE" >> "$DTS_MAKE"
		echo "    appended dtb line to hisilicon/Makefile"
	fi
else
	echo "error: $DTS_MAKE not found" >&2
	exit 1
fi

# porting/appends/<path>.append is appended to <kernel-tree>/<path>.
#
# Same reasoning as the DTS line, generalised: for files upstream keeps
# editing, shipping a whole replacement Makefile would conflict on every
# kernel bump, so we append a self-contained block instead. Idempotency is
# keyed on the append file's first line, which is why every .append must open
# with a unique marker comment.
APPENDS="$(cd "$HERE/../appends" && pwd)"
if [[ -d "$APPENDS" ]]; then
	echo "==> applying appends $APPENDS"
	(cd "$APPENDS" && find . -type f -name '*.append' -print0) |
		while IFS= read -r -d '' rel; do
			src="$APPENDS/${rel#./}"
			dest="$KERNEL_TREE/${rel#./}"
			dest="${dest%.append}"

			if [[ ! -f "$dest" ]]; then
				echo "error: append target does not exist: $dest" >&2
				exit 1
			fi

			sentinel="$(head -n 1 "$src")"
			if [[ -z "$sentinel" ]]; then
				echo "error: $rel has an empty first line; it must open with a marker" >&2
				exit 1
			fi

			if grep -qF "$sentinel" "$dest"; then
				echo "    (already appended: ${dest#"$KERNEL_TREE"/})"
				continue
			fi

			printf '\n' >> "$dest"
			cat "$src" >> "$dest"
			echo "    appended to ${dest#"$KERNEL_TREE"/}"
		done
fi

echo "==> overlay applied"
