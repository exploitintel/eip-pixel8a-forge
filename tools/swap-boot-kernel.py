#!/usr/bin/env python3
"""Replace only the kernel inside an Android boot image, byte for byte.

The GKI boot signature, the boot vbmeta with the security patch property, and
the AVB footer keep their absolute offsets: the new kernel is zero padded
inside the stock kernel's page-rounded region and only the kernel_size header
field changes. Images rebuilt by mkbootimg or repacked by magiskboot lose that
property on this device. See docs/BOOT-SWAP.md.

usage: swap-boot-kernel.py STOCK_BOOT_IMG IMAGE_LZ4 -o OUT
           --expect-target-size DECIMAL --expect-current-sha256 HEX
           --expect-current-kernel-sha256 HEX --expect-image-sha256 HEX
           --expect-output-sha256 HEX
       swap-boot-kernel.py --print-kernel-sha256 BOOT_IMG
"""

import argparse
import errno
import hashlib
import os
import re
import secrets
import struct
import sys

PAGE = 4096
MAGIC = b"ANDROID!"
HEADER_VERSION = 4
HEADER_SIZE = 1584
SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")


def fail(message, status=1):
    sys.stderr.write("swap-boot-kernel: " + message + "\n")
    sys.exit(status)


def parse_header(image):
    if len(image) < PAGE:
        fail("image shorter than one page")
    if image[:8] != MAGIC:
        fail("bad boot image magic (expected ANDROID!)")
    kernel_size, ramdisk_size = struct.unpack("<II", image[8:16])
    header_size = struct.unpack("<I", image[20:24])[0]
    header_version = struct.unpack("<I", image[40:44])[0]
    if header_version != HEADER_VERSION:
        fail("unsupported boot header version %d (expected %d)" % (header_version, HEADER_VERSION))
    if header_size != HEADER_SIZE:
        fail("unexpected header size %d (expected %d)" % (header_size, HEADER_SIZE))
    if ramdisk_size != 0:
        fail("image carries a ramdisk of %d bytes; a kernel swap would move it" % ramdisk_size)
    if kernel_size == 0:
        fail("kernel_size is zero")
    if PAGE + kernel_size > len(image):
        fail("kernel_size %d runs past the end of the image" % kernel_size)
    if PAGE + page_align(kernel_size) > len(image):
        fail("page-rounded kernel region runs past the end of the image")
    return kernel_size


def page_align(size):
    return (size + PAGE - 1) // PAGE * PAGE


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def positive_decimal(value):
    if re.fullmatch(r"[0-9]+", value) is None or int(value) == 0:
        raise argparse.ArgumentTypeError("must be a positive decimal integer")
    return int(value)


def expected_sha256(value):
    if SHA256.fullmatch(value) is None:
        raise argparse.ArgumentTypeError("must be exactly 64 hexadecimal characters")
    return value.lower()


def read_file(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError as error:
        fail("cannot read %s: %s" % (path, error.strerror))


def print_kernel_sha256(path):
    image = read_file(path)
    kernel_size = parse_header(image)
    kernel = image[PAGE:PAGE + kernel_size]
    sys.stdout.write("%d %s\n" % (kernel_size, sha256_hex(kernel)))


def publish_new_output(out_path, contents):
    """Atomically create out_path without replacing any directory entry."""
    absolute_output = os.path.abspath(out_path)
    directory = os.path.dirname(absolute_output)
    output_name = os.path.basename(absolute_output)
    directory_fd = None
    temporary_name = None
    descriptor = None
    error_message = None
    try:
        directory_fd = os.open(
            directory,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        temporary_flags = (
            os.O_WRONLY | os.O_CREAT | os.O_EXCL |
            getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        )
        for _ in range(128):
            candidate_name = ".swap-boot-kernel.%s.tmp" % secrets.token_hex(16)
            try:
                descriptor = os.open(
                    candidate_name, temporary_flags, 0o600, dir_fd=directory_fd
                )
                temporary_name = candidate_name
                break
            except FileExistsError:
                pass
        if descriptor is None:
            raise OSError(errno.EEXIST, "cannot allocate a unique temporary output")
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
            try:
                # Both names are resolved in the one pinned directory. The
                # hard link publishes only a complete, fsynced file and fails
                # with EEXIST for every existing leaf, including a symlink.
                os.link(
                    temporary_name, output_name,
                    src_dir_fd=directory_fd, dst_dir_fd=directory_fd,
                    follow_symlinks=False,
                )
            except FileExistsError:
                error_message = "output %s exists; refusing to overwrite" % out_path
            except OSError as error:
                error_message = "cannot write %s: %s" % (out_path, error.strerror)
    except OSError as error:
        error_message = "cannot write %s: %s" % (out_path, error.strerror)
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary_name is not None and directory_fd is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_message = "cannot remove temporary output %s: %s" % (
                    os.path.join(directory, temporary_name), error.strerror
                )
                error_message = cleanup_message if error_message is None else (
                    error_message + "; " + cleanup_message
                )
        if directory_fd is not None:
            try:
                os.close(directory_fd)
            except OSError:
                pass
    if error_message is not None:
        fail(error_message)


def swap(stock_path, image_path, out_path, expect_target_size, expect_current_sha256,
         expect_current_kernel_sha256, expect_image_sha256, expect_output_sha256):
    if os.path.lexists(out_path):
        fail("output %s exists; refusing to overwrite" % out_path)
    stock = bytearray(read_file(stock_path))
    if len(stock) != expect_target_size:
        fail("target size mismatch: got %d, expected %d" % (len(stock), expect_target_size))
    current_digest = sha256_hex(stock)
    if current_digest != expect_current_sha256:
        fail("current sha256 mismatch: got %s, expected %s" %
             (current_digest, expect_current_sha256))
    kernel = read_file(image_path)
    image_digest = sha256_hex(kernel)
    if image_digest != expect_image_sha256:
        fail("image sha256 mismatch: got %s, expected %s" %
             (image_digest, expect_image_sha256))
    old_size = parse_header(stock)
    current_kernel_digest = sha256_hex(stock[PAGE:PAGE + old_size])
    if current_kernel_digest != expect_current_kernel_sha256:
        fail("current kernel sha256 mismatch: got %s, expected %s" %
             (current_kernel_digest, expect_current_kernel_sha256))
    region = page_align(old_size)
    if len(kernel) > region:
        fail("new kernel (%d bytes) is larger than the stock kernel region (%d bytes)" % (len(kernel), region))
    if len(kernel) == 0:
        fail("new kernel is empty")
    out = bytearray(stock)
    out[PAGE:PAGE + region] = kernel + b"\0" * (region - len(kernel))
    out[8:12] = struct.pack("<I", len(kernel))
    digest = sha256_hex(out)
    if digest != expect_output_sha256:
        fail("output sha256 mismatch: got %s, expected %s" % (digest, expect_output_sha256))
    publish_new_output(out_path, out)
    sys.stdout.write("%s  %s\n" % (digest, out_path))


def main(argv):
    parser = argparse.ArgumentParser(prog="swap-boot-kernel.py", add_help=True)
    parser.add_argument("--print-kernel-sha256", metavar="BOOT_IMG",
                        help="print the kernel payload size and sha256, write nothing")
    parser.add_argument("stock", nargs="?", help="stock boot.img (header v4, no ramdisk)")
    parser.add_argument("image", nargs="?", help="Image.lz4 to install")
    parser.add_argument("-o", "--output", help="output boot image path (must not exist)")
    parser.add_argument("--expect-target-size", type=positive_decimal, metavar="DECIMAL",
                        help="refuse unless the complete input has this size")
    parser.add_argument("--expect-current-sha256", type=expected_sha256, metavar="HEX",
                        help="refuse unless the complete input has this sha256")
    parser.add_argument("--expect-current-kernel-sha256", type=expected_sha256, metavar="HEX",
                        help="refuse unless the current kernel payload has this sha256")
    parser.add_argument("--expect-image-sha256", type=expected_sha256, metavar="HEX",
                        help="refuse unless Image.lz4 has this sha256")
    parser.add_argument("--expect-output-sha256", type=expected_sha256, metavar="HEX",
                        help="refuse unless the complete generated output has this sha256")
    args = parser.parse_args(argv)
    expectations = {
        "--expect-target-size": args.expect_target_size,
        "--expect-current-sha256": args.expect_current_sha256,
        "--expect-current-kernel-sha256": args.expect_current_kernel_sha256,
        "--expect-image-sha256": args.expect_image_sha256,
        "--expect-output-sha256": args.expect_output_sha256,
    }
    if args.print_kernel_sha256:
        if args.stock or args.image or args.output or any(value is not None for value in expectations.values()):
            parser.error("--print-kernel-sha256 takes no other arguments")
        print_kernel_sha256(args.print_kernel_sha256)
        return
    if not (args.stock and args.image and args.output):
        parser.error("STOCK_BOOT_IMG, IMAGE_LZ4 and -o OUT are required")
    missing = [name for name, value in expectations.items() if value is None]
    if missing:
        parser.error("the following arguments are required for swap: %s" % ", ".join(missing))
    swap(args.stock, args.image, args.output, args.expect_target_size,
         args.expect_current_sha256, args.expect_current_kernel_sha256,
         args.expect_image_sha256, args.expect_output_sha256)


if __name__ == "__main__":
    main(sys.argv[1:])
