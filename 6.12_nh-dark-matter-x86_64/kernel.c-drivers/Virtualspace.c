```c
/* SPDX-License-Identifier: GPL-2.0 */
/*
 * hybrid_mount.c - Hybrid Mount subsystem implementation
 *
 * Implements the hybrid mount framework for KernelSU Next:
 *   - Zero Mount (stealth overlay via /proc hiding)
 *   - Hybrid Mount (dual-overlay mount controller)
 *   - SUSFS integration hooks
 *   - kio-fuse upstream mount virtualization
 *   - KDE Connect device sync (level 2)
 *   - Virtual network mounts (VPS / desktop / phone)
 *   - Magic mount expansion + overlay device management
 *   - /proc/hybrid_mount/* status and control interface
 */

#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/mutex.h>
#include <linux/rwsem.h>
#include <linux/spinlock.h>
#include <linux/sched.h>
#include <linux/nsproxy.h>
#include <linux/mount.h>
#include <linux/namespace.h>
#include <linux/fs.h>
#include <linux/path.h>
#include <linux/dcache.h>
#include <linux/namei.h>
#include <linux/overlayfs.h>
#include <linux/workqueue.h>
#include <linux/timer.h>
#include <linux/version.h>
#include <linux/net.h>
#include <linux/socket.h>
#include <linux/in.h>
#include <linux/inet.h>
#include <linux/file.h>
#include <linux/uaccess.h>
#include <linux/atomic.h>
#include <linux/compiler.h>

/* Pull in our own header */
#include "hybrid_mount.h"

/* ================================================================
 *  Module metadata
 * ================================================================ */
MODULE_LICENSE("GPL");
MODULE_AUTHOR("KernelSU Next Team");
MODULE_DESCRIPTION(HM_DESCRIPTION);
MODULE_VERSION(HM_VERSION);

/* ================================================================
 *  Global state
 * ================================================================ */

static atomic_t hm_mount_count = ATOMIC_INIT(0);
static atomic_t hm_module_count = ATOMIC_INIT(0);

static DEFINE_MUTEX(hm_mutex);              /* global mount lock */
static DEFINE_RWSEM(hm_rwsem);              /* read-write for mount table */
static DEFINE_SPINLOCK(hm_spinlock);        /* spinlock for quick flags */
static struct proc_dir_entry *hm_proc_dir;  /* /proc/hybrid_mount */
static bool hm_initialized = false;

/* ================================================================
 *  Core data structures
 * ================================================================ */

/**
 * struct hm_mount_point - Represents a single mount entry
 * @id:           Unique mount identifier
 * @source:       Source path (overlay lower, bind, etc.)
 * @target:       Target filesystem path
 * @type:         Mount type (overlay, fuse, bind, network)
 * @flags:        HM_FLAG_* bitmask
 * @sync_level:   HM_SYNC_LEVEL_* (0-4)
 * @active:       Whether mount is currently active
 * @node:         List linkage
 * @kio_fuse:     Associated kio-fuse context (if any)
 * @kde_device:   Associated KDE device ID (if any)
 */
struct hm_mount_point {
	unsigned int    id;
	char            source[HM_MAX_PATH_LEN];
	char            target[HM_MAX_PATH_LEN];
	char            type[64];
	unsigned long   flags;
	int             sync_level;
	bool            active;
	struct list_head node;
	void           *kio_fuse;
	unsigned int    kde_device;
};

/* Global mount table */
static LIST_HEAD(hm_mount_list);

/**
 * struct hm_module_info - Stores a loaded module's mount info
 * @name:         Module name
 * @path:         Module's overlay source path
 * @flags:        HM_FLAG_* for this module
 * @mounted:      Whether it's currently mounted
 * @node:         List linkage
 */
struct hm_module_info {
	char            name[HM_MAX_PATH_LEN];
	char            path[HM_MAX_PATH_LEN];
	unsigned long   flags;
	bool            mounted;
	struct list_head node;
};

static LIST_HEAD(hm_module_list);

/**
 * struct hm_kio_fuse_info - kio-fuse mount context
 * @id:           kio-fuse instance ID
 * @url:          kio-fuse URL (e.g., sftp://, fish://, smb://)
 * @mount_point:  Path where kio-fuse is mounted
 * @active:       Whether this kio-fuse instance is active
 * @node:         List linkage
 */
struct hm_kio_fuse_info {
	unsigned int    id;
	char            url[HM_MAX_URL_LEN];
	char            mount_point[HM_MAX_PATH_LEN];
	bool            active;
	struct list_head node;
};

static LIST_HEAD(hm_kio_fuse_list);

/**
 * struct hm_kde_device - KDE Connect device info
 * @device_id:    KDE Connect device identifier
 * @name:         Device display name
 * @address:      Device network address (IP)
 * @sync_level:   HM_SYNC_LEVEL_* for this device
 * @paired:       Whether device is paired
 * @online:       Whether device is reachable
 * @node:         List linkage
 */
struct hm_kde_device {
	unsigned int    device_id;
	char            name[64];
	char            address[HM_MAX_HOST_LEN];
	int             sync_level;
	bool            paired;
	bool            online;
	struct list_head node;
};

static LIST_HEAD(hm_kde_device_list);

/**
 * struct hm_network_mount - Virtual network mount point
 * @id:           Network mount ID
 * @protocol:     Protocol string (e.g., "ssh", "smb", "webdav")
 * @host:         Remote host address
 * @remote_path:  Remote path to mount
 * @local_path:   Local mount point
 * @connected:    Whether currently connected
 * @node:         List linkage
 */
struct hm_network_mount {
	unsigned int    id;
	char            protocol[32];
	char            host[HM_MAX_HOST_LEN];
	char            remote_path[HM_MAX_PATH_LEN];
	char            local_path[HM_MAX_PATH_LEN];
	bool            connected;
	struct list_head node;
};

static LIST_HEAD(hm_network_mount_list);

/* ================================================================
 *  Work queues and timers
 * ================================================================ */

static struct workqueue_struct *hm_workqueue;
static struct work_struct hm_cleanup_work;

/* Deferred mount work item */
struct hm_mount_work {
	struct work_struct  work;
	unsigned int        mount_id;
	char                source[HM_MAX_PATH_LEN];
	char                target[HM_MAX_PATH_LEN];
	char                type[64];
	unsigned long       flags;
};

/* Periodic cleanup timer */
static struct timer_list hm_cleanup_timer;

/* ================================================================
 *  Internal helpers
 * ================================================================ */

/**
 * hm_find_mount_locked - Find a