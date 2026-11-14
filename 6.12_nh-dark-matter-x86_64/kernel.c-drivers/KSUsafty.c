diff -ruN '--exclude=include' clean-kernel/Kbuild work-kernel/Kbuild
--- a/kernel/Kbuild	2026-04-09 11:57:48.449755460 +0100
+++ b/kernel/Kbuild	2026-04-09 12:49:20.616852994 +0100
@@ -139,4 +139,14 @@
 ccflags-y += -Wno-strict-prototypes -Wno-int-conversion -Wno-gcc-compat -Wno-missing-prototypes
 ccflags-y += -Wno-declaration-after-statement -Wno-unused-function -Wno-unused-variable
 
+## For susfs stuff ##
+ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
+$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
+$(info )
+$(info -- SUSFS_VERSION: $(SUSFS_VERSION))
+else
+$(info -- You have not integrated susfs in your kernel yet.)
+$(info -- Read: https://gitlab.com/simonpunk/susfs4ksu)
+endif
+
 # Keep a new line here!! Because someone may append config
diff -ruN '--exclude=include' clean-kernel/Kconfig work-kernel/Kconfig
--- a/kernel/Kconfig	2026-04-09 11:57:48.449755460 +0100
+++ b/kernel/Kconfig	2026-04-09 12:49:07.894586046 +0100
@@ -35,4 +35,94 @@
 	  Escalation will always use the default full root profile, and
 	  non-root handling will follow the global umount policy only.
 
+menu "KernelSU - SUSFS"
+config KSU_SUSFS
+	bool "KernelSU addon - SUSFS"
+	depends on KSU
+	depends on THREAD_INFO_IN_TASK
+	default y
+	help
+	  Patch and Enable SUSFS to kernel with KernelSU.
+
+config KSU_SUSFS_SUS_PATH
+	bool "Enable to hide suspicious path (NOT recommended)"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Allow hiding the user-defined path and all its sub-paths from various system calls.
+	  - Includes temp fix for the leaks of app path in /sdcard/Android/data directory.
+	  - Effective only on zygote spawned user app process.
+	  - Use with cautious as it may cause performance loss and will be vulnerable to side channel attacks,
+	    just disable this feature if it doesn't work for you or you don't need it at all.
+
+config KSU_SUSFS_SUS_MOUNT
+	bool "Enable to hide suspicious mounts"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Allow hiding the user-defined mount paths from /proc/self/[mounts|mountinfo|mountstat].
+	  - Effective on all processes for hiding mount entries.
+	  - mnt_id and mnt_group_id of the sus mount will be assigned to a much bigger number to solve the issue of id not being contiguous.
+
+config KSU_SUSFS_SUS_KSTAT
+	bool "Enable to spoof suspicious kstat"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Allow spoofing the kstat of user-defined file/directory.
+	  - Effective only on zygote spawned user app process.
+
+config KSU_SUSFS_SPOOF_UNAME
+	bool "Enable to spoof uname"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Allow spoofing the string returned by uname syscall to user-defined string.
+	  - Effective on all processes.
+
+config KSU_SUSFS_ENABLE_LOG
+	bool "Enable logging susfs log to kernel"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Allow logging susfs log to kernel, uncheck it to completely disable all susfs log.
+
+config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
+	bool "Enable to automatically hide ksu and susfs symbols from /proc/kallsyms"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Automatically hide ksu and susfs symbols from '/proc/kallsyms'.
+	  - Effective on all processes.
+
+config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
+	bool "Enable to spoof /proc/bootconfig (gki) or /proc/cmdline (non-gki)"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Spoof the output of /proc/bootconfig (gki) or /proc/cmdline (non-gki) with a user-defined file.
+	  - Effective on all processes.
+
+config KSU_SUSFS_OPEN_REDIRECT
+	bool "Enable to redirect a path to be opened with another path (experimental)"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Allow redirecting a target path to be opened with another user-defined path.
+	  - Effective only on processes with uid < 2000.
+	  - Please be reminded that process with open access to the target and redirected path can be detected.
+
+config KSU_SUSFS_SUS_MAP
+	bool "Enable to hide some mmapped real file from different proc maps interfaces"
+	depends on KSU_SUSFS
+	default y
+	help
+	  - Allow hiding mmapped real file from /proc/<pid>/[maps|smaps|smaps_rollup|map_files|mem|pagemap]
+	  - It does NOT support hiding for anon memory.
+	  - It does NOT hide any inline hooks or plt hooks cause by the injected library itself.
+	  - It may not be able to evade detections by apps that implement a good injection detection.
+	  - Effective only on zygote spawned umounted user app process.
+
+endmenu
+
 endmenu
diff -ruN '--exclude=include' clean-kernel/core/init.c work-kernel/core/init.c
--- a/kernel/core/init.c	2026-04-09 11:57:48.449755460 +0100
+++ b/kernel/core/init.c	2026-04-09 12:53:05.759034461 +0100
@@ -5,6 +5,9 @@
 #include <linux/rcupdate.h>
 #include <linux/sched.h>
 #include <linux/workqueue.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs.h>
+#endif // #ifdef CONFIG_KSU_SUSFS
 
 #include "policy/allowlist.h"
 #include "policy/app_profile.h"
@@ -132,6 +135,11 @@
 		ksu_syscall_hook_manager_init();
 
 		ksu_throne_tracker_init();
+
+#ifdef CONFIG_KSU_SUSFS
+		susfs_init();
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 		ksu_observer_init();
 		ksu_file_wrapper_init();
 
@@ -150,6 +158,10 @@
 
 		ksu_throne_tracker_init();
 
+#ifdef CONFIG_KSU_SUSFS
+		susfs_init();
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 		ksu_ksud_init();
 
 		ksu_file_wrapper_init();
diff -ruN '--exclude=include' clean-kernel/feature/kernel_umount.c work-kernel/feature/kernel_umount.c
--- a/kernel/feature/kernel_umount.c	2026-04-09 11:57:48.449755460 +0100
+++ b/kernel/feature/kernel_umount.c	2026-04-09 12:52:07.532321601 +0100
@@ -72,6 +72,10 @@
 	struct callback_head cb;
 };
 
+#ifdef CONFIG_KSU_SUSFS_SUS_PATH
+extern void susfs_run_sus_path_loop(void);
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_PATH
+
 int ksu_handle_umount(uid_t old_uid, uid_t new_uid)
 {
 	// if there isn't any module mounted, just ignore it!
@@ -87,6 +91,7 @@
 		return 0;
 	}
 
+#ifndef CONFIG_KSU_SUSFS
     // There are 6 scenarios:
     // 1. Normal app: zygote -> appuid
     // 2. Isolated process forked from zygote: zygote -> isolated_process
@@ -111,6 +116,8 @@
 		pr_info("handle umount ignore non zygote child: %d\n", current->pid);
 		return 0;
 	}
+#endif // #ifndef CONFIG_KSU_SUSFS
+
 	// umount the target mnt
 	pr_info("handle umount for uid: %d, pid: %d\n", new_uid, current->pid);
 
@@ -124,6 +131,11 @@
 	}
 	up_read(&mount_list_lock);
 
+#ifdef CONFIG_KSU_SUSFS_SUS_PATH
+	// susfs_run_sus_path_loop() runs here with ksu_cred so that it can reach all the paths
+	susfs_run_sus_path_loop();
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_PATH
+
 	revert_creds(saved);
 
 	return 0;
diff -ruN '--exclude=include' clean-kernel/feature/sucompat.c work-kernel/feature/sucompat.c
--- a/kernel/feature/sucompat.c	2026-04-09 11:57:48.450082382 +0100
+++ b/kernel/feature/sucompat.c	2026-04-09 14:24:35.069714756 +0100
@@ -11,6 +11,12 @@
 #include <linux/version.h>
 #include <linux/sched/task_stack.h>
 #include <linux/ptrace.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs_def.h>
+#include <linux/namei.h>
+#include "selinux/selinux.h"
+#include "objsec.h"
+#endif // #ifdef CONFIG_KSU_SUSFS
 
 #include "policy/allowlist.h"
 #include "policy/feature.h"
@@ -71,6 +77,7 @@
 	return userspace_stack_buffer(ksud_path, sizeof(ksud_path));
 }
 
+#ifndef CONFIG_KSU_SUSFS
 int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
 		int *mode, int *__unused_flags)
 {
@@ -118,6 +125,130 @@
 
 	return 0;
 }
+#else
+static const char sh_path[] = SH_PATH;
+static const char su_path[] = SU_PATH;
+static const char ksud_path[] = KSUD_PATH;
+
+/*
+ * Returns 0 when no further sucompat checks should run, 1 otherwise.
+ * Called from ksu_handle_execveat_ksud under CONFIG_KSU_SUSFS.
+ */
+int ksu_handle_execveat_init(const char *path)
+{
+	if (!path) {
+		return 1;
+	}
+	if (current->pid != 1 && is_init(get_current_cred())) {
+		if (unlikely(strcmp(path, KSUD_PATH) == 0)) {
+			pr_info("hook_manager: escape to root for init executing ksud: %d\n",
+				current->pid);
+			escape_to_root_for_init();
+		} else if (likely(strstr(path, "/app_process") == NULL &&
+				  strstr(path, "/adbd") == NULL) &&
+			   !susfs_is_current_proc_umounted()) {
+			pr_info("susfs: mark no sucompat checks for pid: '%d', exec: '%s'\n",
+				current->pid, path);
+			susfs_set_current_proc_umounted();
+		}
+		return 0;
+	}
+	return 1;
+}
+
+int ksu_handle_devpts(struct inode *inode)
+{
+	if (!current->mm) {
+		return 0;
+	}
+
+	uid_t uid = current_uid().val;
+	if (uid % 100000 < 10000) {
+		return 0;
+	}
+
+	if (!ksu_is_allow_uid_for_current(uid))
+		return 0;
+
+	if (ksu_file_sid) {
+		struct inode_security_struct *sec = selinux_inode(inode);
+		if (sec) {
+			sec->sid = ksu_file_sid;
+		}
+	}
+
+	return 0;
+}
+
+int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
+				 void *__never_use_argv,
+				 void *__never_use_envp,
+				 int *__never_use_flags)
+{
+	struct filename *filename;
+
+	if (unlikely(!filename_ptr))
+		return 0;
+
+	filename = *filename_ptr;
+	if (IS_ERR(filename)) {
+		return 0;
+	}
+
+	if (!ksu_handle_execveat_init(filename->name)) {
+		return 0;
+	}
+
+	if (likely(memcmp(filename->name, su_path, sizeof(su_path))))
+		return 0;
+
+	pr_info("ksu_handle_execveat_sucompat: su found\n");
+	memcpy((void *)filename->name, ksud_path, sizeof(ksud_path));
+
+	escape_with_root_profile();
+
+	return 0;
+}
+
+int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
+			void *envp, int *flags)
+{
+	return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
+}
+
+int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,
+			 int *__unused_flags)
+{
+	char path[sizeof(su_path) + 1] = { 0 };
+
+	strncpy_from_user_nofault(path, *filename_user, sizeof(path));
+
+	if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
+		pr_info("ksu_handle_faccessat: su->sh!\n");
+		*filename_user = sh_user_path();
+	}
+
+	return 0;
+}
+
+int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
+{
+	if (unlikely(!filename_user)) {
+		return 0;
+	}
+
+	char path[sizeof(su_path) + 1] = { 0 };
+
+	strncpy_from_user_nofault(path, *filename_user, sizeof(path));
+
+	if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
+		pr_info("ksu_handle_stat: su->sh!\n");
+		*filename_user = sh_user_path();
+	}
+
+	return 0;
+}
+#endif // #ifndef CONFIG_KSU_SUSFS
 
 long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs)
 {
diff -ruN '--exclude=include' clean-kernel/hook/setuid_hook.c work-kernel/hook/setuid_hook.c
--- a/kernel/hook/setuid_hook.c	2026-04-09 11:57:48.450220824 +0100
+++ b/kernel/hook/setuid_hook.c	2026-04-09 13:31:53.843570637 +0100
@@ -11,6 +11,9 @@
 #include <linux/types.h>
 #include <linux/uaccess.h>
 #include <linux/uidgid.h>
+#ifdef CONFIG_KSU_SUSFS
+#include <linux/susfs_def.h>
+#endif // #ifdef CONFIG_KSU_SUSFS
 
 #include "policy/allowlist.h"
 #include "hook/setuid_hook.h"
@@ -20,7 +23,27 @@
 #include "supercall/supercall.h"
 #include "hook/tp_marker.h"
 #include "feature/kernel_umount.h"
+#ifdef CONFIG_KSU_SUSFS
+#include "selinux/selinux.h"
+#endif // #ifdef CONFIG_KSU_SUSFS
 
+#ifdef CONFIG_KSU_SUSFS
+static inline bool is_zygote_isolated_service_uid(uid_t uid)
+{
+    uid %= 100000;
+    return (uid >= 99000 && uid < 100000);
+}
+
+static inline bool is_zygote_normal_app_uid(uid_t uid)
+{
+    uid %= 100000;
+    return (uid >= 10000 && uid < 19999);
+}
+
+extern u32 susfs_zygote_sid;
+#endif // #ifdef CONFIG_KSU_SUSFS
+
+#ifndef CONFIG_KSU_SUSFS
 int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)
 {
     // we rely on the fact that zygote always call setresuid(3) with same uids
@@ -55,6 +78,53 @@
 
     return 0;
 }
+#else
+int ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)
+{
+    pr_info("handle_setresuid from %d to %d\n", old_uid, new_uid);
+
+    // Only care about processes spawned by zygote
+    if (!susfs_is_sid_equal(current_cred(), susfs_zygote_sid)) {
+        return 0;
+    }
+
+#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+    if (is_zygote_isolated_service_uid(new_uid)) {
+        goto do_umount;
+    }
+#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
+
+    if (unlikely(is_uid_manager(new_uid))) {
+        spin_lock_irq(&current->sighand->siglock);
+        ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);
+        spin_unlock_irq(&current->sighand->siglock);
+
+        pr_info("install fd for manager: %d\n", new_uid);
+        ksu_install_fd();
+        return 0;
+    }
+
+    if (likely(is_zygote_normal_app_uid(new_uid) && ksu_uid_should_umount(new_uid))) {
+        goto do_umount;
+    }
+
+    if (ksu_is_allow_uid_for_current(new_uid)) {
+        if (current->seccomp.mode == SECCOMP_MODE_FILTER &&
+            current->seccomp.filter) {
+            spin_lock_irq(&current->sighand->siglock);
+            ksu_seccomp_allow_cache(current->seccomp.filter, __NR_reboot);
+            spin_unlock_irq(&current->sighand->siglock);
+        }
+    }
+
+    return 0;
+
+do_umount:
+    ksu_handle_umount(old_uid, new_uid);
+    susfs_set_current_proc_umounted();
+    return 0;
+}
+#endif // #ifndef CONFIG_KSU_SUSFS
 
 void __init ksu_setuid_hook_init(void)
 {
diff -ruN '--exclude=include' clean-kernel/policy/app_profile.c work-kernel/policy/app_profile.c
--- a/kernel/policy/app_profile.c	2026-04-09 11:57:48.451239227 +0100
+++ b/kernel/policy/app_profile.c	2026-04-09 12:52:39.843607339 +0100
@@ -107,8 +107,10 @@
 {
     int ret = 0;
     struct cred *cred;
+#ifndef CONFIG_KSU_SUSFS
     struct task_struct *p = current;
     struct task_struct *t;
+#endif // #ifndef CONFIG_KSU_SUSFS
     struct root_profile profile;
     struct user_struct *new_user;
 
@@ -185,9 +187,11 @@
 
     disable_seccomp();
 
+#ifndef CONFIG_KSU_SUSFS
     for_each_thread (p, t) {
         ksu_set_task_tracepoint_flag(t);
     }
+#endif // #ifndef CONFIG_KSU_SUSFS
 
     setup_mount_ns(profile.namespaces);
     return 0;
diff -ruN '--exclude=include' clean-kernel/runtime/ksud_integration.c work-kernel/runtime/ksud_integration.c
--- a/kernel/runtime/ksud_integration.c	2026-04-09 11:57:48.451373296 +0100
+++ b/kernel/runtime/ksud_integration.c	2026-04-09 14:16:31.248384849 +0100
@@ -143,6 +143,10 @@
     return false;
 }
 
+#ifdef CONFIG_KSU_SUSFS
+extern int ksu_handle_execveat_init(const char *path);
+#endif // #ifdef CONFIG_KSU_SUSFS
+
 void ksu_handle_execveat_ksud(const char *path, struct user_arg_ptr *argv)
 {
     static const char app_process[] = "/system/bin/app_process";
@@ -173,6 +177,10 @@
             ksu_stop_ksud_execve_hook();
         }
     }
+
+#ifdef CONFIG_KSU_SUSFS
+    (void)ksu_handle_execveat_init(path);
+#endif // #ifdef CONFIG_KSU_SUSFS
 }
 
 static ssize_t (*orig_read)(struct file *, char __user *, size_t, loff_t *);
@@ -316,6 +324,7 @@
     file->f_op = &fops_proxy;
 }
 
+#ifndef CONFIG_KSU_SUSFS
 static void ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr)
 {
     struct file *file = fget(fd);
@@ -325,6 +334,37 @@
     ksu_install_rc_hook(file);
     fput(file);
 }
+#else
+bool ksu_init_rc_hook __read_mostly = true;
+bool ksu_input_hook __read_mostly = false;
+bool ksu_execveat_hook __read_mostly = true;
+
+__attribute__((cold)) void ksu_handle_sys_read(unsigned int fd)
+{
+    struct file *file = fget(fd);
+    if (!file) {
+        return;
+    }
+    ksu_install_rc_hook(file);
+    fput(file);
+}
+
+void ksu_handle_vfs_fstat(int fd, loff_t *kstat_size_ptr)
+{
+    loff_t new_size = *kstat_size_ptr + ksu_rc_len;
+    struct file *file = fget(fd);
+
+    if (!file)
+        return;
+
+    if (is_init_rc(file)) {
+        pr_info("stat init.rc");
+        pr_info("adding ksu_rc_len: %lld -> %lld", *kstat_size_ptr, new_size);
+        *kstat_size_ptr = new_size;
+    }
+    fput(file);
+}
+#endif // #ifndef CONFIG_KSU_SUSFS
 
 static unsigned int volumedown_pressed_count = 0;
 
@@ -402,6 +442,7 @@
     ksu_handle_execveat_ksud(path, &argv);
 }
 
+#ifndef CONFIG_KSU_SUSFS
 static long (*orig_sys_read)(const struct pt_regs *regs);
 static long ksu_sys_read(const struct pt_regs *regs)
 {
@@ -450,6 +491,7 @@
 
     return ret;
 }
+#endif // #ifndef CONFIG_KSU_SUSFS
 
 static int input_handle_event_handler_pre(struct kprobe *p, struct pt_regs *regs)
 {
@@ -471,9 +513,14 @@
 
 static void stop_init_rc_hook()
 {
+#ifndef CONFIG_KSU_SUSFS
     ksu_syscall_table_unhook(__NR_read);
     ksu_syscall_table_unhook(__NR_fstat);
     pr_info("unregister init_rc syscall hook\n");
+#else
+    ksu_init_rc_hook = false;
+    pr_info("stop init_rc_hook\n");
+#endif // #ifndef CONFIG_KSU_SUSFS
 }
 
 void ksu_stop_input_hook_runtime(void)
@@ -492,8 +539,10 @@
 {
     int ret;
 
+#ifndef CONFIG_KSU_SUSFS
     ksu_syscall_table_hook(__NR_read, ksu_sys_read, &orig_sys_read);
     ksu_syscall_table_hook(__NR_fstat, ksu_sys_fstat, &orig_sys_fstat);
+#endif // #ifndef CONFIG_KSU_SUSFS
 
     ret = register_kprobe(&input_event_kp);
     pr_info("ksud: input_event_kp: %d\n", ret);
diff -ruN '--exclude=include' clean-kernel/selinux/rules.c work-kernel/selinux/rules.c
--- a/kernel/selinux/rules.c	2026-04-09 11:57:48.451373296 +0100
+++ b/kernel/selinux/rules.c	2026-04-09 12:50:26.207778088 +0100
@@ -119,6 +119,13 @@
     ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "getpgid");
     ksu_allow(db, "system_server", KERNEL_SU_DOMAIN, "process", "sigkill");
 
+#ifdef CONFIG_KSU_SUSFS
+    susfs_set_priv_app_sid();
+    susfs_set_init_sid();
+    susfs_set_ksu_sid();
+    susfs_set_zygote_sid();
+#endif // #ifdef CONFIG_KSU_SUSFS
+
     rcu_assign_pointer(selinux_state.policy, pol);
     synchronize_rcu();
     ksu_destroy_sepolicy(old_pol);
diff -ruN '--exclude=include' clean-kernel/selinux/selinux.c work-kernel/selinux/selinux.c
--- a/kernel/selinux/selinux.c	2026-04-09 11:57:48.451550590 +0100
+++ b/kernel/selinux/selinux.c	2026-04-09 12:49:42.567232921 +0100
@@ -207,3 +207,99 @@
 {
     return is_sid_match(cred, cached_init_sid, INIT_CONTEXT);
 }
+
+#ifdef CONFIG_KSU_SUSFS
+#define KERNEL_INIT_DOMAIN "u:r:init:s0"
+#define KERNEL_ZYGOTE_DOMAIN "u:r:zygote:s0"
+#define KERNEL_PRIV_APP_DOMAIN "u:r:priv_app:s0:c512,c768"
+
+u32 susfs_ksu_sid = 0;
+u32 susfs_init_sid = 0;
+u32 susfs_zygote_sid = 0;
+u32 susfs_priv_app_sid = 0;
+
+static inline void susfs_set_sid(const char *secctx_name, u32 *out_sid)
+{
+    int err;
+
+    if (!secctx_name || !out_sid) {
+        pr_err("secctx_name || out_sid is NULL\n");
+        return;
+    }
+
+    err = security_secctx_to_secid(secctx_name, strlen(secctx_name),
+                       out_sid);
+    if (err) {
+        pr_err("failed setting sid for '%s', err: %d\n", secctx_name, err);
+        return;
+    }
+    pr_info("sid '%u' is set for secctx_name '%s'\n", *out_sid, secctx_name);
+}
+
+bool susfs_is_sid_equal(const struct cred *cred, u32 sid2) {
+#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 18, 0)
+    const struct task_security_struct *tsec = selinux_cred(cred);
+#else
+    const struct cred_security_struct *tsec = selinux_cred(cred);
+#endif
+
+    if (!tsec) {
+        return false;
+    }
+    return tsec->sid == sid2;
+}
+
+u32 susfs_get_sid_from_name(const char *secctx_name)
+{
+    u32 out_sid = 0;
+    int err;
+
+    if (!secctx_name) {
+        pr_err("secctx_name is NULL\n");
+        return 0;
+    }
+    err = security_secctx_to_secid(secctx_name, strlen(secctx_name),
+                       &out_sid);
+    if (err) {
+        pr_err("failed getting sid from secctx_name: %s, err: %d\n", secctx_name, err);
+        return 0;
+    }
+    return out_sid;
+}
+
+u32 susfs_get_current_sid(void) {
+    return current_sid();
+}
+
+void susfs_set_zygote_sid(void)
+{
+    susfs_set_sid(KERNEL_ZYGOTE_DOMAIN, &susfs_zygote_sid);
+}
+
+bool susfs_is_current_zygote_domain(void) {
+    return unlikely(current_sid() == susfs_zygote_sid);
+}
+
+void susf