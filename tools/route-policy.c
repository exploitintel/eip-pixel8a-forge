/* route-policy: issue only the two IPv4 policy-rule mutations owned by the
 * Pixel Docker host. The caller proves rule absence/conflict and verifies the
 * resulting rules; this helper only crosses Android's privileged netlink
 * boundary from a reviewed, transient host-network container.
 *
 * usage: route-policy add|delete|describe to-main CIDR 9990
 *        route-policy add|delete|describe from-table CIDR TABLE 9991
 *
 * Exit 0 means the requested operation completed. Exit 2 is invalid input.
 * Exit 3 means add found an existing rule or delete found no matching rule.
 * Other runtime failures return 1.
 */
#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) && !defined(ROUTE_POLICY_DESCRIBE_ONLY)
#include <fcntl.h>
#include <linux/fib_rules.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#endif

enum operation {
    OP_ADD,
    OP_DELETE,
    OP_DESCRIBE
};

enum selector {
    SELECTOR_TO_MAIN,
    SELECTOR_FROM_TABLE
};

struct policy_spec {
    enum operation operation;
    enum selector selector;
    struct in_addr address;
    char cidr[32];
    uint8_t prefix;
    uint32_t table;
    uint32_t priority;
};

static void usage(void)
{
    fputs("usage: route-policy add|delete|describe to-main CIDR 9990\n"
          "       route-policy add|delete|describe from-table CIDR TABLE 9991\n",
          stderr);
}

static int parse_canonical_u32(const char *text, uint32_t minimum,
                               uint32_t maximum, uint32_t *result)
{
    uint64_t value = 0;
    const unsigned char *cursor = (const unsigned char *)text;

    if (*cursor == '\0' || (cursor[0] == '0' && cursor[1] != '\0')) {
        return -1;
    }
    for (; *cursor != '\0'; cursor++) {
        uint32_t digit;

        if (*cursor < '0' || *cursor > '9') {
            return -1;
        }
        digit = (uint32_t)(*cursor - '0');
        if (value > ((uint64_t)maximum - digit) / 10U) {
            return -1;
        }
        value = value * 10U + digit;
    }
    if (value < minimum) {
        return -1;
    }
    *result = (uint32_t)value;
    return 0;
}

static int parse_cidr(const char *text, struct in_addr *address,
                      uint8_t *prefix, char canonical[32])
{
    const char *slash = strchr(text, '/');
    const char *cursor = text;
    uint32_t octets[4];
    uint32_t prefix_value;
    uint32_t host_address = 0;
    uint32_t mask;
    uint32_t end;
    size_t index;

    if (slash == NULL || slash == text || strchr(slash + 1, '/') != NULL ||
        strlen(text) >= 32U) {
        return -1;
    }
    for (index = 0; index < 4U; index++) {
        const char *start = cursor;
        uint32_t value = 0;

        if (cursor >= slash || (*cursor == '0' && cursor + 1 < slash &&
                                cursor[1] >= '0' && cursor[1] <= '9')) {
            return -1;
        }
        while (cursor < slash && *cursor >= '0' && *cursor <= '9') {
            value = value * 10U + (uint32_t)(*cursor - '0');
            if (value > 255U) {
                return -1;
            }
            cursor++;
        }
        if (cursor == start) {
            return -1;
        }
        octets[index] = value;
        if (index < 3U) {
            if (cursor >= slash || *cursor != '.') {
                return -1;
            }
            cursor++;
        } else if (cursor != slash) {
            return -1;
        }
    }
    if (parse_canonical_u32(slash + 1, 12U, 24U, &prefix_value) != 0) {
        return -1;
    }
    for (index = 0; index < 4U; index++) {
        host_address = (host_address << 8U) | octets[index];
    }
    mask = UINT32_MAX << (32U - prefix_value);
    if ((host_address & mask) != host_address) {
        return -1;
    }
    end = host_address | ~mask;
    if (!((host_address >= UINT32_C(0x0a000000) &&
           end <= UINT32_C(0x0affffff)) ||
          (host_address >= UINT32_C(0xac100000) &&
           end <= UINT32_C(0xac1fffff)) ||
          (host_address >= UINT32_C(0xc0a80000) &&
           end <= UINT32_C(0xc0a8ffff)))) {
        return -1;
    }
    {
        int written = snprintf(canonical, 32, "%u.%u.%u.%u/%u",
                               octets[0], octets[1], octets[2], octets[3],
                               prefix_value);
        if (written < 0 || written >= 32) {
            return -1;
        }
    }
    address->s_addr = htonl(host_address);
    *prefix = (uint8_t)prefix_value;
    return 0;
}

static int parse_spec(int argc, char **argv, struct policy_spec *spec)
{
    uint32_t priority;

    memset(spec, 0, sizeof(*spec));
    if (argc < 2) {
        return -1;
    }
    if (strcmp(argv[1], "add") == 0) {
        spec->operation = OP_ADD;
    } else if (strcmp(argv[1], "delete") == 0) {
        spec->operation = OP_DELETE;
    } else if (strcmp(argv[1], "describe") == 0) {
        spec->operation = OP_DESCRIBE;
    } else {
        return -1;
    }
    if (argc == 5 && strcmp(argv[2], "to-main") == 0) {
        spec->selector = SELECTOR_TO_MAIN;
        spec->table = 254U;
        if (parse_cidr(argv[3], &spec->address, &spec->prefix, spec->cidr) != 0 ||
            parse_canonical_u32(argv[4], 1U, UINT32_MAX, &priority) != 0 ||
            priority != 9990U) {
            return -1;
        }
    } else if (argc == 6 && strcmp(argv[2], "from-table") == 0) {
        spec->selector = SELECTOR_FROM_TABLE;
        if (parse_cidr(argv[3], &spec->address, &spec->prefix, spec->cidr) != 0 ||
            parse_canonical_u32(argv[4], 256U, UINT32_MAX, &spec->table) != 0 ||
            parse_canonical_u32(argv[5], 1U, UINT32_MAX, &priority) != 0 ||
            priority != 9991U) {
            return -1;
        }
    } else {
        return -1;
    }
    spec->priority = priority;
    return 0;
}

static const char *operation_name(enum operation operation)
{
    switch (operation) {
    case OP_ADD:
        return "add";
    case OP_DELETE:
        return "delete";
    case OP_DESCRIBE:
        return "describe";
    }
    return "unknown";
}

static void describe(const struct policy_spec *spec)
{
    printf("operation=%s selector=%s cidr=%s table=%u priority=%u\n",
           operation_name(spec->operation),
           spec->selector == SELECTOR_TO_MAIN ? "to-main" : "from-table",
           spec->cidr, spec->table, spec->priority);
}

#if defined(__linux__) && !defined(ROUTE_POLICY_DESCRIBE_ONLY)
struct rule_request {
    struct nlmsghdr header;
    struct fib_rule_hdr rule;
    unsigned char attributes[128];
};

static int append_attribute(struct rule_request *request, uint16_t type,
                            const void *value, size_t length)
{
    size_t offset = NLMSG_ALIGN(request->header.nlmsg_len);
    size_t attribute_length = RTA_LENGTH(length);
    size_t aligned_length = RTA_ALIGN(attribute_length);
    struct rtattr *attribute;

    if (offset > sizeof(*request) || aligned_length > sizeof(*request) - offset) {
        return -1;
    }
    attribute = (struct rtattr *)((unsigned char *)request + offset);
    attribute->rta_type = type;
    attribute->rta_len = (unsigned short)attribute_length;
    memcpy(RTA_DATA(attribute), value, length);
    if (aligned_length > attribute_length) {
        memset((unsigned char *)attribute + attribute_length, 0,
               aligned_length - attribute_length);
    }
    request->header.nlmsg_len = (uint32_t)(offset + aligned_length);
    return 0;
}

static int open_netlink(uint32_t *port_id)
{
    int descriptor;
    int descriptor_flags;
    struct sockaddr_nl local;
    socklen_t local_length = sizeof(local);

    descriptor = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (descriptor < 0) {
        return -1;
    }
    descriptor_flags = fcntl(descriptor, F_GETFD);
    if (descriptor_flags < 0 ||
        fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) < 0) {
        int saved_errno = errno;
        close(descriptor);
        errno = saved_errno;
        return -1;
    }
    memset(&local, 0, sizeof(local));
    local.nl_family = AF_NETLINK;
    if (bind(descriptor, (struct sockaddr *)&local, sizeof(local)) < 0 ||
        getsockname(descriptor, (struct sockaddr *)&local, &local_length) < 0 ||
        local_length != sizeof(local) || local.nl_family != AF_NETLINK) {
        int saved_errno = errno;
        close(descriptor);
        errno = saved_errno;
        return -1;
    }
    *port_id = local.nl_pid;
    return descriptor;
}

static int receive_ack(int descriptor, uint32_t sequence, uint32_t port_id)
{
    unsigned char buffer[4096];

    for (;;) {
        struct sockaddr_nl sender;
        socklen_t sender_length = sizeof(sender);
        ssize_t length;
        struct nlmsghdr *message;
        int remaining;

        memset(&sender, 0, sizeof(sender));
        do {
            length = recvfrom(descriptor, buffer, sizeof(buffer), 0,
                              (struct sockaddr *)&sender, &sender_length);
        } while (length < 0 && errno == EINTR);
        if (length < 0) {
            return -1;
        }
        if (sender_length != sizeof(sender) || sender.nl_family != AF_NETLINK ||
            sender.nl_pid != 0U || length > INT32_MAX) {
            errno = EPROTO;
            return -1;
        }
        remaining = (int)length;
        for (message = (struct nlmsghdr *)buffer; NLMSG_OK(message, remaining);
             message = NLMSG_NEXT(message, remaining)) {
            struct nlmsgerr *error_message;

            if (message->nlmsg_seq != sequence || message->nlmsg_pid != port_id) {
                continue;
            }
            if (message->nlmsg_type != NLMSG_ERROR ||
                message->nlmsg_len < NLMSG_LENGTH(sizeof(*error_message))) {
                errno = EPROTO;
                return -1;
            }
            error_message = (struct nlmsgerr *)NLMSG_DATA(message);
            if (error_message->error == 0) {
                return 0;
            }
            errno = -error_message->error;
            return -1;
        }
        if (remaining != 0) {
            errno = EPROTO;
            return -1;
        }
    }
}

static int execute_policy(const struct policy_spec *spec)
{
    struct rule_request request;
    struct sockaddr_nl kernel;
    uint32_t port_id;
    uint32_t sequence;
    int descriptor;
    ssize_t sent;
    int result;
    int saved_errno;

    memset(&request, 0, sizeof(request));
    descriptor = open_netlink(&port_id);
    if (descriptor < 0) {
        fprintf(stderr, "route-policy: cannot open route netlink: %s\n",
                strerror(errno));
        return 1;
    }
    sequence = (uint32_t)getpid();
    request.header.nlmsg_len = NLMSG_LENGTH(sizeof(request.rule));
    request.header.nlmsg_type = spec->operation == OP_ADD ? RTM_NEWRULE : RTM_DELRULE;
    request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    if (spec->operation == OP_ADD) {
        request.header.nlmsg_flags |= NLM_F_CREATE | NLM_F_EXCL;
    }
    request.header.nlmsg_seq = sequence;
    request.header.nlmsg_pid = port_id;
    request.rule.family = AF_INET;
    request.rule.action = FR_ACT_TO_TBL;
    request.rule.table = spec->table <= UINT8_MAX ? (uint8_t)spec->table : RT_TABLE_UNSPEC;
    if (spec->selector == SELECTOR_TO_MAIN) {
        request.rule.dst_len = spec->prefix;
    } else {
        request.rule.src_len = spec->prefix;
    }
    if (append_attribute(&request, FRA_PRIORITY, &spec->priority,
                         sizeof(spec->priority)) != 0 ||
        append_attribute(&request, FRA_TABLE, &spec->table,
                         sizeof(spec->table)) != 0 ||
        append_attribute(&request,
                         spec->selector == SELECTOR_TO_MAIN ? FRA_DST : FRA_SRC,
                         &spec->address.s_addr, sizeof(spec->address.s_addr)) != 0) {
        close(descriptor);
        fputs("route-policy: internal request exceeds its fixed buffer\n", stderr);
        return 1;
    }
    memset(&kernel, 0, sizeof(kernel));
    kernel.nl_family = AF_NETLINK;
    do {
        sent = sendto(descriptor, &request, request.header.nlmsg_len, 0,
                      (struct sockaddr *)&kernel, sizeof(kernel));
    } while (sent < 0 && errno == EINTR);
    if (sent < 0 || (size_t)sent != request.header.nlmsg_len) {
        saved_errno = sent < 0 ? errno : EIO;
        close(descriptor);
        fprintf(stderr, "route-policy: cannot send exact policy rule: %s\n",
                strerror(saved_errno));
        return 1;
    }
    result = receive_ack(descriptor, sequence, port_id);
    saved_errno = errno;
    close(descriptor);
    if (result == 0) {
        return 0;
    }
    if ((spec->operation == OP_ADD && saved_errno == EEXIST) ||
        (spec->operation == OP_DELETE && saved_errno == ENOENT)) {
        fprintf(stderr, "route-policy: exact rule is %s\n",
                spec->operation == OP_ADD ? "already present" : "absent");
        return 3;
    }
    fprintf(stderr, "route-policy: kernel rejected exact policy rule: %s\n",
            strerror(saved_errno));
    return 1;
}
#else
static int execute_policy(const struct policy_spec *spec)
{
    (void)spec;
    fputs("route-policy: policy mutation requires the Linux route-netlink build\n",
          stderr);
    return 1;
}
#endif

int main(int argc, char **argv)
{
    struct policy_spec spec;

    if (parse_spec(argc, argv, &spec) != 0) {
        usage();
        return 2;
    }
    if (spec.operation == OP_DESCRIBE) {
        describe(&spec);
        return 0;
    }
    return execute_policy(&spec);
}
