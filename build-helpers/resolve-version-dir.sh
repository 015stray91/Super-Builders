# Resolve a (android_version, kernel_version) pair to a patch directory.
#
# Sourced or called by the GKI builders.  Kept in one place because the same
# derivation appeared in several workflows, and each copy had the same flaw:
# it built the name but never checked the directory existed, so a target with no
# patches failed much later with a confusing error (a missing `.patch` file, or
# `patch: **** Can't open` in the middle of a build).
#
# The rule is deliberately strict:
#
#   * `android<NN>-<ver>` must exist.  It encodes both the Android KMI and the
#     kernel version, and those are independent — android12-5.10 and
#     android13-5.10 are different KMIs of the same 5.10.270, not synonyms.
#   * If it does not exist, do NOT silently substitute another Android version.
#     That was the old `case` fallback keyed on kernel version alone, which
#     mapped every 5.10 device — including Android 14 ones — onto the Android 12
#     patch set.  Building against the wrong KMI produces a kernel that loads
#     but does not match the device's vendor modules.
#
# Usage:
#   resolve_version_dir <android_ver> <kernel_ver>   # prints dir or fails

resolve_version_dir() {
    local android_ver="${1:?android_ver required}"
    local kernel_ver="${2:?kernel_ver required}"
    local want="${android_ver}-${kernel_ver}"

    if [ -d "$GITHUB_WORKSPACE/$want" ]; then
        printf '%s\n' "$want"
        return 0
    fi

    # Report what does exist for this kernel version, so the fix is obvious.
    echo "resolve_version_dir: no patch directory '$want'." >&2
    local alt
    alt=$(cd "$GITHUB_WORKSPACE" 2>/dev/null && ls -d "android"*"-${kernel_ver}" 2>/dev/null | tr '\n' ' ')
    if [ -n "$alt" ]; then
        echo "resolve_version_dir: available for kernel ${kernel_ver}: ${alt}" >&2
        echo "resolve_version_dir: these are DIFFERENT Android KMIs of the same kernel;" >&2
        echo "resolve_version_dir: do not substitute one for another." >&2
    else
        echo "resolve_version_dir: no patch directory at all for kernel ${kernel_ver}." >&2
    fi
    return 1
}

# Report the GKI identity of a checked-out kernel tree: KMI generation and
# whether the tree actually carries Google's GKI module contract.
#
#   * KMI_GENERATION comes from build.config.common (the same field that
#     scripts/setlocalversion turns into the "-android12-9" release suffix).
#     It is NOT a sub-level: 5.10-9 and 5.10-4 are both 5.10.270.
#   * A tree with no android/ directory is not GKI at all -- monolithic, like a
#     vendor 5.4/5.10 tree or an x86_64 build from a GKI-derived source. Those
#     have nothing to match, so this is informational, not an error.
#
# Usage: gki_identity <kernel_tree_root>
gki_identity() {
    local tree="${1:?kernel tree required}"
    local gen branch contract

    if [ -f "$tree/build.config.common" ]; then
        gen=$(sed -n 's/^KMI_GENERATION=//p' "$tree/build.config.common" | head -1)
        branch=$(sed -n 's/^BRANCH=//p' "$tree/build.config.common" | head -1)
    fi
    gen="${gen:-0}"

    if [ -d "$tree/android" ]; then
        contract="gki"
    else
        contract="monolithic"
    fi

    printf 'kmi_generation=%s branch=%s contract=%s\n' \
        "$gen" "${branch:-unknown}" "$contract"
}
