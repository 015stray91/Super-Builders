#!/bin/bash
# Sync an Android common kernel tree for a GKI build.
#
# Usage: sync-gki-source.sh <kernel_root> <android_ver> <kernel_ver> <sub_level> <os_patch_level>
#
# Why this is not a one-line `repo init`:
#
#   The manifest is branched by *month*, not by sublevel.  There is a branch
#   common-android12-5.10-2026-10, but no branch common-android12-5.10-2026-10-270
#   and no tag branch for android12-5.10.270_r00 -- so `repo init -b <that>`
#   cannot name 270.
#
#   Sublevel 270 sits on top of the 2026-10 branch, one merge past it
#   (5.10.269).  Every other sublevel in a month is the same story: 252/257/269
#   are branch heads, while 260/264/270 are tags that land after the branch was
#   cut.
#
#   So: sync the branch the OS patch level names, then check out the exact tag
#   for the requested sublevel.  If the tag does not exist, stay on the branch
#   and say so loudly -- silently building a different kernel than asked for is
#   how an artifact ends up labelled 270 while being 269.
set -euo pipefail

KERNEL_ROOT="${1:?usage: sync-gki-source.sh <kernel_root> <android_ver> <kernel_ver> <sub_level> <os_patch_level>}"
ANDROID_VER="${2:?}"
KERNEL_VER="${3:?}"
SUB_LEVEL="${4:?}"
OS_PATCH="${5:?}"

COMMON_URL="https://android.googlesource.com/kernel/common"
MANIFEST_URL="https://android.googlesource.com/kernel/manifest"

cd "$KERNEL_ROOT"

FORMATTED_BRANCH="${ANDROID_VER}-${KERNEL_VER}-${OS_PATCH}"
TAG="${ANDROID_VER}-${KERNEL_VER}.${SUB_LEVEL}_r00"

echo "=== syncing branch  common-${FORMATTED_BRANCH}"
echo "=== target sublevel ${SUB_LEVEL} (tag ${TAG})"

repo init -u "$MANIFEST_URL" -b "common-${FORMATTED_BRANCH}" --depth=1

# Google moves old monthly branches under refs/heads/deprecated/. Rewrite the
# manifest rather than pinning a dead branch.
REMOTE_BRANCH="$(git ls-remote "$COMMON_URL" "${FORMATTED_BRANCH}")"
if grep -q deprecated <<< "$REMOTE_BRANCH"; then
    echo "=== ${FORMATTED_BRANCH} is deprecated; following it"
    sed -i "s/\"${FORMATTED_BRANCH}\"/\"deprecated\/${FORMATTED_BRANCH}\"/g" .repo/manifests/default.xml
fi

repo --trace sync -c -j"$(nproc --all)" --fail-fast --force-sync --no-clone-bundle

BRANCH_SUBLEVEL=""
if [ -f common/Makefile ]; then
    BRANCH_SUBLEVEL="$(grep '^SUBLEVEL = ' common/Makefile | awk '{print $3}')"
fi
echo "=== branch head is 5.10.${BRANCH_SUBLEVEL:-unknown}"

if [ -z "$SUB_LEVEL" ]; then
    echo "=== no sublevel requested; building the branch head"
    exit 0
fi

if [ "$BRANCH_SUBLEVEL" = "$SUB_LEVEL" ]; then
    echo "=== branch head already matches ${SUB_LEVEL}; nothing to check out"
    exit 0
fi

# The tag is what actually names this sublevel. Fetch it into the common tree
# and move the worktree onto it. --depth=1 fetched history, so ask for the tag
# explicitly instead of assuming it is reachable.
cd common
if ! git fetch --depth=1 origin "refs/tags/${TAG}:refs/tags/${TAG}" 2>/dev/null; then
    echo "::warning::tag ${TAG} not fetchable; staying on 5.10.${BRANCH_SUBLEVEL}"
    echo "::warning::the artifact will be labelled ${SUB_LEVEL} but is 5.10.${BRANCH_SUBLEVEL}"
    exit 0
fi
# -f: repo sync can leave tracked files touched, and a checkout that aborts
# here would silently build the branch head while claiming the tag's sublevel.
git checkout -q -f "refs/tags/${TAG}"

GOT="$(grep '^SUBLEVEL = ' Makefile | awk '{print $3}')"
echo "=== checked out 5.10.${GOT} (${TAG})"
if [ "$GOT" != "$SUB_LEVEL" ]; then
    echo "::error::asked for 5.10.${SUB_LEVEL} but tag ${TAG} contains 5.10.${GOT}"
    exit 1
fi
