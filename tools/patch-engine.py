#!/usr/bin/env python3
"""Rebuild the Android engine binaries from Docker's own static release.

Reads tools/engine.json, verifies the release tarball against the pinned size
and sha256, extracts the listed binaries, applies the same-length path
substitutions, verifies the replacement counts and the output hashes, and only
then writes the results. Nothing is written on any mismatch. The procedure and
its evidence are recorded in docs/ENGINE-PATCH.md.

usage: patch-engine.py --engine tools/engine.json --tarball docker-VERSION.tgz --out DIR
       patch-engine.py --engine tools/engine.json --download --cache DIR --out DIR
"""

import argparse
import hashlib
import io
import json
import os
import re
import secrets
import stat
import sys
import tarfile
import urllib.parse
import urllib.request


def fail(message, status=1):
    sys.stderr.write("patch-engine: " + message + "\n")
    sys.exit(status)


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def read_file(path, mode="rb"):
    try:
        with open(path, mode) as handle:
            return handle.read()
    except OSError as error:
        fail("cannot read %s: %s" % (path, error.strerror))


def safe_basename(name, description):
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        fail("unsafe %s: %r" % (description, name))
    if name in (".", ".."):
        fail("unsafe %s: %r" % (description, name))
    return name


def load_pin(path):
    try:
        pin = json.loads(read_file(path, "r"))
    except ValueError as error:
        fail("%s is not valid JSON: %s" % (path, error))
    for rule in pin["rules"]:
        old = rule["from"].encode("ascii")
        new = rule["to"].encode("ascii")
        if len(old) != len(new):
            fail("rule changes length: %r -> %r" % (rule["from"], rule["to"]))
        if len(old) == 0:
            fail("empty rule")
    rule_keys = {rule["from"] for rule in pin["rules"]}
    folded_names = {}
    for name, expected in pin["binaries"].items():
        safe_basename(name, "binary name")
        folded = name.casefold()
        if folded in folded_names:
            fail("case-insensitive binary name collision: %s and %s" % (folded_names[folded], name))
        folded_names[folded] = name
        unknown = set(expected["replacements"]) - rule_keys
        if unknown:
            fail("replacements for %s name strings that are not rules: %s" % (name, sorted(unknown)))
    return pin


def write_all(fd, data):
    offset = 0
    while offset < len(data):
        written = os.write(fd, data[offset:])
        if written == 0:
            raise OSError("zero-byte write")
        offset += written


def open_private_cache(path):
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        try:
            os.mkdir(path, mode=0o700)
        except FileExistsError:
            pass
        except OSError as error:
            fail("cannot create cache directory %s: %s" % (path, error.strerror))
        try:
            before = os.lstat(path)
        except OSError as error:
            fail("cannot inspect cache directory %s: %s" % (path, error.strerror))
    except OSError as error:
        fail("cannot inspect cache directory %s: %s" % (path, error.strerror))

    if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
        fail("cache path must be a real directory: %s" % path)
    if before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) & 0o022:
        fail("cache directory must be owned by the current user and not writable by group or other: %s" % path)

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    directory_fd = None
    try:
        directory_fd = os.open(path, flags)
        opened = os.fstat(directory_fd)
    except OSError as error:
        if directory_fd is not None:
            try:
                os.close(directory_fd)
            except OSError:
                pass
        fail("cannot open cache directory %s: %s" % (path, error.strerror))
    if (
        not stat.S_ISDIR(opened.st_mode)
        or opened.st_dev != before.st_dev
        or opened.st_ino != before.st_ino
        or opened.st_uid != os.geteuid()
        or stat.S_IMODE(opened.st_mode) & 0o022
    ):
        os.close(directory_fd)
        fail("cache directory changed while opening: %s" % path)
    return directory_fd


def read_cache_entry(directory_fd, name):
    try:
        before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as error:
        fail("cannot inspect cached tarball %s: %s" % (name, error.strerror))
    if not stat.S_ISREG(before.st_mode):
        fail("cached tarball is not a regular file: %s" % name)

    descriptor = None
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_dev != before.st_dev
            or opened.st_ino != before.st_ino
        ):
            fail("cached tarball changed while opening: %s" % name)
        chunks = []
        while True:
            chunk = os.read(descriptor, 1 << 20)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
        if (
            after.st_dev != opened.st_dev
            or after.st_ino != opened.st_ino
            or after.st_size != opened.st_size
            or after.st_mtime_ns != opened.st_mtime_ns
            or after.st_ctime_ns != opened.st_ctime_ns
        ):
            fail("cached tarball changed while reading: %s" % name)
        data = b"".join(chunks)
        if len(data) != opened.st_size:
            fail("cached tarball size changed while reading: %s" % name)
        return data
    except OSError as error:
        fail("cannot read cached tarball %s: %s" % (name, error.strerror))
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def verify_tarball(data, expected):
    if len(data) != expected["size"]:
        fail("tarball size mismatch: got %d, expected %d" % (len(data), expected["size"]))
    digest = sha256_hex(data)
    if digest != expected["sha256"]:
        fail("tarball sha256 mismatch: got %s, expected %s" % (digest, expected["sha256"]))


def download_to_cache(directory_fd, name, url, expected):
    temporary_name = None
    descriptor = None
    published = False
    try:
        for _ in range(128):
            candidate = ".download-%s.tmp" % secrets.token_hex(16)
            try:
                descriptor = os.open(
                    candidate,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                    0o600,
                    dir_fd=directory_fd,
                )
                temporary_name = candidate
                break
            except FileExistsError:
                continue
            except OSError as error:
                fail("cannot create temporary download in cache: %s" % error.strerror)
        if descriptor is None:
            fail("cannot create a unique temporary download")

        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    write_all(descriptor, chunk)
        except (OSError, ValueError) as error:
            fail("download failed: %s" % error)
        try:
            os.fsync(descriptor)
            os.close(descriptor)
        except OSError as error:
            fail("cannot finish temporary download: %s" % error.strerror)
        descriptor = None

        data = read_cache_entry(directory_fd, temporary_name)
        if data is None:
            fail("temporary download disappeared before verification")
        verify_tarball(data, expected)
        try:
            os.link(
                temporary_name,
                name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except FileExistsError:
            fail("cached tarball appeared concurrently; refusing to overwrite: %s" % name)
        except OSError as error:
            fail("cannot publish cached tarball %s: %s" % (name, error.strerror))
        published = True
        return data
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            except OSError as error:
                if published:
                    sys.stderr.write(
                        "patch-engine: warning: cached tarball is valid but temporary link remains: %s: %s\n"
                        % (temporary_name, error.strerror)
                    )


def obtain_tarball(pin, tarball_path, download, cache_dir):
    tarball = pin["engine"]["tarball"]
    if tarball_path is None:
        if cache_dir is None:
            fail("--download requires --cache DIR", 2)
        try:
            archive_name = safe_basename(
                os.path.basename(urllib.parse.urlsplit(tarball["url"]).path),
                "cached tarball name",
            )
        except ValueError as error:
            fail("invalid tarball URL: %s" % error)
        directory_fd = open_private_cache(cache_dir)
        try:
            data = read_cache_entry(directory_fd, archive_name)
            if data is None:
                sys.stderr.write("patch-engine: downloading %s\n" % tarball["url"])
                data = download_to_cache(
                    directory_fd,
                    archive_name,
                    tarball["url"],
                    tarball,
                )
        finally:
            os.close(directory_fd)
    else:
        data = read_file(tarball_path)
    verify_tarball(data, tarball)
    return data


def patch(data, rules):
    counts = {}
    for rule in rules:
        old = rule["from"].encode("ascii")
        new = rule["to"].encode("ascii")
        count = data.count(old)
        if count:
            data = data.replace(old, new)
        counts[rule["from"]] = count
    return data, counts


def publish_results(output_path, results):
    try:
        os.mkdir(output_path, mode=0o755)
    except FileExistsError:
        fail("output directory %s exists; refusing to overwrite" % output_path)
    except OSError as error:
        fail("cannot create output directory %s: %s" % (output_path, error.strerror))

    directory_fd = None
    try:
        created = os.lstat(output_path)
        directory_fd = os.open(
            output_path,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        opened = os.fstat(directory_fd)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or opened.st_dev != created.st_dev
            or opened.st_ino != created.st_ino
        ):
            fail("output directory changed while opening: %s" % output_path)

        for name, patched, digest in results:
            descriptor = None
            try:
                descriptor = os.open(
                    name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                    0o600,
                    dir_fd=directory_fd,
                )
                write_all(descriptor, patched)
                os.fchmod(descriptor, 0o755)
                os.fsync(descriptor)
            except FileExistsError:
                fail("output member exists; refusing to overwrite: %s" % name)
            except OSError as error:
                fail("cannot write output member %s: %s" % (name, error.strerror))
            finally:
                if descriptor is not None:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
            sys.stdout.write("%s  %s\n" % (digest, name))
    finally:
        if directory_fd is not None:
            try:
                os.close(directory_fd)
            except OSError:
                pass


def main(argv):
    parser = argparse.ArgumentParser(prog="patch-engine.py")
    parser.add_argument("--engine", required=True, help="engine pin (tools/engine.json)")
    parser.add_argument("--tarball", help="local copy of the pinned release tarball")
    parser.add_argument("--download", action="store_true", help="download the pinned tarball into --cache")
    parser.add_argument("--cache", help="directory that keeps downloaded tarballs")
    parser.add_argument("--out", required=True, help="output directory (must not exist)")
    args = parser.parse_args(argv)
    if args.tarball is None and not args.download:
        parser.error("either --tarball PATH or --download --cache DIR is required")
    if args.tarball is not None and args.download:
        parser.error("--tarball and --download are mutually exclusive")
    if os.path.lexists(args.out):
        fail("output directory %s exists; refusing to overwrite" % args.out)

    pin = load_pin(args.engine)
    data = obtain_tarball(pin, args.tarball, args.download, args.cache)

    members = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive.getmembers():
            if member.isfile():
                members[member.name] = archive.extractfile(member).read()

    results = []
    for name, expected in pin["binaries"].items():
        key = "docker/" + name
        if key not in members:
            fail("%s not in tarball" % key)
        original = members[key]
        if len(original) != expected["size"]:
            fail("input size mismatch for %s: got %d, expected %d" % (name, len(original), expected["size"]))
        input_digest = sha256_hex(original)
        if input_digest != expected.get("inputSha256"):
            fail("input sha256 mismatch for %s: got %s, expected %s" % (name, input_digest, expected.get("inputSha256")))
        rules = pin["rules"] if expected["replacements"] else []
        patched, counts = patch(original, rules)
        wanted = {rule["from"]: expected["replacements"].get(rule["from"], 0) for rule in rules}
        if counts != wanted:
            fail("replacement count mismatch for %s: got %s, expected %s" % (name, counts, wanted))
        if len(patched) != len(original):
            fail("length changed for %s" % name)
        digest = sha256_hex(patched)
        if digest != expected["sha256"]:
            fail("output sha256 mismatch for %s: got %s, expected %s" % (name, digest, expected["sha256"]))
        results.append((name, patched, digest))

    publish_results(args.out, results)
    sys.stdout.write("patch-engine: %d binaries written to %s\n" % (len(results), args.out))


if __name__ == "__main__":
    main(sys.argv[1:])
