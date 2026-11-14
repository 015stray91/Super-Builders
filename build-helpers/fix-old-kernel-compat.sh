#!/bin/bash
# Runs BEFORE patch application — only fix vanilla kernel issues here
# Post-patch fixes (show_pad, etc.) are in each build workflow
set -euo pipefail

KERNEL_COMMON="$1"
SUBLEVEL="$2"

cd "$KERNEL_COMMON" || exit 1

# 6.6.30-46: namespace.c missing <trace/hooks/fs.h> — added in 6.6.50
if (( SUBLEVEL < 50 )); then
  if ! grep -q 'trace/hooks/fs\.h' fs/namespace.c; then
    sed -i '/#include <trace\/hooks\/blk\.h>/a #include <trace/hooks/fs.h>' fs/namespace.c
  fi
fi
