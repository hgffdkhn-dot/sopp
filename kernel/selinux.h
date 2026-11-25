/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __SOPP_SELINUX_H
#define __SOPP_SELINUX_H

#include <linux/types.h>

#define SOPP_SU_DOMAIN "u:r:su:s0"

/* Switch the calling task to a SELinux domain by security context string. */
int sopp_transit_to_domain(const char *domain);

/* Called after escape_to_root(); moves the process into the su domain. */
void sopp_apply_selinux_rules(void);

/*
 * Manager interface. arg4 points to a NUL-terminated domain string from
 * userspace; the kernel validates it and applies it to the caller.
 */
int sopp_handle_sepolicy(unsigned long arg3, void __user *arg4);

#endif /* __SOPP_SELINUX_H */
