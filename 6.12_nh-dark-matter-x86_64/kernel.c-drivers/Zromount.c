diff --git a/fs/Kconfig b/fs/Kconfig
index 5e4dea4cf..ff3c8adde 100644
--- a/fs/Kconfig
+++ b/fs/Kconfig
@@ -350,6 +350,13 @@ source "fs/unicode/Kconfig"
 config IO_WQ
 	bool
 
+config ZEROMOUNT
+	bool "ZeroMount Path Redirection Subsystem"
+	default y
+	help
+	  ZeroMount allows path redirection and virtual file injection
+	  without mounting filesystems. Useful for systemless modifications.
+
 endmenu
 
 config KSU_SUSFS_SUS_KSTAT_REDIRECT
diff --git a/fs/Makefile b/fs/Makefile
index e951f5487..5cf04de70 100644
--- a/fs/Makefile
+++ b/fs/Makefile
@@ -139,3 +139,4 @@ obj-$(CONFIG_EFIVAR_FS)		+= efivarfs/
 obj-$(CONFIG_EROFS_FS)		+= erofs/
 obj-$(CONFIG_VBOXSF_FS)		+= vboxsf/
 obj-$(CONFIG_ZONEFS_FS)		+= zonefs/
+obj-$(CONFIG_ZEROMOUNT)		+= zeromount.o
diff --git a/fs/d_path.c b/fs/d_path.c
index a69e2cd36..11678ff56 100644
--- a/fs/d_path.c
+++ b/fs/d_path.c
@@ -8,6 +8,10 @@
 #include <linux/prefetch.h>
 #include "mount.h"
 
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
+
 static int prepend(char **buffer, int *buflen, const char *str, int namelen)
 {
 	*buflen -= namelen;
@@ -265,6 +269,26 @@ char *d_path(const struct path *path, char *buf, int buflen)
 	struct path root;
 	int error;
 
+#ifdef CONFIG_ZEROMOUNT
+	if (path->dentry && d_backing_inode(path->dentry)) {
+		char *v_path = zeromount_get_static_vpath(d_backing_inode(path->dentry));
+
+		if (v_path) {
+			int len = strlen(v_path);
+			if (buflen < len + 1) {
+				kfree(v_path);
+				return ERR_PTR(-ENAMETOOLONG);
+			}
+			*--res = '\0';
+			res -= len;
+			memcpy(res, v_path, len);
+			kfree(v_path);
+			return res;
+		}
+	}
+#endif
+
+
 	/*
 	 * We have various synthetic filesystems that never get mounted.  On
 	 * these filesystems dentries are never used for lookup purposes, and
diff --git a/fs/namei.c b/fs/namei.c
index 3dfde472b..81e8e5547 100644
--- a/fs/namei.c
+++ b/fs/namei.c
@@ -49,6 +49,10 @@
 #include "internal.h"
 #include "mount.h"
 
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
+
 #define CREATE_TRACE_POINTS
 #include <trace/events/namei.h>
 
@@ -214,6 +218,13 @@ getname_flags(const char __user *filename, int flags, int *empty)
 	result->uptr = filename;
 	result->aname = NULL;
 	audit_getname(result);
+
+#ifdef CONFIG_ZEROMOUNT
+	if (!IS_ERR(result)) {
+		result = zeromount_getname_hook(result);
+	}
+#endif
+
 	return result;
 }
 
@@ -361,6 +372,18 @@ int generic_permission(struct inode *inode, int mask)
 {
 	int ret;
 
+#ifdef CONFIG_ZEROMOUNT
+	if (zeromount_is_injected_file(inode)) {
+		if (mask & MAY_WRITE)
+			return -EACCES;
+		return 0;
+	}
+
+	if (S_ISDIR(inode->i_mode) && zeromount_is_traversal_allowed(inode, mask)) {
+		return 0;
+	}
+#endif
+
 	/*
 	 * Do the basic permission checks.
 	 */
@@ -454,6 +477,18 @@ int inode_permission(struct inode *inode, int mask)
 {
 	int retval;
 
+#ifdef CONFIG_ZEROMOUNT
+	if (zeromount_is_injected_file(inode)) {
+		if (mask & MAY_WRITE)
+			return -EACCES;
+		return 0;
+	}
+
+	if (S_ISDIR(inode->i_mode) && zeromount_is_traversal_allowed(inode, mask)) {
+		return 0;
+	}
+#endif
+
 	retval = sb_permission(inode->i_sb, inode, mask);
 	if (retval)
 		return retval;
diff --git a/fs/proc/base.c b/fs/proc/base.c
index 156ce6286..373978ce5 100644
--- a/fs/proc/base.c
+++ b/fs/proc/base.c
@@ -102,6 +102,9 @@
 #endif
 #include <trace/events/oom.h>
 #include "internal.h"
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
 #include "fd.h"
 
 #include "../../lib/kstrtox.h"
@@ -1791,6 +1794,27 @@ static int do_proc_readlink(struct path *path, char __user *buffer, int buflen)
 	if (!tmp)
 		return -ENOMEM;
 
+
+#ifdef CONFIG_ZEROMOUNT
+	if (!zeromount_should_skip() && path->dentry) {
+		struct inode *inode = d_backing_inode(path->dentry);
+		if (inode) {
+			char *vpath = zeromount_get_static_vpath(inode);
+			if (vpath) {
+				int vlen = strlen(vpath);
+				if (vlen > buflen)
+					vlen = buflen;
+				if (copy_to_user(buffer, vpath, vlen) == 0) {
+					kfree(vpath);
+					free_page((unsigned long)tmp);
+					return vlen;
+				}
+				kfree(vpath);
+			}
+		}
+	}
+#endif
+
 	pathname = d_path(path, tmp, PAGE_SIZE);
 	len = PTR_ERR(pathname);
 	if (IS_ERR(pathname))
diff --git a/fs/proc/task_mmu.c b/fs/proc/task_mmu.c
index 7cb00fe68..fd8d787e7 100644
--- a/fs/proc/task_mmu.c
+++ b/fs/proc/task_mmu.c
@@ -19,6 +19,9 @@
 #include <linux/shmem_fs.h>
 #include <linux/uaccess.h>
 #include <linux/pkeys.h>
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
 #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP)
 #include <linux/susfs_def.h>
 #endif
@@ -366,6 +369,9 @@ show_map_vma(struct seq_file *m, struct vm_area_struct *vma)
 #endif
 		dev = inode->i_sb->s_dev;
 		ino = inode->i_ino;
+#ifdef CONFIG_ZEROMOUNT
+		zeromount_spoof_mmap_metadata(inode, &dev, &ino);
+#endif
 #ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
 bypass_orig_flow:
 #endif
diff --git a/fs/readdir.c b/fs/readdir.c
index e5a56fcfc..d0fca7da3 100644
--- a/fs/readdir.c
+++ b/fs/readdir.c
@@ -21,6 +21,9 @@
 #include <linux/unistd.h>
 #include <linux/compat.h>
 #include <linux/uaccess.h>
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
 
 #include <asm/unaligned.h>
 
@@ -323,17 +326,37 @@ SYSCALL_DEFINE3(getdents, unsigned int, fd,
 		.current_dir = dirent
 	};
 	int error;
+#ifdef CONFIG_ZEROMOUNT
+	int initial_count = count;
+#endif
 
 	f = fdget_pos(fd);
 	if (!f.file)
 		return -EBADF;
 
+#ifdef CONFIG_ZEROMOUNT
+	if (f.file->f_pos >= ZEROMOUNT_MAGIC_POS) {
+		error = 0;
+		goto skip_real_iterate;
+	}
+#endif
+
 #ifdef CONFIG_KSU_SUSFS_SUS_PATH
 	buf.sb = f.file->f_inode->i_sb;
 #endif
 	error = iterate_dir(f.file, &buf.ctx);
 	if (error >= 0)
 		error = buf.error;
+
+#ifdef CONFIG_ZEROMOUNT
+skip_real_iterate:
+	if (error >= 0 && !signal_pending(current)) {
+		zeromount_inject_dents(f.file, (void __user **)&dirent, &count, &f.file->f_pos);
+		if (count != initial_count)
+			error = initial_count - count;
+		goto zm_out;
+	}
+#endif
 	if (buf.prev_reclen) {
 		struct linux_dirent __user * lastdirent;
 		lastdirent = (void __user *)buf.current_dir - buf.prev_reclen;
@@ -343,6 +366,9 @@ SYSCALL_DEFINE3(getdents, unsigned int, fd,
 		else
 			error = count - buf.count;
 	}
+#ifdef CONFIG_ZEROMOUNT
+zm_out:
+#endif
 	fdput_pos(f);
 	return error;
 }
@@ -420,17 +446,37 @@ SYSCALL_DEFINE3(getdents64, unsigned int, fd,
 		.current_dir = dirent
 	};
 	int error;
+#ifdef CONFIG_ZEROMOUNT
+	int initial_count = count;
+#endif
 
 	f = fdget_pos(fd);
 	if (!f.file)
 		return -EBADF;
 
+#ifdef CONFIG_ZEROMOUNT
+	if (f.file->f_pos >= ZEROMOUNT_MAGIC_POS) {
+		error = 0;
+		goto skip_real_iterate;
+	}
+#endif
+
 #ifdef CONFIG_KSU_SUSFS_SUS_PATH
 	buf.sb = f.file->f_inode->i_sb;
 #endif
 	error = iterate_dir(f.file, &buf.ctx);
 	if (error >= 0)
 		error = buf.error;
+
+#ifdef CONFIG_ZEROMOUNT
+skip_real_iterate:
+	if (error >= 0 && !signal_pending(current)) {
+		zeromount_inject_dents64(f.file, (void __user **)&dirent, &count, &f.file->f_pos);
+		if (count != initial_count)
+			error = initial_count - count;
+		goto zm_out;
+	}
+#endif
 	if (buf.prev_reclen) {
 		struct linux_dirent64 __user * lastdirent;
 		typeof(lastdirent->d_off) d_off = buf.ctx.pos;
@@ -441,6 +487,9 @@ SYSCALL_DEFINE3(getdents64, unsigned int, fd,
 		else
 			error = count - buf.count;
 	}
+#ifdef CONFIG_ZEROMOUNT
+zm_out:
+#endif
 	fdput_pos(f);
 	return error;
 }
@@ -614,17 +663,37 @@ COMPAT_SYSCALL_DEFINE3(getdents, unsigned int, fd,
 		.count = count
 	};
 	int error;
+#ifdef CONFIG_ZEROMOUNT
+	int initial_count = count;
+#endif
 
 	f = fdget_pos(fd);
 	if (!f.file)
 		return -EBADF;
 
+#ifdef CONFIG_ZEROMOUNT
+	if (f.file->f_pos >= ZEROMOUNT_MAGIC_POS) {
+		error = 0;
+		goto skip_real_iterate;
+	}
+#endif
+
 #ifdef CONFIG_KSU_SUSFS_SUS_PATH
 	buf.sb = f.file->f_inode->i_sb;
 #endif
 	error = iterate_dir(f.file, &buf.ctx);
 	if (error >= 0)
 		error = buf.error;
+
+#ifdef CONFIG_ZEROMOUNT
+skip_real_iterate:
+	if (error >= 0 && !signal_pending(current)) {
+		zeromount_inject_dents(f.file, (void __user **)&dirent, &count, &f.file->f_pos);
+		if (count != initial_count)
+			error = initial_count - count;
+		goto zm_out;
+	}
+#endif
 	if (buf.prev_reclen) {
 		struct compat_linux_dirent __user * lastdirent;
 		lastdirent = (void __user *)buf.current_dir - buf.prev_reclen;
@@ -634,6 +703,9 @@ COMPAT_SYSCALL_DEFINE3(getdents, unsigned int, fd,
 		else
 			error = count - buf.count;
 	}
+#ifdef CONFIG_ZEROMOUNT
+zm_out:
+#endif
 	fdput_pos(f);
 	return error;
 }
diff --git a/fs/stat.c b/fs/stat.c
index 9c699e632..c4a5678b8 100644
--- a/fs/stat.c
+++ b/fs/stat.c
@@ -26,6 +26,9 @@
 #endif
 
 #include <linux/uaccess.h>
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
 #include <asm/unistd.h>
 
 #include "internal.h"
@@ -217,6 +220,41 @@ extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *fla
  *
  * 0 will be returned on success, and a -ve error code if unsuccessful.
  */
+#ifdef CONFIG_ZEROMOUNT
+static inline int zeromount_stat_hook(int dfd, const char __user *filename, 
+                                      struct kstat *stat, unsigned int request_mask, 
+                                      int flags) {
+    if (zm_is_recursive() || IS_ERR_OR_NULL(filename)) return -ENOENT;
+    if (filename) {
+        char kname[NAME_MAX + 1];
+        long copied = strncpy_from_user(kname, filename, sizeof(kname));
+        if (copied > 0 && kname[0] != '/') {
+            char *abs_path = zeromount_build_absolute_path(dfd, kname);
+            if (abs_path) {
+                char *resolved = zeromount_resolve_path(abs_path);
+                if (resolved) {
+                    struct path zm_path;
+                    int zm_ret;
+                    zm_enter();
+                    zm_ret = kern_path(resolved, (flags & AT_SYMLINK_NOFOLLOW) ? 0 : LOOKUP_FOLLOW, &zm_path);
+                    zm_exit();
+                    kfree(resolved);
+                    kfree(abs_path);
+                    if (zm_ret == 0) {
+                        zm_ret = vfs_getattr(&zm_path, stat, request_mask,
+                                             (flags & AT_SYMLINK_NOFOLLOW) ? AT_SYMLINK_NOFOLLOW : 0);
+                        path_put(&zm_path);
+                        return zm_ret;
+                    }
+                } else {
+                    kfree(abs_path);
+                }
+            }
+        }
+    }
+    return -ENOENT;
+}
+#endif
 static int vfs_statx(int dfd, const char __user *filename, int flags,
 	      struct kstat *stat, u32 request_mask)
 {
@@ -224,6 +262,16 @@ static int vfs_statx(int dfd, const char __user *filename, int flags,
 	unsigned lookup_flags = 0;
 	int error;
 
+#ifdef CONFIG_ZEROMOUNT
+	/* Try ZeroMount hook for relative paths */
+	if (filename) {
+		int zm_ret = zeromount_stat_hook(dfd, filename, stat, request_mask, flags);
+		if (zm_ret != -ENOENT)
+			return zm_ret;
+	}
+#endif
+
+
 #ifdef CONFIG_KSU_SUSFS_UNICODE_FILTER
 	if (susfs_check_unicode_bypass(filename)) {
 		return -ENOENT;
diff --git a/fs/statfs.c b/fs/statfs.c
index a21875ca3..093287941 100644
--- a/fs/statfs.c
+++ b/fs/statfs.c
@@ -14,6 +14,9 @@
 #include "mount.h"
 #endif
 #include "internal.h"
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
 
 static int flags_by_mnt(int mnt_flags)
 {
@@ -118,7 +121,14 @@ int user_statfs(const char __user *pathname, struct kstatfs *st)
 retry:
 	error = user_path_at(AT_FDCWD, pathname, lookup_flags, &path);
 	if (!error) {
+#ifdef CONFIG_ZEROMOUNT
+		int spoofed;
+#endif
 		error = vfs_statfs(&path, st);
+#ifdef CONFIG_ZEROMOUNT
+		spoofed = zeromount_spoof_statfs(pathname, st);
+		(void)spoofed;
+#endif
 		path_put(&path);
 		if (retry_estale(error, lookup_flags)) {
 			lookup_flags |= LOOKUP_REVAL;
diff --git a/fs/xattr.c b/fs/xattr.c
index 8d7151492..e21419bd7 100644
--- a/fs/xattr.c
+++ b/fs/xattr.c
@@ -24,6 +24,9 @@
 #include <linux/posix_acl_xattr.h>
 
 #include <linux/uaccess.h>
+#ifdef CONFIG_ZEROMOUNT
+#include <linux/zeromount.h>
+#endif
 
 static const char *
 strcmp_prefix(const char *a, const char *a_prefix)
@@ -403,6 +406,12 @@ EXPORT_SYMBOL(__vfs_getxattr);
 ssize_t
 vfs_getxattr(struct dentry *dentry, const char *name, void *value, size_t size)
 {
+#ifdef CONFIG_ZEROMOUNT
+	ssize_t zm_ret;
+	zm_ret = zeromount_spoof_xattr(dentry, name, value, size);
+	if (zm_ret != -EOPNOTSUPP)
+		return zm_ret;
+#endif
 	return __vfs_getxattr(dentry, dentry->d_inode, name, value, size, 0);
 }
 EXPORT_SYMBOL_NS_GPL(vfs_getxattr, ANDROID_GKI_VFS_EXPORT_ONLY);
diff --git a/fs/zeromount.c b/fs/zeromount.c
new file mode 100644
index 000000000..0b596ea48
--- /dev/null
+++ b/fs/zeromount.c
@@ -0,0 +1,1526 @@
+#include <linux/module.h>
+#include <linux/kernel.h>
+#include <linux/init.h>
+#include <linux/fs.h>
+#include <linux/dcache.h>
+#include <linux/path.h>
+#include <linux/namei.h>
+#include <linux/sched.h>
+#include <linux/slab.h>
+#include <linux/string.h>
+#include <linux/uaccess.h>
+#include <linux/dirent.h>
+#include <linux/miscdevice.h>
+#include <linux/cred.h>
+#include <linux/vmalloc.h>
+#include <linux/mm.h>
+#include <linux/zeromount.h>
+#include <linux/kobject.h>
+#include <linux/sysfs.h>
+#include <linux/statfs.h>
+#include <linux/file.h>
+#include <linux/fs_struct.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs.h>
+#endif
+#include <linux/reboot.h>
+#include <linux/bitmap.h>
+
+int zeromount_debug_level = 0;
+
+DEFINE_HASHTABLE(zeromount_rules_ht, ZEROMOUNT_HASH_BITS);
+DEFINE_HASHTABLE(zeromount_dirs_ht, ZEROMOUNT_HASH_BITS);
+DEFINE_HASHTABLE(zeromount_uid_ht, ZEROMOUNT_HASH_BITS);
+DEFINE_HASHTABLE(zeromount_ino_ht, ZEROMOUNT_HASH_BITS);
+LIST_HEAD(zeromount_rules_list);
+DEFINE_SPINLOCK(zeromount_lock);
+
+atomic_t zeromount_enabled = ATOMIC_INIT(0);
+static atomic_t zeromount_dirs_count = ATOMIC_INIT(0);
+static atomic_t zeromount_rule_count = ATOMIC_INIT(0);
+static DECLARE_BITMAP(zm_bloom, ZM_BLOOM_BITS);
+#define ZEROMOUNT_DISABLED() (atomic_read(&zeromount_enabled) == 0)
+
+static inline void zm_bloom_add(u32 hash)
+{
+	set_bit(hash & ZM_BLOOM_MASK, zm_bloom);
+	set_bit((hash >> 10) & ZM_BLOOM_MASK, zm_bloom);
+	set_bit((hash >> 20) & ZM_BLOOM_MASK, zm_bloom);
+}
+
+static inline bool zm_bloom_test(u32 hash)
+{
+	return test_bit(hash & ZM_BLOOM_MASK, zm_bloom) &&
+	       test_bit((hash >> 10) & ZM_BLOOM_MASK, zm_bloom) &&
+	       test_bit((hash >> 20) & ZM_BLOOM_MASK, zm_bloom);
+}
+
+static void zm_bloom_rebuild(void)
+{
+	struct zeromount_rule *rule;
+	int count = 0;
+
+	bitmap_zero(zm_bloom, ZM_BLOOM_BITS);
+	list_for_each_entry(rule, &zeromount_rules_list, list) {
+		u32 h = full_name_hash(NULL, rule->virtual_path, rule->vp_len);
+		zm_bloom_add(h);
+		count++;
+	}
+	ZM_DBG("bloom: rebuilt (%d rules)\n", count);
+}
+
+struct linux_dirent {
+	unsigned long	d_ino;
+	unsigned long	d_off;
+	unsigned short	d_reclen;
+	char		d_name[];
+};
+
+static unsigned long zm_ino_adb = 0;
+static unsigned long zm_ino_modules = 0;
+
+static inline bool zeromount_is_critical_process(void)
+{
+	const char *comm = current->comm;
+
+	switch (comm[0]) {
+	case 'i': if (comm[1] == 'n' && comm[2] == 'i') return true; break;
+	case 'u': if (comm[1] == 'e' && comm[2] == 'v') return true; break;
+	case 'v': if (comm[1] == 'o' && comm[2] == 'l') return true; break;
+	}
+	if (current->flags & PF_KTHREAD)
+		return true;
+	return false;
+}
+
+bool zeromount_should_skip(void)
+{
+	if (ZEROMOUNT_DISABLED())
+		return true;
+	if (zm_is_recursive())
+		return true;
+	if (unlikely(in_interrupt() || in_nmi() || oops_in_progress))
+		return true;
+	if (!current || !current->mm)
+		return true;
+	if (current->flags & PF_EXITING)
+		return true;
+	if (zeromount_is_critical_process())
+		return true;
+#ifdef CONFIG_KSU_SUSFS
+	if (susfs_is_current_proc_umounted())
+		return true;
+#endif
+	return false;
+}
+EXPORT_SYMBOL(zeromount_should_skip);
+
+bool zeromount_is_uid_blocked(uid_t uid)
+{
+	struct zeromount_uid_node *entry;
+
+	if (ZEROMOUNT_DISABLED())
+		return false;
+#ifdef CONFIG_KSU_SUSFS
+	if (susfs_is_current_proc_umounted()) return true;
+#endif
+
+	rcu_read_lock();
+	hash_for_each_possible_rcu(zeromount_uid_ht, entry, node, uid) {
+		if (entry->uid == uid) {
+			rcu_read_unlock();
+			return true;
+		}
+	}
+	rcu_read_unlock();
+	return false;
+}
+EXPORT_SYMBOL(zeromount_is_uid_blocked);
+
+bool zeromount_match_path(const char *input_path, const char *rule_path)
+{
+	if (!input_path || !rule_path)
+		return false;
+	if (strcmp(input_path, rule_path) == 0)
+		return true;
+	if (strncmp(input_path, "/system", 7) == 0) {
+		if (strcmp(input_path + 7, rule_path) == 0)
+			return true;
+	}
+	return false;
+}
+
+/* Zero-alloc normalize: compute adjusted base and length in-place */
+static inline void zeromount_normalize_inline(const char *path,
+					      const char **out_p,
+					      size_t *out_len)
+{
+	const char *p = path;
+	size_t len;
+
+	if (strncmp(path, "/system/", 8) == 0)
+		p = path + 7;
+
+	len = strlen(p);
+	while (len > 1 && p[len - 1] == '/')
+		len--;
+
+	*out_p = p;
+	*out_len = len;
+}
+
+/* Alloc variant for callers that need a persistent copy */
+static char *zeromount_normalize_path(const char *path)
+{
+	const char *p;
+	size_t len;
+	char *normalized;
+
+	if (!path)
+		return NULL;
+
+	zeromount_normalize_inline(path, &p, &len);
+
+	normalized = kmalloc(len + 1, GFP_KERNEL);
+	if (!normalized)
+		return NULL;
+
+	memcpy(normalized, p, len);
+	normalized[len] = '\0';
+	return normalized;
+}
+
+static void zeromount_free_rule_rcu(struct rcu_head *head)
+{
+	struct zeromount_rule *rule = container_of(head, struct zeromount_rule, rcu);
+
+	kfree(rule->virtual_path);
+	kfree(rule->real_path);
+	kfree(rule);
+}
+
+static void zeromount_free_child_rcu(struct rcu_head *head)
+{
+	struct zeromount_child_name *child =
+		container_of(head, struct zeromount_child_name, rcu);
+
+	kfree(child->name);
+	kfree(child);
+}
+
+static void zeromount_free_dir_node_rcu(struct rcu_head *head)
+{
+	struct zeromount_dir_node *node =
+		container_of(head, struct zeromount_dir_node, rcu);
+
+	kfree(node->dir_path);
+	kfree(node);
+}
+
+static void zeromount_flush_parent(const char *full_path)
+{
+	char *path_copy, *last_slash, *parent_str, *child_name;
+	struct path parent;
+
+	path_copy = kstrdup(full_path, GFP_KERNEL);
+	if (!path_copy)
+		return;
+
+	last_slash = strrchr(path_copy, '/');
+	if (!last_slash || last_slash == path_copy) {
+		kfree(path_copy);
+		return;
+	}
+
+	*last_slash = '\0';
+	parent_str = path_copy;
+	child_name = last_slash + 1;
+
+	if (*child_name == '\0') {
+		kfree(path_copy);
+		return;
+	}
+
+	if (kern_path(parent_str, LOOKUP_FOLLOW, &parent) == 0) {
+		struct dentry *child;
+
+		inode_lock(parent.dentry->d_inode);
+		child = lookup_one_len(child_name, parent.dentry,
+				       strlen(child_name));
+		if (!IS_ERR(child)) {
+			d_invalidate(child);
+			d_drop(child);
+			dput(child);
+		}
+		inode_unlock(parent.dentry->d_inode);
+		path_put(&parent);
+	}
+
+	kfree(path_copy);
+}
+
+static void zeromount_flush_dcache(const char *path_name)
+{
+	struct path path;
+	int err;
+
+	zm_enter();
+	err = kern_path(path_name, LOOKUP_FOLLOW, &path);
+	if (!err) {
+		d_invalidate(path.dentry);
+		d_drop(path.dentry);
+		path_put(&path);
+	} else if (err == -ENOENT) {
+		zeromount_flush_parent(path_name);
+	}
+	zm_exit();
+}
+
+static void zeromount_force_refresh_all(void)
+{
+	struct zeromount_rule *rule;
+	char **paths = NULL;
+	int count = 0, i = 0;
+
+	spin_lock(&zeromount_lock);
+	list_for_each_entry(rule, &zeromount_rules_list, list)
+		count++;
+	spin_unlock(&zeromount_lock);
+
+	if (count == 0)
+		return;
+
+	paths = kvmalloc_array(count, sizeof(char *), GFP_KERNEL);
+	if (!paths)
+		return;
+
+	spin_lock(&zeromount_lock);
+	list_for_each_entry(rule, &zeromount_rules_list, list) {
+		if (i >= count)
+			break;
+		paths[i] = kstrdup(rule->virtual_path, GFP_ATOMIC);
+		if (!paths[i])
+			break;
+		i++;
+	}
+	spin_un