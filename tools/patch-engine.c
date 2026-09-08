/* patch-engine: apply verified, fixed-length substitutions to one binary.
 *
 * This is the archive-independent engine patch primitive intended for a
 * future static AArch64 build. Archive acquisition, archive verification, and
 * extraction remain the caller's responsibility. Every invocation pins the
 * complete extracted input and output identities and the exact count of each
 * ordered substitution.
 *
 * usage: patch-engine INPUT OUTPUT --expect-input-size DECIMAL
 *            --expect-input-sha256 HEX --expect-output-sha256 HEX
 *            [--replace FROM TO COUNT]...
 *
 * OUTPUT must not exist. Exit status is 0 on success, 1 on a refused input or
 * I/O failure, and 2 for invalid usage.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

typedef struct {
    uint32_t h[8];
    uint64_t length;
    unsigned char block[64];
    size_t fill;
} sha256_t;

typedef struct {
    const char *from;
    const char *to;
    size_t length;
    uint64_t expected_count;
} rule_t;

static const uint32_t SHA256_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define ROTR32(value, count) (((value) >> (count)) | ((value) << (32 - (count))))

static void sha256_init(sha256_t *state) {
    static const uint32_t initial[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    memcpy(state->h, initial, sizeof initial);
    state->length = 0;
    state->fill = 0;
}

static void sha256_block(sha256_t *state, const unsigned char *data) {
    uint32_t words[64], a, b, c, d, e, f, g, h;
    size_t index;
    for (index = 0; index < 16; index++) {
        words[index] = ((uint32_t)data[4 * index] << 24) |
                       ((uint32_t)data[4 * index + 1] << 16) |
                       ((uint32_t)data[4 * index + 2] << 8) |
                       (uint32_t)data[4 * index + 3];
    }
    for (index = 16; index < 64; index++) {
        uint32_t s0 = ROTR32(words[index - 15], 7) ^ ROTR32(words[index - 15], 18) ^
                      (words[index - 15] >> 3);
        uint32_t s1 = ROTR32(words[index - 2], 17) ^ ROTR32(words[index - 2], 19) ^
                      (words[index - 2] >> 10);
        words[index] = words[index - 16] + s0 + words[index - 7] + s1;
    }
    a = state->h[0]; b = state->h[1]; c = state->h[2]; d = state->h[3];
    e = state->h[4]; f = state->h[5]; g = state->h[6]; h = state->h[7];
    for (index = 0; index < 64; index++) {
        uint32_t sum1 = ROTR32(e, 6) ^ ROTR32(e, 11) ^ ROTR32(e, 25);
        uint32_t choose = (e & f) ^ (~e & g);
        uint32_t first = h + sum1 + choose + SHA256_K[index] + words[index];
        uint32_t sum0 = ROTR32(a, 2) ^ ROTR32(a, 13) ^ ROTR32(a, 22);
        uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        uint32_t second = sum0 + majority;
        h = g; g = f; f = e; e = d + first;
        d = c; c = b; b = a; a = first + second;
    }
    state->h[0] += a; state->h[1] += b; state->h[2] += c; state->h[3] += d;
    state->h[4] += e; state->h[5] += f; state->h[6] += g; state->h[7] += h;
}

static void sha256_update(sha256_t *state, const unsigned char *data, size_t length) {
    state->length += length;
    while (length > 0) {
        size_t take = 64 - state->fill;
        if (take > length) take = length;
        memcpy(state->block + state->fill, data, take);
        state->fill += take;
        data += take;
        length -= take;
        if (state->fill == 64) {
            sha256_block(state, state->block);
            state->fill = 0;
        }
    }
}

static void sha256_final(sha256_t *state, char output[65]) {
    static const char hex[] = "0123456789abcdef";
    unsigned char padding[72];
    uint64_t bits = state->length * 8;
    size_t padding_length = state->fill < 56 ? 56 - state->fill : 120 - state->fill;
    size_t index;
    memset(padding, 0, sizeof padding);
    padding[0] = 0x80;
    sha256_update(state, padding, padding_length);
    for (index = 0; index < 8; index++)
        padding[index] = (unsigned char)(bits >> (56 - 8 * index));
    sha256_update(state, padding, 8);
    for (index = 0; index < 8; index++) {
        size_t byte_index;
        for (byte_index = 0; byte_index < 4; byte_index++) {
            unsigned char byte = (unsigned char)(state->h[index] >> (24 - 8 * byte_index));
            output[8 * index + 2 * byte_index] = hex[byte >> 4];
            output[8 * index + 2 * byte_index + 1] = hex[byte & 15];
        }
    }
    output[64] = '\0';
}

static void sha256_hex(const unsigned char *data, size_t length, char output[65]) {
    sha256_t state;
    sha256_init(&state);
    sha256_update(&state, data, length);
    sha256_final(&state, output);
}

static int fail(const char *message) {
    fprintf(stderr, "patch-engine: %s\n", message);
    return 1;
}

static int fail_errno(const char *message) {
    fprintf(stderr, "patch-engine: %s: %s\n", message, strerror(errno));
    return 1;
}

static int usage(void) {
    fprintf(stderr,
            "usage: patch-engine INPUT OUTPUT --expect-input-size DECIMAL "
            "--expect-input-sha256 HEX --expect-output-sha256 HEX "
            "[--replace FROM TO COUNT]...\n");
    return 2;
}

static int parse_decimal(const char *text, uint64_t *value) {
    uint64_t result = 0;
    size_t index;
    if (text == NULL || text[0] == '\0') return 0;
    for (index = 0; text[index] != '\0'; index++) {
        unsigned digit;
        if (text[index] < '0' || text[index] > '9') return 0;
        digit = (unsigned)(text[index] - '0');
        if (result > (UINT64_MAX - digit) / 10) return 0;
        result = result * 10 + digit;
    }
    *value = result;
    return 1;
}

static int valid_sha256(const char *text) {
    size_t index;
    if (text == NULL || strlen(text) != 64) return 0;
    for (index = 0; index < 64; index++) {
        if (!((text[index] >= '0' && text[index] <= '9') ||
              (text[index] >= 'a' && text[index] <= 'f'))) return 0;
    }
    return 1;
}

static int ascii_text(const char *text) {
    const unsigned char *byte = (const unsigned char *)text;
    if (*byte == '\0') return 0;
    for (; *byte != '\0'; byte++)
        if (*byte > 0x7f) return 0;
    return 1;
}

static int read_all(int fd, unsigned char *data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t got = read(fd, data + offset, length - offset);
        if (got < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (got == 0) { errno = EIO; return -1; }
        offset += (size_t)got;
    }
    return 0;
}

static int write_all(int fd, const unsigned char *data, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t wrote = write(fd, data + offset, length - offset);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (wrote == 0) { errno = EIO; return -1; }
        offset += (size_t)wrote;
    }
    return 0;
}

static int sha256_fd_exact(int fd, size_t length, char output[65]) {
    unsigned char buffer[64 * 1024];
    size_t remaining = length;
    sha256_t state;
    sha256_init(&state);
    while (remaining > 0) {
        size_t wanted = remaining < sizeof buffer ? remaining : sizeof buffer;
        ssize_t got = read(fd, buffer, wanted);
        if (got < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (got == 0) { errno = EIO; return -1; }
        sha256_update(&state, buffer, (size_t)got);
        remaining -= (size_t)got;
    }
    for (;;) {
        ssize_t got = read(fd, buffer, 1);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) return -1;
        if (got != 0) { errno = EOVERFLOW; return -1; }
        break;
    }
    sha256_final(&state, output);
    return 0;
}

static int load_input(const char *path, uint64_t expected_size,
                      unsigned char **data_out, size_t *length_out) {
    struct stat before, opened, after;
    unsigned char *data;
    int fd;
    if (lstat(path, &before) != 0) return fail_errno("inspect input");
    if (!S_ISREG(before.st_mode)) return fail("input is not a regular file");
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return fail_errno("open input");
    if (fstat(fd, &opened) != 0) { close(fd); return fail_errno("inspect opened input"); }
    if (!S_ISREG(opened.st_mode) || opened.st_dev != before.st_dev || opened.st_ino != before.st_ino) {
        close(fd);
        return fail("input changed while opening");
    }
    if (opened.st_size < 0 || (uint64_t)opened.st_size != expected_size) {
        fprintf(stderr, "patch-engine: input size mismatch: got %lld, expected %llu\n",
                (long long)opened.st_size, (unsigned long long)expected_size);
        close(fd);
        return 1;
    }
    if (expected_size == 0 || expected_size > SIZE_MAX) {
        close(fd);
        return fail("input size is unsupported");
    }
    data = malloc((size_t)expected_size);
    if (data == NULL) { close(fd); return fail("out of memory"); }
    if (read_all(fd, data, (size_t)expected_size) != 0) {
        free(data);
        close(fd);
        return fail_errno("read input");
    }
    if (fstat(fd, &after) != 0) {
        free(data);
        close(fd);
        return fail_errno("reinspect input");
    }
    if (after.st_dev != opened.st_dev || after.st_ino != opened.st_ino ||
        after.st_size != opened.st_size || after.st_mtime != opened.st_mtime) {
        free(data);
        close(fd);
        return fail("input changed while reading");
    }
    if (close(fd) != 0) { free(data); return fail_errno("close input"); }
    *data_out = data;
    *length_out = (size_t)expected_size;
    return 0;
}

static uint64_t apply_rule(unsigned char *data, size_t data_length, const rule_t *rule) {
    uint64_t count = 0;
    size_t offset = 0;
    if (rule->length > data_length) return 0;
    while (offset <= data_length - rule->length) {
        if (memcmp(data + offset, rule->from, rule->length) == 0) {
            memcpy(data + offset, rule->to, rule->length);
            count++;
            offset += rule->length;
        } else {
            offset++;
        }
    }
    return count;
}

static int publish_output(const char *path, const unsigned char *data, size_t length,
                          const char expected_hash[65]) {
    struct stat existing;
    char *temporary;
    char actual_hash[65];
    size_t template_length;
    int fd = -1;
    int result = 1;
    if (lstat(path, &existing) == 0) return fail("output exists; refusing to overwrite");
    if (errno != ENOENT) return fail_errno("inspect output");
    if (strlen(path) > SIZE_MAX - sizeof ".tmp.XXXXXX") return fail("output path is too long");
    template_length = strlen(path) + sizeof ".tmp.XXXXXX";
    temporary = malloc(template_length);
    if (temporary == NULL) return fail("out of memory");
    snprintf(temporary, template_length, "%s.tmp.XXXXXX", path);
    fd = mkstemp(temporary);
    if (fd < 0) { free(temporary); return fail_errno("create temporary output"); }
    if (write_all(fd, data, length) != 0) {
        fail_errno("write temporary output");
        goto cleanup;
    }
    if (fsync(fd) != 0) { fail_errno("sync temporary output"); goto cleanup; }
    if (lseek(fd, 0, SEEK_SET) < 0) { fail_errno("rewind temporary output"); goto cleanup; }
    if (sha256_fd_exact(fd, length, actual_hash) != 0) {
        fail_errno("read back temporary output");
        goto cleanup;
    }
    if (strcmp(actual_hash, expected_hash) != 0) {
        fprintf(stderr, "patch-engine: written output sha256 mismatch: got %s, expected %s\n",
                actual_hash, expected_hash);
        goto cleanup;
    }
    if (fchmod(fd, 0755) != 0) { fail_errno("set output mode"); goto cleanup; }
    if (fsync(fd) != 0) { fail_errno("sync output mode"); goto cleanup; }
    if (close(fd) != 0) { fd = -1; fail_errno("close temporary output"); goto cleanup; }
    fd = -1;
    if (link(temporary, path) != 0) {
        if (errno == EEXIST) fail("output exists; refusing to overwrite");
        else fail_errno("publish output");
        goto cleanup;
    }
    result = 0;
    if (unlink(temporary) != 0) {
        fprintf(stderr,
                "patch-engine: warning: output is valid but temporary link remains: %s: %s\n",
                temporary, strerror(errno));
    }

cleanup:
    if (fd >= 0) close(fd);
    if (result != 0) unlink(temporary);
    free(temporary);
    return result;
}

int main(int argc, char **argv) {
    const char *input_path, *output_path;
    const char *expected_input_hash = NULL, *expected_output_hash = NULL;
    uint64_t expected_size = 0;
    int have_size = 0;
    rule_t *rules = NULL;
    size_t rule_count = 0, index, data_length = 0;
    unsigned char *data = NULL;
    char actual_hash[65];
    int result = 1;

    if (argc < 3) return usage();
    input_path = argv[1];
    output_path = argv[2];
    for (index = 3; index < (size_t)argc;) {
        if (strcmp(argv[index], "--expect-input-size") == 0 && index + 1 < (size_t)argc) {
            if (have_size || !parse_decimal(argv[index + 1], &expected_size) || expected_size == 0)
                goto bad_usage;
            have_size = 1;
            index += 2;
        } else if (strcmp(argv[index], "--expect-input-sha256") == 0 && index + 1 < (size_t)argc) {
            if (expected_input_hash != NULL || !valid_sha256(argv[index + 1])) goto bad_usage;
            expected_input_hash = argv[index + 1];
            index += 2;
        } else if (strcmp(argv[index], "--expect-output-sha256") == 0 && index + 1 < (size_t)argc) {
            if (expected_output_hash != NULL || !valid_sha256(argv[index + 1])) goto bad_usage;
            expected_output_hash = argv[index + 1];
            index += 2;
        } else if (strcmp(argv[index], "--replace") == 0 && index + 3 < (size_t)argc) {
            rule_t *grown;
            uint64_t count;
            size_t previous;
            if (!ascii_text(argv[index + 1]) || !ascii_text(argv[index + 2]) ||
                strlen(argv[index + 1]) != strlen(argv[index + 2]) ||
                !parse_decimal(argv[index + 3], &count)) {
                fprintf(stderr, "patch-engine: replacement rules must be nonempty ASCII, same-length strings with a decimal count\n");
                goto refusal;
            }
            for (previous = 0; previous < rule_count; previous++) {
                if (strcmp(rules[previous].from, argv[index + 1]) == 0) {
                    fprintf(stderr, "patch-engine: duplicate replacement source: %s\n", argv[index + 1]);
                    goto refusal;
                }
            }
            if (rule_count == SIZE_MAX / sizeof *rules) { fail("too many rules"); goto refusal; }
            grown = realloc(rules, (rule_count + 1) * sizeof *rules);
            if (grown == NULL) { fail("out of memory"); goto refusal; }
            rules = grown;
            rules[rule_count].from = argv[index + 1];
            rules[rule_count].to = argv[index + 2];
            rules[rule_count].length = strlen(argv[index + 1]);
            rules[rule_count].expected_count = count;
            rule_count++;
            index += 4;
        } else {
            goto bad_usage;
        }
    }
    if (!have_size || expected_input_hash == NULL || expected_output_hash == NULL) goto bad_usage;
    if (load_input(input_path, expected_size, &data, &data_length) != 0) goto refusal;
    sha256_hex(data, data_length, actual_hash);
    if (strcmp(actual_hash, expected_input_hash) != 0) {
        fprintf(stderr, "patch-engine: input sha256 mismatch: got %s, expected %s\n",
                actual_hash, expected_input_hash);
        goto refusal;
    }
    for (index = 0; index < rule_count; index++) {
        uint64_t actual_count = apply_rule(data, data_length, &rules[index]);
        if (actual_count != rules[index].expected_count) {
            fprintf(stderr,
                    "patch-engine: replacement count mismatch for %s: got %llu, expected %llu\n",
                    rules[index].from, (unsigned long long)actual_count,
                    (unsigned long long)rules[index].expected_count);
            goto refusal;
        }
    }
    sha256_hex(data, data_length, actual_hash);
    if (strcmp(actual_hash, expected_output_hash) != 0) {
        fprintf(stderr, "patch-engine: output sha256 mismatch: got %s, expected %s\n",
                actual_hash, expected_output_hash);
        goto refusal;
    }
    if (publish_output(output_path, data, data_length, expected_output_hash) != 0) goto refusal;
    printf("%s  %s\n", expected_output_hash, output_path);
    result = 0;
    goto cleanup;

bad_usage:
    result = usage();
    goto cleanup;
refusal:
    result = 1;
cleanup:
    free(data);
    free(rules);
    return result;
}
