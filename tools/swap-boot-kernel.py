#!/usr/bin/env python3
"""Replace only the kernel payload inside an Android v4 boot image."""

import argparse
import hashlib
import os
import struct
import sys

PAGE = 4096
MAGIC = b"ANDROID!"
HEADER_VERSION = 4
HEADER_SIZE = 1584


def fail(message, status=1):
    sys.stderr.write("swap-boot-kernel: " + message + "\n")
    raise SystemExit(status)


def read_file(path):
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError as error:
        fail("cannot read %s: %s" % (path, error.strerror))


def parse_header(image):
    if len(image) < PAGE:
        fail("image shorter than one page")
    if image[:8] != MAGIC:
        fail("bad boot image magic")
    kernel_size, ramdisk_size = struct.unpack("<II", image[8:16])
    header_size = struct.unpack("<I", image[20:24])[0]
    header_version = struct.unpack("<I", image[40:44])[0]
    if header_version != HEADER_VERSION:
        fail("unsupported boot header version %d" % header_version)
    if header_size != HEADER_SIZE:
        fail("unexpected header size %d" % header_size)
    if ramdisk_size != 0:
        fail("boot image contains a ramdisk; kernel-only replacement is unsafe")
    if PAGE + kernel_size > len(image):
        fail("kernel payload extends past the boot image")
    return kernel_size


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def page_align(size):
    return (size + PAGE - 1) // PAGE * PAGE


def inspect(path):
    image = read_file(path)
    kernel_size = parse_header(image)
    payload = image[PAGE:PAGE + kernel_size]
    print("%d %s" % (kernel_size, sha256_hex(payload)))


def replace(stock_path, kernel_path, output_path):
    if os.path.exists(output_path):
        fail("output exists: %s" % output_path)
    stock = bytearray(read_file(stock_path))
    kernel = read_file(kernel_path)
    old_size = parse_header(stock)
    region_size = page_align(old_size)
    if not kernel:
        fail("new kernel is empty")
    if len(kernel) > region_size:
        fail(
            "new kernel (%d bytes) is larger than the stock region (%d bytes)"
            % (len(kernel), region_size)
        )
    output = bytearray(stock)
    output[PAGE:PAGE + region_size] = kernel + b"\0" * (region_size - len(kernel))
    output[8:12] = struct.pack("<I", len(kernel))
    temporary = output_path + ".tmp"
    try:
        with open(temporary, "wb") as handle:
            handle.write(output)
            handle.flush()
            os.fsync(handle.fileno())
        os.rename(temporary, output_path)
    except OSError as error:
        fail("cannot write %s: %s" % (output_path, error.strerror))
    print("%s  %s" % (sha256_hex(output), output_path))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--print-kernel-sha256", metavar="BOOT_IMG")
    parser.add_argument("stock", nargs="?")
    parser.add_argument("kernel", nargs="?")
    parser.add_argument("-o", "--output")
    args = parser.parse_args()
    if args.print_kernel_sha256:
        if args.stock or args.kernel or args.output:
            parser.error("--print-kernel-sha256 takes no other arguments")
        inspect(args.print_kernel_sha256)
        return
    if not (args.stock and args.kernel and args.output):
        parser.error("STOCK_BOOT_IMG IMAGE_LZ4 and --output are required")
    replace(args.stock, args.kernel, args.output)


if __name__ == "__main__":
    main()
