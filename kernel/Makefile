# SPDX-License-Identifier: GPL-2.0
# s0ppSU kernel module

soppsu-y := main.o
soppsu-y += core.o
soppsu-y += allowlist.o
soppsu-y += compat.o
soppsu-y += selinux.o
soppsu-y += sucompat.o

obj-$(CONFIG_SOPP_SU) += soppsu.o

# SELinux internal headers (task_security_struct) live outside the public tree.
ccflags-y += -I$(srctree)/security/selinux/include -I$(srctree)/security/selinux
ccflags-y += -I$(objtree)/security/selinux

# The manager package identity can be overridden at build time.
ifndef SOPP_MANAGER_PACKAGE
SOPP_MANAGER_PACKAGE := com.sopp.su
endif
ccflags-y += -DSOPP_MANAGER_PACKAGE=\"$(SOPP_MANAGER_PACKAGE)\"

# path_umount() was introduced in 5.9; non-GKI 4.14 kernels lack it.
ifneq ($(shell grep -q "int path_umount" $(srctree)/fs/namespace.c; echo $$?),1)
ccflags-y += -DSOPP_HAS_PATH_UMOUNT
endif

ccflags-y += -Wno-implicit-function-declaration -Wno-int-conversion
ccflags-y += -Wno-declaration-after-statement
