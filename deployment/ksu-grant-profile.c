#define _GNU_SOURCE

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KSU_GET_MANAGER_APPID 0x80004b0aUL
#define KSU_SET_APP_PROFILE 0x40004b0cUL
#define KSU_APP_PROFILE_VERSION 4
#define KSU_MAX_PACKAGE_NAME 256

struct root_profile {
    int32_t uid;
    int32_t gid;
    uint32_t groups_count;
    int32_t groups[32];
    struct {
        uint64_t effective;
        uint64_t permitted;
        uint64_t inheritable;
    } capabilities;
    char selinux_domain[64];
    int32_t namespaces;
    uint64_t flags;
};

struct non_root_profile {
    bool umount_modules;
};

struct app_profile {
    uint32_t version;
    char key[KSU_MAX_PACKAGE_NAME];
    int32_t curr_uid;
    bool allow_su;
    union {
        struct {
            bool use_default;
            char template_name[KSU_MAX_PACKAGE_NAME];
            struct root_profile profile;
        } rp_config;
        struct {
            bool use_default;
            struct non_root_profile profile;
        } nrp_config;
    };
};

_Static_assert(sizeof(struct app_profile) == 784, "KernelSU v3.3.0 ABI mismatch");

static int fail(const char *message) {
    perror(message);
    return 1;
}

int main(int argc, char **argv) {
    char *end = NULL;
    long target_uid;
    int driver_fd = -1;
    struct {
        uint32_t appid;
    } manager = {0};
    struct app_profile profile = {0};

    if (argc != 3) {
        fprintf(stderr, "usage: ksu-grant-profile UID PACKAGE\n");
        return 64;
    }

    target_uid = strtol(argv[1], &end, 10);
    if (argv[1][0] == '\0' || *end != '\0' || target_uid < 2000
            || target_uid > INT32_MAX || strlen(argv[2]) >= KSU_MAX_PACKAGE_NAME) {
        fprintf(stderr, "invalid UID or package name\n");
        return 64;
    }

    (void)syscall(__NR_reboot, 0xDEADBEEF, 0xCAFEBABE, 0, &driver_fd);
    if (driver_fd < 0) {
        return fail("KernelSU driver fd");
    }
    if (ioctl(driver_fd, KSU_GET_MANAGER_APPID, &manager) < 0
            || manager.appid == UINT32_MAX) {
        return fail("KernelSU manager appid");
    }
    if (setresuid(manager.appid, manager.appid, manager.appid) < 0) {
        return fail("setresuid manager");
    }

    profile.version = KSU_APP_PROFILE_VERSION;
    strcpy(profile.key, argv[2]);
    profile.curr_uid = (int32_t)target_uid;
    profile.allow_su = true;
    profile.rp_config.use_default = true;
    profile.rp_config.profile.groups_count = 1;
    profile.rp_config.profile.groups[0] = 0;
    strcpy(profile.rp_config.profile.selinux_domain, "u:r:ksu:s0");
    profile.rp_config.profile.flags = 1;

    if (ioctl(driver_fd, KSU_SET_APP_PROFILE, &profile) < 0) {
        return fail("KernelSU set app profile");
    }
    return 0;
}
