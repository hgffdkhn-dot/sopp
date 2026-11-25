/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Thin wrappers around kernel file I/O. 4.14 still has vfs_read/vfs_write with
 * the classic signature, so no set_fs gymnastics are required here.
 */
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/types.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#include "compat.h"

struct file *sopp_filp_open_compat(const char *path, int flags, umode_t mode)
{
	return filp_open(path, flags, mode);
}

ssize_t sopp_kernel_read_compat(struct file *fp, void *buf, size_t count,
				loff_t *pos)
{
	return vfs_read(fp, buf, count, pos);
}

ssize_t sopp_kernel_write_compat(struct file *fp, const void *buf, size_t count,
				 loff_t *pos)
{
	return vfs_write(fp, buf, count, pos);
}

long sopp_strncpy_from_user_nofault(char *dst, const void __user *src, long count)
{
	/* strncpy_from_user already validates the range. */
	return strncpy_from_user(dst, src, count);
}
