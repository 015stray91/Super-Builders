
```c
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * hybrid_mount.h - Hybrid Mount subsystem for KernelSU Next
 *
 * Combines Zero Mount, Hybrid Mount, and SUSFS logics
 * for overlay filesystem management and rootless
 * module injection in the Android kernel.
 */

#ifndef _HYBRID_MOUNT_H_
#define _HYBRID_MOUNT_H_

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/mount.h>
#include <linux/namespace.h>
#include <linux/path.h>
#include <linux/dcache.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/spinlock.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/namei.h>
#include <linux/overlayfs.h>
#include <linux/version.h>

/* ========== Version & Identification ========== */
#define HMRID_MOUNT_VERSION   "2.1.0"
#define HMRID_MOUNT_NAME      "hybrid_mount"
#define HMRID_MOUNT_DESC      "Hybrid Mount — Zero Mount + SUSFS unified"

/* ========== Configuration Limits ========== */
#define HM_MAX_MODULES        64
#define HM_MAX_OVERLAY_DIRS   8
#define HM_MAX_MOUNT_POINTS   32
#define HM_MAX_PATH_LEN       256

/* ========== Proc Filesystem Entries ========== */
#define HM_PROC_DIR           "hybrid_mount"
#define HM_PROC_STATUS        "status"
#define HM_PROC_MODULES       "modules"
#define HM_PROC_MOUNTS        "mounts"

/* ========== Mount Type Flags ========== */
#define HM_FLAG_ZERO_MOUNT     BIT(0)   /* Zero mount (stealth) */
#define HM_FLAG_HYBRID_MOUNT   BIT(1)   /* Hybrid mount (dual overlay) */
#define HM_FLAG_SUSFS_MOUNT    BIT(2)   /* SUSFS integration */
#define HM_FLAG_MAGIC_MOUNT    BIT(6)   /* Legacy magic mount compat */

/* ========== Mount Behavior Flags ========== */
#define HM_FLAG_HIDE_MOUNT     BIT(3)   /* Hide from /proc/mounts */
#define HM_FLAG_BIND_MOUNT     BIT(4)   /* Bind mount instead of overlay */
#define HM_FLAG_MODULE_MOUNT   BIT(5)   /* Module-specific mount */
#define HM_FLAG_FORCE_MOUNT    BIT(7)   /* Force mount even if busy */

/* ========== Return Codes ========== */
#define HM_SUCCESS              0
#define HM_ERR_INVALID_ARG     (-1)
#define HM_ERR_NO_MEMORY       (-2)
#define HM_ERR_MOUNT_FAILED    (-3)
#define HM_ERR_ALREADY_MOUNTED (-4)
#define HM_ERR_NOT_FOUND       (-5)
#define HM_ERR_PERMISSION      (-6)
#define HM_ERR_BUSY            (-7)
#define HM_ERR_MODULE_FULL     (-8)
#define HM_ERR_GENERIC         (-99)

/* ========== Data Structures ========== */

/* Single overlay layer (lower/upper/work/merged) */
struct hm_overlay_layer {
    char lower_path[HM_MAX_PATH_LEN];   /* Read-only lower directory */
    char upper_path[HM_MAX_PATH_LEN];   /* Writable upper directory */
    char work_path[HM_MAX_PATH_LEN];    /* OverlayFS work directory */
    char merged_path[HM_MAX_PATH_LEN];  /* Where overlay is mounted */
    bool active;                         /* Layer activation state */
    bool visible;                        /* Visibility in /proc/mounts */
};

/* Individual mount entry tracking one overlay mount */
struct hm_mount_entry {
    struct list_head    list;            /* Linked list node */
    u32                 id;              /* Unique mount identifier */
    u32                 flags;           /* HM_FLAG_* combination */
    char                mount_point[HM_MAX_PATH_LEN]; /* Target mount point */
    char                module_name[HM_MAX_PATH_LEN]; /* Owning module name */
    struct hm_overlay_layer layer;       /* Overlay configuration */
    struct vfsmount    *vfsmnt;          /* VFS mount reference */
    bool                is_mounted;      /* Current mount state */
    bool                is_hidden;       /* Hidden from procfs? */
    ktime_t             mount_time;      /* Mount timestamp */
    struct list_head    module_list;     /* Per-module mount list */
};

/* Module entry representing a loaded