/*
 * soppctl / su - minimal userspace client for the s0ppSU prctl door.
 *
 * Built with the Android NDK and installed to /data/adb/s0ppSU/bin. When an
 * authorised app executes `su`, the execve kprobe escalates the process before
 * this program's main() runs; `id` then reports uid 0.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/prctl.h>

#define SOPP_SU_OPTION   0x5A0F7001U
#define SOPP_REPLY_MAGIC 0x5A0F7001U

enum {
    CMD_GET_VERSION = 0,
    CMD_MODULE_MOUNTED = 31,
};

static int call(int cmd, void *arg)
{
    int32_t reply = 0;
    prctl(SOPP_SU_OPTION, cmd, arg, NULL, &reply);
    return reply == SOPP_REPLY_MAGIC;
}

static int do_version(void)
{
    int32_t version = -1;
    call(CMD_GET_VERSION, &version);
    printf("s0ppSU version: 0x%08x\n", version);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: soppctl <version|module-mounted>\n");
        return 1;
    }

    if (!strcmp(argv[1], "version")) {
        return do_version();
    } else if (!strcmp(argv[1], "module-mounted")) {
        return call(CMD_MODULE_MOUNTED, NULL) ? 0 : 1;
    }

    fprintf(stderr, "soppctl: unknown command '%s'\n", argv[1]);
    return 1;
}
