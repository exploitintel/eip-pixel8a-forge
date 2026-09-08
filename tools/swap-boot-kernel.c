/* swap-boot-kernel: replace only the kernel inside an Android boot image or
 * boot partition, byte for byte, with the same procedure as
 * swap-boot-kernel.py (see docs/BOOT-SWAP.md).
 *
 * usage: swap-boot-kernel TARGET IMAGE_LZ4 --expect-target-size DECIMAL
 *            --expect-current-sha256 HEX
 *            --expect-current-kernel-sha256 HEX
 *            --expect-image-sha256 HEX --expect-output-sha256 HEX
 *        swap-boot-kernel --print-kernel-sha256 TARGET
 *
 * TARGET is a regular file or, on Linux, a block device. The caller must
 * exclude every other writer for the complete invocation; same-descriptor
 * revalidation narrows but cannot replace that external lock. The tool refuses
 * unless the complete target and its current kernel match their paired
 * expected identities. An already-installed result requires both the complete
 * output identity and image payload identity. Writes go kernel pages, fsync,
 * header page, fsync, and the entire target is read back with target-appropriate
 * cache handling before success is reported.
 *
 * Exit status: 0 installed or already installed, 1 refusal or pre-write I/O
 * failure, 2 usage error, 3 failure after a write may have begun (recovery is
 * required). Builds with -std=c99 on Linux (static for the phone) and on macOS
 * for the host tests.
 */
#define _GNU_SOURCE 1
#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef __linux__
#include <linux/fs.h>
#include <sys/ioctl.h>
#endif

#define PAGE 4096u
#define HEADER_VERSION 4u
#define HEADER_SIZE 1584u
static const unsigned char MAGIC[8] = {'A', 'N', 'D', 'R', 'O', 'I', 'D', '!'};

/* ---- SHA-256 (FIPS 180-4), no external dependency ---- */
typedef struct {
    uint32_t h[8];
    uint64_t length;
    unsigned char block[64];
    size_t fill;
} sha256_t;

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_init(sha256_t *s) {
    static const uint32_t init[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    memcpy(s->h, init, sizeof init);
    s->length = 0;
    s->fill = 0;
}

static void sha256_block(sha256_t *s, const unsigned char *p) {
    uint32_t w[64], a, b, c, d, e, f, g, h;
    int i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
               ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = ROTR(w[i - 15], 7) ^ ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROTR(w[i - 2], 17) ^ ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3];
    e = s->h[4]; f = s->h[5]; g = s->h[6]; h = s->h[7];
    for (i = 0; i < 64; i++) {
        uint32_t S1 = ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + K[i] + w[i];
        uint32_t S0 = ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d;
    s->h[4] += e; s->h[5] += f; s->h[6] += g; s->h[7] += h;
}

static void sha256_update(sha256_t *s, const unsigned char *data, size_t len) {
    s->length += len;
    while (len > 0) {
        size_t take = 64 - s->fill;
        if (take > len) take = len;
        memcpy(s->block + s->fill, data, take);
        s->fill += take;
        data += take;
        len -= take;
        if (s->fill == 64) {
            sha256_block(s, s->block);
            s->fill = 0;
        }
    }
}

static void sha256_final(sha256_t *s, char out_hex[65]) {
    static const char *hex = "0123456789abcdef";
    unsigned char pad[72];
    uint64_t bits = s->length * 8;
    size_t padlen = (s->fill < 56) ? (56 - s->fill) : (120 - s->fill);
    int i;
    memset(pad, 0, sizeof pad);
    pad[0] = 0x80;
    sha256_update(s, pad, padlen);
    for (i = 0; i < 8; i++) pad[i] = (unsigned char)(bits >> (56 - 8 * i));
    sha256_update(s, pad, 8);
    for (i = 0; i < 8; i++) {
        int j;
        for (j = 0; j < 4; j++) {
            unsigned char byte = (unsigned char)(s->h[i] >> (24 - 8 * j));
            out_hex[8 * i + 2 * j] = hex[byte >> 4];
            out_hex[8 * i + 2 * j + 1] = hex[byte & 15];
        }
    }
    out_hex[64] = '\0';
}

static void sha256_hex(const unsigned char *data, size_t len, char out_hex[65]) {
    sha256_t s;
    sha256_init(&s);
    sha256_update(&s, data, len);
    sha256_final(&s, out_hex);
}

/* ---- helpers ---- */
static int fail(const char *message) {
    fprintf(stderr, "swap-boot-kernel: %s\n", message);
    return 1;
}

static int fail_errno(const char *what) {
    fprintf(stderr, "swap-boot-kernel: %s: %s\n", what, strerror(errno));
    return 1;
}

static int usage(void) {
    fprintf(stderr,
            "usage: swap-boot-kernel TARGET IMAGE_LZ4 --expect-target-size DECIMAL --expect-current-sha256 HEX --expect-current-kernel-sha256 HEX --expect-image-sha256 HEX --expect-output-sha256 HEX\n"
            "       swap-boot-kernel --print-kernel-sha256 TARGET\n");
    return 2;
}

static int parse_size(const char *s, uint64_t *value_out) {
    uint64_t value = 0;
    size_t i;
    if (s == NULL || *s == '\0') return 0;
    for (i = 0; s[i] != '\0'; i++) {
        unsigned digit;
        if (s[i] < '0' || s[i] > '9') return 0;
        digit = (unsigned)(s[i] - '0');
        if (value > ((uint64_t)INT64_MAX - digit) / 10) return 0;
        value = value * 10 + digit;
    }
    if (value == 0) return 0;
    *value_out = value;
    return 1;
}

static int valid_hex64(const char *s) {
    size_t i;
    if (s == NULL || strlen(s) != 64) return 0;
    for (i = 0; i < 64; i++) {
        char c = s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return 0;
    }
    return 1;
}

static void lower_hex(char *s) {
    for (; *s; s++)
        if (*s >= 'A' && *s <= 'F') *s = (char)(*s - 'A' + 'a');
}

static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void put_le32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)v; p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}

static uint64_t page_align(uint64_t size) {
    return (size + PAGE - 1) / PAGE * PAGE;
}

static int read_exact(int fd, void *buf, size_t len, off_t offset) {
    unsigned char *p = buf;
    while (len > 0) {
        ssize_t n = pread(fd, p, len, offset);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) {
            errno = EIO;
            return -1;
        }
        p += n; len -= (size_t)n; offset += n;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t len, off_t offset) {
    const unsigned char *p = buf;
    while (len > 0) {
        ssize_t n = pwrite(fd, p, len, offset);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) {
            errno = EIO;
            return -1;
        }
        p += n; len -= (size_t)n; offset += n;
    }
    return 0;
}

static void *aligned_alloc_page(size_t len) {
    void *p = NULL;
    if (posix_memalign(&p, PAGE, len) != 0) return NULL;
    memset(p, 0, len);
    return p;
}

static int fd_size(int fd, uint64_t *size_out) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
#ifdef __linux__
    if (S_ISBLK(st.st_mode)) {
        uint64_t bytes;
        if (ioctl(fd, BLKGETSIZE64, &bytes) != 0) return -1;
        *size_out = bytes;
        return 0;
    }
#endif
    if (S_ISREG(st.st_mode)) {
        if (st.st_size < 0) { errno = EIO; return -1; }
        *size_out = (uint64_t)st.st_size;
        return 0;
    }
    errno = ENOTSUP;
    return -1;
}

static int sha256_fd_range(int fd, uint64_t offset, uint64_t length, sha256_t *state) {
    const size_t capacity = 1024u * 1024u;
    unsigned char *buffer = aligned_alloc_page(capacity);
    if (buffer == NULL) { errno = ENOMEM; return -1; }
    while (length > 0) {
        size_t take = length < capacity ? (size_t)length : capacity;
        if (read_exact(fd, buffer, take, (off_t)offset) != 0) {
            free(buffer);
            return -1;
        }
        sha256_update(state, buffer, take);
        offset += take;
        length -= take;
    }
    free(buffer);
    return 0;
}

static int sha256_fd_exact(int fd, uint64_t length, char out_hex[65]) {
    sha256_t state;
    sha256_init(&state);
    if (sha256_fd_range(fd, 0, length, &state) != 0) return -1;
    sha256_final(&state, out_hex);
    return 0;
}

static int sha256_expected_output(int fd, uint64_t target_bytes,
                                  const unsigned char *header,
                                  const unsigned char *region, uint64_t region_size,
                                  char out_hex[65]) {
    uint64_t changed_size = (uint64_t)PAGE + region_size;
    sha256_t state;
    if (target_bytes < changed_size) { errno = EIO; return -1; }
    sha256_init(&state);
    sha256_update(&state, header, PAGE);
    sha256_update(&state, region, (size_t)region_size);
    if (sha256_fd_range(fd, changed_size, target_bytes - changed_size, &state) != 0) return -1;
    sha256_final(&state, out_hex);
    return 0;
}

/* Parse and validate the header page. Returns 0 and sets *kernel_size. */
static int parse_header(const unsigned char *header, uint32_t *kernel_size) {
    uint32_t ramdisk_size, header_size, header_version;
    if (memcmp(header, MAGIC, 8) != 0) return fail("bad boot image magic (expected ANDROID!)");
    *kernel_size = le32(header + 8);
    ramdisk_size = le32(header + 12);
    header_size = le32(header + 20);
    header_version = le32(header + 40);
    if (header_version != HEADER_VERSION) {
        fprintf(stderr, "swap-boot-kernel: unsupported boot header version %u (expected %u)\n",
                (unsigned)header_version, (unsigned)HEADER_VERSION);
        return 1;
    }
    if (header_size != HEADER_SIZE) {
        fprintf(stderr, "swap-boot-kernel: unexpected header size %u (expected %u)\n",
                (unsigned)header_size, (unsigned)HEADER_SIZE);
        return 1;
    }
    if (ramdisk_size != 0) {
        fprintf(stderr, "swap-boot-kernel: image carries a ramdisk of %u bytes; a kernel swap would move it\n",
                (unsigned)ramdisk_size);
        return 1;
    }
    if (*kernel_size == 0) return fail("kernel_size is zero");
    return 0;
}

/* Linux block devices use O_DIRECT, or a fail-closed BLKFLSBUF fallback when
 * direct I/O is unavailable. Regular files deliberately use buffered reads:
 * O_DIRECT can accept the open and then reject a valid unaligned final read.
 * macOS requests F_NOCACHE for regular-file targets. */
static int open_uncached(const char *path) {
    int fd;
#ifdef __linux__
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    {
        struct stat st;
        int direct_fd;
        if (fstat(fd, &st) != 0) {
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
        if (!S_ISBLK(st.st_mode)) return fd;
        direct_fd = open(path, O_RDONLY | O_DIRECT);
        if (direct_fd >= 0) {
            struct stat direct_st;
            int stat_rc = fstat(direct_fd, &direct_st);
            if (stat_rc != 0 || !S_ISBLK(direct_st.st_mode) || direct_st.st_rdev != st.st_rdev) {
                int saved = stat_rc != 0 ? errno : ESTALE;
                close(direct_fd);
                close(fd);
                errno = saved;
                return -1;
            }
            close(fd);
            return direct_fd;
        }
        if (ioctl(fd, BLKFLSBUF, 0) == 0) return fd;
        {
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
    }
#else
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
#ifdef F_NOCACHE
    (void)fcntl(fd, F_NOCACHE, 1);
#endif
    return fd;
#endif
}

static int inspect_kernel_fd(int fd, uint64_t target_bytes, unsigned char *header,
                             uint32_t *size_out, char hash_out[65]) {
    sha256_t state;
    if (target_bytes < PAGE) return fail("target shorter than the boot header page");
    if (read_exact(fd, header, PAGE, 0) != 0) return fail_errno("read header");
    if (parse_header(header, size_out) != 0) return 1;
    if ((uint64_t)*size_out > target_bytes - PAGE)
        return fail("kernel_size runs past the end of the target");
    sha256_init(&state);
    if (sha256_fd_range(fd, PAGE, *size_out, &state) != 0) return fail_errno("read kernel");
    sha256_final(&state, hash_out);
    return 0;
}

static int print_kernel_sha256(const char *path) {
    int fd = open(path, O_RDONLY);
    unsigned char *header;
    uint64_t target_bytes;
    uint32_t size;
    char hex[65];
    int rc;
    if (fd < 0) return fail_errno(path);
    if (fd_size(fd, &target_bytes) != 0) { close(fd); return fail_errno("measure target"); }
    header = aligned_alloc_page(PAGE);
    if (header == NULL) { close(fd); return fail("out of memory"); }
    rc = inspect_kernel_fd(fd, target_bytes, header, &size, hex);
    close(fd);
    free(header);
    if (rc != 0) return rc;
    printf("%u %s\n", (unsigned)size, hex);
    return 0;
}

static int swap(const char *target_path, const char *image_path, uint64_t expect_target_size,
                const char *expect_current_full, const char *expect_current_kernel,
                const char *expect_image, const char *expect_output_full) {
    unsigned char *image = NULL, *region = NULL, *header = NULL, *written = NULL, *check = NULL;
    uint32_t current_size, image_size, rw_kernel_size, readback_size;
    uint64_t image_bytes, target_bytes, region_size;
    char image_hash[65], current_full_hash[65], current_kernel_hash[65];
    char proposed_full_hash[65], rw_full_hash[65], rw_kernel_hash[65];
    char readback_full_hash[65], readback_kernel_hash[65];
    int fd = -1, rc = 1, write_started = 0;

    /* Validate and load the proposed kernel before inspecting the target. */
    {
        int ifd = open(image_path, O_RDONLY);
        if (ifd < 0) return fail_errno(image_path);
        if (fd_size(ifd, &image_bytes) != 0) { close(ifd); return fail_errno("measure image"); }
        if (image_bytes == 0 || image_bytes > 0x7fffffffU) {
            close(ifd);
            return fail("image is empty or too large");
        }
        image_size = (uint32_t)image_bytes;
        image = malloc(image_size);
        if (image == NULL) { close(ifd); return fail("out of memory"); }
        if (read_exact(ifd, image, image_size, 0) != 0) {
            close(ifd);
            free(image);
            return fail_errno("read image");
        }
        close(ifd);
        sha256_hex(image, image_size, image_hash);
        if (strcmp(image_hash, expect_image) != 0) {
            fprintf(stderr, "swap-boot-kernel: image sha256 mismatch: got %s, expected %s\n",
                    image_hash, expect_image);
            free(image);
            return 1;
        }
    }

    header = aligned_alloc_page(PAGE);
    written = aligned_alloc_page(PAGE);
    if (header == NULL || written == NULL) { rc = fail("out of memory"); goto out; }

    /* Establish the complete input identity and its embedded payload before
     * allocating a write buffer or opening the target writable. */
    fd = open(target_path, O_RDONLY);
    if (fd < 0) { rc = fail_errno(target_path); goto out; }
    if (fd_size(fd, &target_bytes) != 0) { rc = fail_errno("measure target"); goto out; }
    if (target_bytes != expect_target_size) {
        fprintf(stderr, "swap-boot-kernel: target size mismatch: got %llu, expected %llu\n",
                (unsigned long long)target_bytes, (unsigned long long)expect_target_size);
        goto out;
    }
    if (sha256_fd_exact(fd, target_bytes, current_full_hash) != 0) {
        rc = fail_errno("hash current target");
        goto out;
    }
    if (inspect_kernel_fd(fd, target_bytes, header, &current_size, current_kernel_hash) != 0)
        goto out;

    /* Neither half of an already-installed identity is sufficient alone.
     * This also prevents a damaged tail from being accepted just because the
     * embedded kernel happens to match the requested image. */
    if (strcmp(current_full_hash, expect_output_full) == 0 ||
        (current_size == image_size && strcmp(current_kernel_hash, expect_image) == 0)) {
        if (strcmp(current_full_hash, expect_output_full) != 0) {
            fprintf(stderr,
                    "swap-boot-kernel: installed payload matches but output full sha256 mismatch: got %s, expected %s\n",
                    current_full_hash, expect_output_full);
            goto out;
        }
        if (current_size != image_size || strcmp(current_kernel_hash, expect_image) != 0) {
            fprintf(stderr,
                    "swap-boot-kernel: expected output full sha256 matches but installed payload does not match image\n");
            goto out;
        }
        printf("already installed %u %s\n", (unsigned)current_size, current_kernel_hash);
        rc = 0;
        goto out;
    }
    if (strcmp(current_full_hash, expect_current_full) != 0) {
        fprintf(stderr, "swap-boot-kernel: current full sha256 mismatch: got %s, expected %s\n",
                current_full_hash, expect_current_full);
        goto out;
    }
    if (strcmp(current_kernel_hash, expect_current_kernel) != 0) {
        fprintf(stderr, "swap-boot-kernel: current kernel sha256 mismatch: got %s, expected %s\n",
                current_kernel_hash, expect_current_kernel);
        goto out;
    }

    region_size = page_align(current_size);
    if ((uint64_t)PAGE + region_size > target_bytes) {
        rc = fail("target shorter than the kernel region");
        goto out;
    }
    if (image_size > region_size) {
        fprintf(stderr,
                "swap-boot-kernel: new kernel (%u bytes) is larger than the stock kernel region (%llu bytes)\n",
                (unsigned)image_size, (unsigned long long)region_size);
        goto out;
    }
    region = aligned_alloc_page((size_t)region_size);
    check = aligned_alloc_page((size_t)region_size);
    if (region == NULL || check == NULL) { rc = fail("out of memory"); goto out; }
    memcpy(region, image, image_size);
    memcpy(written, header, PAGE);
    put_le32(written + 8, image_size);

    /* Prove the exact full output while the target is still read-only. */
    if (sha256_expected_output(fd, target_bytes, written, region, region_size,
                               proposed_full_hash) != 0) {
        rc = fail_errno("hash proposed output");
        goto out;
    }
    if (strcmp(proposed_full_hash, expect_output_full) != 0) {
        fprintf(stderr,
                "swap-boot-kernel: output full sha256 mismatch before write: got %s, expected %s\n",
                proposed_full_hash, expect_output_full);
        goto out;
    }
    close(fd);
    fd = -1;

    /* Revalidate through the descriptor that will perform the write. Inspect
     * the header and payload first, then make the complete-target hash the
     * final I/O immediately before pwrite. The caller's exclusive-writer lock
     * remains mandatory because no userspace sequence eliminates the last
     * instruction-sized race against an external block-device writer. */
    fd = open(target_path, O_RDWR | O_SYNC);
    if (fd < 0) { rc = fail_errno(target_path); goto out; }
    if (fd_size(fd, &target_bytes) != 0) { rc = fail_errno("remeasure target"); goto out; }
    if (target_bytes != expect_target_size) { rc = fail("target size changed before write"); goto out; }
    if (inspect_kernel_fd(fd, target_bytes, check, &rw_kernel_size, rw_kernel_hash) != 0)
        goto out;
    if (memcmp(check, header, PAGE) != 0 || rw_kernel_size != current_size ||
        strcmp(rw_kernel_hash, expect_current_kernel) != 0) {
        rc = fail("target payload changed between inspection and write");
        goto out;
    }
    if (sha256_fd_exact(fd, target_bytes, rw_full_hash) != 0) {
        rc = fail_errno("rehash target before write");
        goto out;
    }
    if (strcmp(rw_full_hash, expect_current_full) != 0) {
        rc = fail("target full sha256 changed between inspection and write");
        goto out;
    }

    /* Write: kernel pages, fsync, header page, fsync. */
    write_started = 1;
    if (write_exact(fd, region, (size_t)region_size, (off_t)PAGE) != 0) {
        rc = fail_errno("write kernel");
        goto out;
    }
    if (fsync(fd) != 0) { rc = fail_errno("fsync after kernel"); goto out; }
    if (write_exact(fd, written, PAGE, 0) != 0) { rc = fail_errno("write header"); goto out; }
    if (fsync(fd) != 0) { rc = fail_errno("fsync after header"); goto out; }
    {
        int close_rc = close(fd);
        int saved = errno;
        fd = -1;
        if (close_rc != 0) {
            errno = saved;
            rc = fail_errno("close target after writes");
            goto out;
        }
    }

    /* Verify the complete output and the embedded payload through an
     * uncached descriptor before reporting success. */
    fd = open_uncached(target_path);
    if (fd < 0) { rc = fail_errno("reopen target for verification"); goto out; }
    if (fd_size(fd, &target_bytes) != 0) { rc = fail_errno("remeasure written target"); goto out; }
    if (target_bytes != expect_target_size) { rc = fail("read back target size mismatch"); goto out; }
    if (sha256_fd_exact(fd, target_bytes, readback_full_hash) != 0) {
        rc = fail_errno("read back complete target");
        goto out;
    }
    if (strcmp(readback_full_hash, expect_output_full) != 0) {
        fprintf(stderr, "swap-boot-kernel: read back full sha256 mismatch: got %s, expected %s\n",
                readback_full_hash, expect_output_full);
        goto out;
    }
    memset(check, 0, (size_t)region_size);
    if (read_exact(fd, check, PAGE, 0) != 0) { rc = fail_errno("read back header"); goto out; }
    if (memcmp(check, written, PAGE) != 0) {
        rc = fail("read back header page differs from what was written");
        goto out;
    }
    if (parse_header(check, &readback_size) != 0) goto out;
    if (readback_size != image_size) { rc = fail("read back kernel size mismatch"); goto out; }
    if (read_exact(fd, check, (size_t)region_size, (off_t)PAGE) != 0) {
        rc = fail_errno("read back kernel");
        goto out;
    }
    if (memcmp(check, region, (size_t)region_size) != 0) {
        rc = fail("read back kernel region differs from what was written");
        goto out;
    }
    sha256_hex(check, image_size, readback_kernel_hash);
    if (strcmp(readback_kernel_hash, expect_image) != 0) {
        rc = fail("read back kernel sha256 mismatch");
        goto out;
    }
    {
        int close_rc = close(fd);
        int saved = errno;
        fd = -1;
        if (close_rc != 0) {
            errno = saved;
            rc = fail_errno("close verification target");
            goto out;
        }
    }
    printf("installed %u %s\n", (unsigned)image_size, readback_kernel_hash);
    rc = 0;
out:
    if (fd >= 0) close(fd);
    if (rc != 0 && write_started) {
        fprintf(stderr,
                "swap-boot-kernel: RECOVERY REQUIRED: target may be partially modified; do not boot it; restore the exact expected partition before retrying\n");
        rc = 3;
    }
    free(image);
    free(region);
    free(header);
    free(written);
    free(check);
    return rc;
}

int main(int argc, char **argv) {
    const char *target = NULL, *image = NULL, *expect_size = NULL;
    const char *expect_current_full = NULL, *expect_current_kernel = NULL;
    const char *expect_image = NULL, *expect_output_full = NULL;
    uint64_t target_size_value;
    char current_full_hex[65], current_kernel_hex[65], image_hex[65], output_full_hex[65];
    int i;
    if (argc == 3 && strcmp(argv[1], "--print-kernel-sha256") == 0)
        return print_kernel_sha256(argv[2]);
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--expect-target-size") == 0 && i + 1 < argc)
            expect_size = argv[++i];
        else if (strcmp(argv[i], "--expect-current-sha256") == 0 && i + 1 < argc)
            expect_current_full = argv[++i];
        else if (strcmp(argv[i], "--expect-current-kernel-sha256") == 0 && i + 1 < argc)
            expect_current_kernel = argv[++i];
        else if (strcmp(argv[i], "--expect-image-sha256") == 0 && i + 1 < argc)
            expect_image = argv[++i];
        else if (strcmp(argv[i], "--expect-output-sha256") == 0 && i + 1 < argc)
            expect_output_full = argv[++i];
        else if (argv[i][0] == '-') return usage();
        else if (target == NULL) target = argv[i];
        else if (image == NULL) image = argv[i];
        else return usage();
    }
    if (target == NULL || image == NULL || !parse_size(expect_size, &target_size_value) ||
        !valid_hex64(expect_current_full) || !valid_hex64(expect_current_kernel) ||
        !valid_hex64(expect_image) || !valid_hex64(expect_output_full))
        return usage();
    strcpy(current_full_hex, expect_current_full);
    strcpy(current_kernel_hex, expect_current_kernel);
    strcpy(image_hex, expect_image);
    strcpy(output_full_hex, expect_output_full);
    lower_hex(current_full_hex);
    lower_hex(current_kernel_hex);
    lower_hex(image_hex);
    lower_hex(output_full_hex);
    return swap(target, image, target_size_value, current_full_hex, current_kernel_hex,
                image_hex, output_full_hex);
}
