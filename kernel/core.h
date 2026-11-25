/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __SOPP_CORE_H
#define __SOPP_CORE_H

#include <linux/types.h>

void sopp_core_init(void);
void sopp_core_exit(void);

int sopp_handle_prctl(int option, unsigned long arg2, unsigned long arg3,
		      unsigned long arg4, unsigned long arg5);
int sopp_handle_setuid(struct cred *new, const struct cred *old);
int sopp_handle_rename(struct dentry *old_dentry, struct dentry *new_dentry);
int sopp_handle_input_event(unsigned int type, unsigned int code, int value);

void sopp_mark_module_mounted(void);
bool sopp_is_safe_mode(void);
bool sopp_is_module_mounted(void);

extern int sopp_handle_sepolicy(unsigned long arg3, void __user *arg4);
extern void sopp_apply_selinux_rules(void);
extern void sopp_on_post_fs_data(void);

#endif /* __SOPP_CORE_H */
