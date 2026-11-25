/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __SOPP_COMPAT_H
#define __SOPP_COMPAT_H

#include <linux/fs.h>
#include <linux/types.h>

struct file *sopp_filp_open_compat(const char *path, int flags, umode_t mode);
ssize_t sopp_kernel_read_compat(struct file *fp, void *buf, size_t count,
				loff_t *pos);
ssize_t sopp_kernel_write_compat(struct file *fp, const void *buf, size_t count,
				 loff_t *pos);
long sopp_strncpy_from_user_nofault(char *dst, const void __user *src, long count);

#endif /* __SOPP_COMPAT_H */
