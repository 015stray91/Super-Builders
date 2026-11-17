#!/bin/bash
# Keep AnyKernel's device check in sync with the device profile.
#
# Why this exists: the phone answers to four names, and they are not synonyms.
#
#   genevn  - what the bootloader reports. device/motorola/yume/board-info.txt
#             says, literally, "require board=genevn".
#   yume    - what Motorola's own device and vendor trees call it. This is the
#             codename the trees use, and the credit goes to PizzaG, who wrote
#             the yume device work this device depends on.
#   genevn_g - the variant suffix Motorola ships alongside the plain name.
#   XT2315  - the model number.
#
# The recovery tree for this phone accepts all four:
#
#   TARGET_DEVICE_ALT += genevn_g genevn yume XT2315
#
# A kernel package that checks only "genevn" will refuse to flash on a unit that
# reports "yume", and the user sees a device-check failure on a phone the package
# was built for. So the aliases are read from device-profiles.json -- the one
# place they are written down -- rather than hand-copied into anykernel.sh where
# they drift.
#
# Usage:
#   sync-anykernel-devices.sh <anykernel-dir> [profile-json]
#   sync-anykernel-devices.sh --check <anykernel-dir>   # exit 1 if out of sync

set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi

AK_DIR="${1:-}"
PROFILE="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/device-profiles.json}"

if [ -z "$AK_DIR" ]; then
  echo "usage: $0 [--check] <anykernel-dir> [profile-json]" >&2
  exit 2
fi
if [ ! -f "$AK_DIR/anykernel.sh" ]; then
  echo "sync-anykernel-devices: no anykernel.sh in $AK_DIR" >&2
  exit 2
fi
if [ ! -f "$PROFILE" ]; then
  echo "sync-anykernel-devices: no profile at $PROFILE" >&2
  exit 2
fi

# Read the aliases from the profile. The profile is the source of truth; this
# script never invents a name.
mapfile -t ALIASES < <(python3 - "$PROFILE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
g = d["devices"]["genevn-g"]
ident = g.get("identity", {})
names = ident.get("device_alts") or []
if not names:
    # Fall back to the three separate fields rather than fail silently.
    for k in ("codename_board", "codename_tree", "model_number"):
        v = ident.get(k)
        if v:
            names.append(v)
# Keep order stable and drop duplicates while preserving the first occurrence.
seen, out = set(), []
for n in names:
    if n and n not in seen:
        seen.add(n)
        out.append(n)
# AnyKernel reads device.nameN, so more than nine is not expressible anyway.
print("\n".join(out[:8]))
PY
)

if [ "${#ALIASES[@]}" -eq 0 ]; then
  echo "sync-anykernel-devices: the profile lists no device aliases" >&2
  exit 3
fi

echo "aliases from profile: ${ALIASES[*]}"

# Build the replacement block. AnyKernel3 accepts device.name1..device.name8 and
# requires at least one; it treats them as a set, so order does not matter to the
# matcher.
BLOCK=""
for i in "${!ALIASES[@]}"; do
  BLOCK+="device.name$((i + 1))=${ALIASES[$i]}"$'\n'
done

# Report what is there now, so a --check run explains itself.
CURRENT=$(cd "$AK_DIR" && grep -E '^device\.name[0-9]+=' anykernel.sh || true)
if [ "$CURRENT" = "${BLOCK%$'\n'}" ]; then
  echo "anykernel device check already in sync"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "sync-anykernel-devices: OUT OF SYNC" >&2
  echo "  anykernel.sh has:" >&2
  echo "$CURRENT" | sed 's/^/    /' >&2
  echo "  profile wants:" >&2
  printf '%s' "$BLOCK" | sed 's/^/    /' >&2
  echo "  a unit reporting an unlisted name will be refused by the device check" >&2
  exit 1
fi

# Rewrite in place: strip every existing device.nameN line and drop the new block
# in where the first one was. Doing it with python keeps the edit anchored to the
# properties() block instead of sed-matching across the whole file.
python3 - "$AK_DIR/anykernel.sh" "$BLOCK" <<'PY'
import sys

path, block = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)

out, inserted = [], False
for line in lines:
    if line.startswith("device.name") and line.split("=", 1)[0][len("device.name"):].isdigit():
        if not inserted:
            out.append(block)
            inserted = True
        continue
    out.append(line)

if not inserted:
    # No existing line to anchor to. Put the block after do.devicecheck=1, which
    # is where AnyKernel3 expects the device names, or at the top of the file if
    # even that is absent.
    out2, done = [], False
    for line in out:
        out2.append(line)
        if not done and line.startswith("do.devicecheck="):
            out2.append(block)
            done = True
    if not done:
        out2 = [block] + out2
    out = out2

open(path, "w").writelines(out)
print(f"anykernel.sh updated: {len(block.strip().splitlines())} device name(s)")
PY

# Verify the result parses as shell and that the check now accepts every alias.
bash -n "$AK_DIR/anykernel.sh" || {
  echo "sync-anykernel-devices: anykernel.sh no longer parses" >&2
  exit 4
}

NEW=$(cd "$AK_DIR" && grep -E '^device\.name[0-9]+=' anykernel.sh || true)
if [ "$NEW" != "${BLOCK%$'\n'}" ]; then
  echo "sync-anykernel-devices: rewrite did not take" >&2
  exit 4
fi
echo "anykernel device check accepts: ${ALIASES[*]}"
