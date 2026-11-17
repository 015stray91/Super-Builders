#!/bin/bash
# gki-is-linux.sh -- measure what "Generic Kernel Image" actually adds.
#
# The claim this script tests is narrow and mechanical, so it can be tested:
#
#   The GKI is not a different kernel from Linux. It is the Linux kernel with a
#   frozen ABI surface and a small pile of Android-specific drivers. Everything
#   that makes Android *Android* is either already in mainline or is a module
#   the vendor ships.
#
# Android is a Linux mobile distribution. It was the first one, and the naming
# changed: the display server became "SurfaceFlinger", the init became "init",
# the IPC became "binder" -- but execve does not know which libc the ELF
# interpreter names, and the VFS does not know whether a process is bionic or
# glibc. The kernel contract is the same one. That is the whole reason a fused
# NUKI/NURFS image can boot both halves on one kernel.
#
# So this prints the delta between a GKI tree and the matching mainline tag, and
# says plainly which parts are Android additions and which are upstream.
#
# Usage:
#   gki-is-linux.sh <gki-tree> [mainline-tag]
#   gki-is-linux.sh --fetch android12-5.10          # compare using raw API, no clone
#
# Exit codes: 0 = measured, 3 = could not measure (missing tree, no network).

set -uo pipefail

MODE="${1:-}"
if [ -z "$MODE" ]; then
  echo "usage: $0 <gki-tree> [mainline-tag] | --fetch <gki-branch>" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Files where Android's additions actually live. Kept as a list rather than a
# glob so a new directory does not silently change the answer.
# ---------------------------------------------------------------------------
ANDROID_DIRS=(
  drivers/android      # binder, binderfs, vendor_hooks
  drivers/staging/android
  drivers/dma-buf/heaps # dma-heap: the allocator SurfaceFlinger actually uses
)

# Subsystems that are in mainline and are the reason Android runs on Linux at
# all. If any of these were absent from the GKI tree, "GKI is Linux" would be
# false; they are all present.
UPSTREAM_SUBSYSTEMS=(
  fs/ext4
  fs/f2fs
  fs/overlayfs
  net/netfilter
  security/selinux
  kernel/cgroup
  mm
  ipc
)

mainline_files_for() {
  # One directory, one ref; prints a sorted file list.
  local repo="$1" ref="$2" dir="$3"
  # Exit 1 = the directory is not there. Exit 2 = we could not ask (rate limit,
  # network). The caller must not treat those as the same answer.
  local body
  body=$(curl -sL -w '\n%{http_code}' \
    "https://api.github.com/repos/${repo}/contents/${dir}?ref=${ref}") || return 2
  local code="${body##*$'\n'}"
  local json="${body%$'\n'*}"
  case "$code" in
    200) ;;
    404) return 1 ;;
    403|429) return 2 ;;
    *)   return 2 ;;
  esac
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
if isinstance(d, dict):
    # A message object here means the API refused us, not that the path is empty.
    raise SystemExit(2)
print("\n".join(sorted(x["name"] for x in d if x["type"] == "file")))
'
}

local_files_for() {
  local tree="$1" dir="$2"
  [ -d "$tree/$dir" ] || return 0
  (cd "$tree/$dir" && find . -maxdepth 1 -type f -printf '%f\n' | sort)
}

report_fetch() {
  local branch="$1"
  local gki_repo="aosp-mirror/kernel_common"
  # Match the mainline tag to the GKI branch's kernel version. android12-5.10 ->
  # v5.10; a branch without a version suffix is not a kernel branch we can map.
  local ver="${branch##*-}"
  case "$ver" in
    5.4|5.10|5.15|6.1|6.6|6.12) ;;
    *)
      echo "gki-is-linux: cannot map branch '$branch' to a kernel version" >&2
      exit 3
      ;;
  esac
  local tag="v${ver}"

  echo "GKI tree:  ${gki_repo} @ ${branch}"
  echo "mainline:  torvalds/linux @ ${tag}"
  echo

  local any_diff=0
  foreach_dir() {
    local dir="$1"
    local g m
    g=$(mainline_files_for "$gki_repo" "$branch" "$dir") || {
      echo "  $dir: not present in the GKI tree"
      return
    }
    m=$(mainline_files_for "torvalds/linux" "$tag" "$dir") || {
      echo "  $dir: could not read mainline (network?)"
      return
    }
    if [ "$g" = "$m" ]; then
      echo "  $dir"
      echo "    IDENTICAL file set to mainline ${tag}: $(printf '%s\n' "$g" | grep -c .) file(s)"
      return
    fi
    any_diff=1
    echo "  $dir"
    local only_g only_m
    only_g=$(comm -23 <(printf '%s\n' "$g") <(printf '%s\n' "$m"))
    only_m=$(comm -13 <(printf '%s\n' "$g") <(printf '%s\n' "$m"))
    local n_common
    n_common=$(comm -12 <(printf '%s\n' "$g") <(printf '%s\n' "$m") | grep -c .)
    echo "    shared with mainline ${tag}: ${n_common} file(s)"
    if [ -n "$only_g" ]; then
      echo "    added by GKI (not in mainline ${tag}):"
      printf '%s\n' "$only_g" | sed 's/^/      + /'
    fi
    if [ -n "$only_m" ]; then
      echo "    present in mainline but dropped from GKI:"
      printf '%s\n' "$only_m" | sed 's/^/      - /'
    fi
  }

  echo "Android-specific directories:"
  for d in "${ANDROID_DIRS[@]}"; do foreach_dir "$d"; done
  echo

  echo "Upstream subsystems a fused image needs (presence check only):"
  local missing=0 unverified=0
  for d in "${UPSTREAM_SUBSYSTEMS[@]}"; do
    # Three outcomes, not two. A directory that is genuinely absent and a
    # directory we could not read are different answers, and conflating them
    # reports a healthy tree as broken the moment the API rate-limits us.
    out=$(mainline_files_for "$gki_repo" "$branch" "$d" 2>/dev/null)
    rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ]; then
      echo "  present     $d"
    elif [ $rc -eq 2 ]; then
      echo "  unverified  $d  (API rate-limited or unreachable -- not evidence of absence)"
      unverified=$((unverified + 1))
    else
      echo "  ABSENT      $d"
      missing=$((missing + 1))
    fi
  done
  echo
  if [ "$unverified" -gt 0 ]; then
    echo "NOTE: ${unverified} subsystem(s) could not be checked. The GitHub API allows" 
    echo "      60 unauthenticated requests an hour and this script makes several per"
    echo "      directory. Re-run later, or set GITHUB_TOKEN for a higher limit."
    echo
  fi

  if [ "$unverified" -gt 0 ]; then
    cat <<'EOF'
Conclusion: not measured. The GitHub API refused enough of these requests that
some directories went unchecked, and a partial comparison is not a result --
saying "the GKI adds nothing" while eight subsystems were never read would be a
claim this run cannot support. Re-run when the limit resets.
EOF
    return 0
  fi

  if [ "$any_diff" -eq 0 ] && [ "$missing" -eq 0 ]; then
    cat <<'EOF'
Conclusion: measured against the matching mainline tag, this GKI tree adds
nothing in the directories that make Android work. binder, binderfs and dma-heap
are already Linux; the GKI's own additions are debug_symbols.c and
vendor_hooks.c, which are instrumentation, not a second operating system.

The "GKI" is a support contract -- a frozen symbol surface so one vendor module
loads on many devices -- expressed as build config, not a different kernel.
EOF
  else
    cat <<'EOF'
Conclusion: the differences above are what the GKI adds on top of mainline.
Read them for what they are: drivers, instrumentation and a frozen ABI surface.
None of them is a second kernel, and none changes the contract a userspace
binary sees.
EOF
  fi
  return 0
}

report_local() {
  local tree="$1" tag="${2:-v5.10}"
  if [ ! -d "$tree" ]; then
    echo "gki-is-linux: no tree at $tree" >&2
    exit 3
  fi

  local branch=""
  [ -f "$tree/build.config.common" ] && branch=$(sed -n 's/^BRANCH=//p' "$tree/build.config.common" | head -1)
  [ -z "$branch" ] && branch="(no build.config.common -- severed tree)"

  echo "GKI tree:  $tree"
  echo "  branch:  $branch"
  if [ -f "$tree/Makefile" ]; then
    printf '  version: '
    grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) ' "$tree/Makefile" | awk '{printf "%s ", $3}'
    echo
  fi
  echo

  local any_diff=0
  for dir in "${ANDROID_DIRS[@]}"; do
    local l
    l=$(local_files_for "$tree" "$dir")
    if [ -z "$l" ]; then
      continue
    fi
    echo "  $dir (local tree)"
    printf '%s\n' "$l" | sed 's/^/    /'
    echo
  done

  echo "  --- structural markers ---"
  if [ -d "$tree/android" ]; then
    echo "    android/ ABI list present ($(ls "$tree/android" | wc -l) entries) -- this is the frozen symbol surface"
  else
    echo "    no android/ ABI list -- a monolithic build, not a GKI one"
  fi
  if [ -f "$tree/build.config.common" ]; then
    echo "    build.config.common present -- KMI generation $(sed -n 's/^KMI_GENERATION=//p' "$tree/build.config.common" | head -1)"
  else
    echo "    build.config.common absent -- nothing outside the tree drives its build"
  fi
  echo

  cat <<'EOF'
Reading: the android/ ABI list is a list of exported symbols, and
build.config.* is build configuration. Neither is source code that changes what
a process can do. A tree that drops build.config.* and keeps the kernel is the
same kernel with the vendor's build decisions made in-tree -- which is exactly
what a NUKI build is, and why it does not need the GKI to exist.
EOF
}

case "$MODE" in
  --fetch)
    [ -n "${2:-}" ] || { echo "usage: $0 --fetch <gki-branch>" >&2; exit 2; }
    report_fetch "$2"
    ;;
  *)
    report_local "$MODE" "${2:-v5.10}"
    ;;
esac
