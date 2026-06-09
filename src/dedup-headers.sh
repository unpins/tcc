#!/usr/bin/env bash
# Zig-style header de-duplication for the multi-target sysroots.
#
# Each <zroot>/<arch>/include tree is a full per-arch sysroot; most of the bytes
# are the kernel UAPI headers (linux/, drm/, sound/, ...), which are identical
# across architectures -- only asm/ and bits/ genuinely differ. This hoists every
# file that is BYTE-IDENTICAL across ALL given arches into a single shared
# <zroot>/<common>/include tier and deletes the per-arch copies; files that
# differ (or are missing in some arch) stay per-arch. Callers must then put the
# per-arch dir FIRST on the include search path and <common> as the fallback, so
# the specific copy always wins when it exists -- exactly Zig's
# <arch>-linux-any over any-linux-any ordering (tools/process_headers.zig).
#
# Correctness invariant: a file lands in <common> only if it is present AND
# byte-identical in every arch, so the common copy can never differ from what an
# arch had. A file that differs is left in each arch and, being searched first,
# always shadows any (necessarily absent) common entry. Therefore no arch ever
# resolves a header to different bytes than before the dedup.
#
# Usage: dedup-headers.sh <zroot> <common-name> <arch>...
set -euo pipefail

zroot=$1; common=$2; shift 2
arches=("$@")
[ ${#arches[@]} -ge 2 ] || { echo "dedup-headers: need >=2 arches" >&2; exit 1; }
first=${arches[0]}

mkdir -p "$zroot/$common/include"

# Materialise the reference file list up front: the loop deletes from $first's
# tree as it goes, so we must not stream the list concurrently.
mapfile -d '' files < <(cd "$zroot/$first/include" && find . -type f -print0)

hoisted=0
for f in "${files[@]}"; do
  rel=${f#./}
  same=1
  for a in "${arches[@]}"; do
    cmp -s "$zroot/$first/include/$rel" "$zroot/$a/include/$rel" 2>/dev/null || { same=0; break; }
  done
  [ $same -eq 1 ] || continue
  mkdir -p "$zroot/$common/include/$(dirname "$rel")"
  cp -a "$zroot/$first/include/$rel" "$zroot/$common/include/$rel"
  for a in "${arches[@]}"; do rm -f "$zroot/$a/include/$rel"; done
  hoisted=$((hoisted + 1))
done

# Drop directories left empty by the hoist.
for a in "${arches[@]}" "$common"; do
  find "$zroot/$a/include" -type d -empty -delete 2>/dev/null || true
done

leftover=$(find "$zroot/$first/include" -type f | wc -l)
echo "dedup-headers: hoisted $hoisted shared file(s) into $common/include; $leftover per-arch file(s) remain in $first/include"
