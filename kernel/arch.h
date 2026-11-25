/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Register/symbol shims for the kprobe based entry points.
 * The 4.14 ares kernel exposes bare sys_* symbols (no __arm64_ prefix).
 */
#ifndef __SOPP_ARCH_H
#define __SOPP_ARCH_H

#include <linux/version.h>

#if defined(__aarch64__)

#define __PT_PARM1_REG regs[0]
#define __PT_PARM2_REG regs[1]
#define __PT_PARM3_REG regs[2]
#define __PT_SYSCALL_PARM4_REG regs[3]
#define __PT_CCALL_PARM4_REG regs[3]
#define __PT_PARM5_REG regs[4]

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)
#define SOPP_PRCTL_SYMBOL "__arm64_sys_prctl"
#define SOPP_SETUID_SYMBOL "__arm64_sys_setuid"
#else
#define SOPP_PRCTL_SYMBOL "sys_prctl"
#define SOPP_SETUID_SYMBOL "sys_setuid"
#endif

#elif defined(__x86_64__)

#define __PT_PARM1_REG di
#define __PT_PARM2_REG si
#define __PT_PARM3_REG dx
#define __PT_SYSCALL_PARM4_REG r10
#define __PT_CCALL_PARM4_REG cx
#define __PT_PARM5_REG r8

#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)
#define SOPP_PRCTL_SYMBOL "__x64_sys_prctl"
#define SOPP_SETUID_SYMBOL "__x64_sys_setuid"
#else
#define SOPP_PRCTL_SYMBOL "sys_prctl"
#define SOPP_SETUID_SYMBOL "sys_setuid"
#endif

#else
#error "s0ppSU: unsupported architecture"
#endif

#define PT_REGS_PARM1(x) ((x)->__PT_PARM1_REG)
#define PT_REGS_PARM2(x) ((x)->__PT_PARM2_REG)
#define PT_REGS_PARM3(x) ((x)->__PT_PARM3_REG)
#define PT_REGS_SYSCALL_PARM4(x) ((x)->__PT_SYSCALL_PARM4_REG)
#define PT_REGS_PARM5(x) ((x)->__PT_PARM5_REG)

/*
 * On >=4.16 the kprobe receives a pt_regs of the wrapper and the real syscall
 * arguments live one level deeper. On 4.14 they are already in the kprobe regs.
 */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 16, 0)
#define SOPP_REAL_REGS(regs) ((struct pt_regs *)PT_REGS_PARM1(regs))
#else
#define SOPP_REAL_REGS(regs) (regs)
#endif

#endif /* __SOPP_ARCH_H */
