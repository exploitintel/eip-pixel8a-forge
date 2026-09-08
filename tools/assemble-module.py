#!/usr/bin/env python3
"""Assemble a deterministic KernelSU-Next qualification installer.

The archive contains the tracked module source plus explicit prebuilt static
AArch64 helpers, their provenance, and strict generated installer inputs. The
caller must opt in with --installable so an executable installer is never
produced by an ambiguous command.
"""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import stat
import struct
import sys
from urllib.parse import urlsplit
import zipfile


PROGRAM = "assemble-module"
REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = "MODULE-MANIFEST.json"
RELEASE_MANIFEST_PATH = "release-manifest.tsv"
INSTALLER_INPUTS_PATH = "installer-inputs.tsv"
MUSL_LICENSE_PATH = "LICENSES/musl-COPYRIGHT"
TOOLCHAIN_PROVENANCE_PATH = "provenance/toolchain.json"
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
MODULE_ID = "eip-pixel8a-forge"
MODULE_SOURCE_PATHS = frozenset((
    "action.sh", "bin/hostctl", "bin/install-host", "bin/install-preflight",
    "bin/kernelctl", "bin/prepare-engine", "bin/prepare-kernel",
    "bin/release-transaction", "boot-completed.sh", "customize.sh",
    "host.conf.default", "module.prop", "service.sh", "uninstall.sh",
))
TOOL_DESTINATIONS = {
    "patch_engine": "bin/patch-engine",
    "swap_boot_kernel": "bin/swap-boot-kernel",
    "privns": "bin/privns",
    "route_policy": "bin/route-policy",
}
RUNTIME_SCRIPT_DESTINATIONS = {
    "dockerd_script": "bin/dockerd.sh",
    "buildkit_runc_script": "bin/buildkit-runc.sh",
}
ENGINE_RUNTIME_NAMES = frozenset((
    "containerd", "containerd-shim-runc-v2", "ctr", "docker", "docker-init",
    "docker-proxy", "dockerd", "runc",
))
ENGINE_RUNTIME_ORDER = tuple(sorted(ENGINE_RUNTIME_NAMES, key=lambda value: value.encode("ascii")))
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SAFE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
BUILD_ID_PATTERN = re.compile(r"^[A-Z0-9]+(?:\.[A-Z0-9]+)+$")
SEMVER_PATTERN = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
PACKAGED_RUNTIME_PATHS = {
    "buildkit-runc.sh": "bin/buildkit-runc.sh",
    "dockerd.sh": "bin/dockerd.sh",
    "hostctl": "bin/hostctl",
    "privns": "bin/privns",
    "route-policy": "bin/route-policy",
}


class AssemblyError(Exception):
    pass


def fail(message):
    raise AssemblyError(message)


def sha256_hex(contents):
    return hashlib.sha256(contents).hexdigest()


def read_regular(path, description):
    path = os.fspath(path)
    try:
        before = os.lstat(path)
    except OSError as error:
        fail("cannot inspect %s %s: %s" % (description, path, error.strerror))
    if stat.S_ISLNK(before.st_mode):
        fail("%s must not be a symlink: %s" % (description, path))
    if not stat.S_ISREG(before.st_mode):
        fail("%s must be a regular file: %s" % (description, path))

    descriptor = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            fail("%s changed type while being read: %s" % (description, path))
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            fail("%s changed while being opened: %s" % (description, path))
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
        if (
            after.st_size != opened.st_size
            or after.st_mtime_ns != opened.st_mtime_ns
            or after.st_ctime_ns != opened.st_ctime_ns
        ):
            fail("%s changed while being read: %s" % (description, path))
        contents = b"".join(chunks)
        if len(contents) != opened.st_size:
            fail("%s size changed while being read: %s" % (description, path))
        return contents
    except AssemblyError:
        raise
    except OSError as error:
        fail("cannot read %s %s: %s" % (description, path, error.strerror))
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def parse_json_object(contents, description):
    def reject_duplicate_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail("%s contains duplicate JSON key %r" % (description, key))
            result[key] = value
        return result

    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError:
        fail("%s is not UTF-8 JSON" % description)
    try:
        value = json.loads(text, object_pairs_hook=reject_duplicate_keys)
    except AssemblyError:
        raise
    except (json.JSONDecodeError, ValueError) as error:
        fail("%s is not valid JSON: %s" % (description, error))
    if not isinstance(value, dict):
        fail("%s must contain a JSON object" % description)
    return value


def validate_member_name(name):
    if not isinstance(name, str) or not name:
        fail("archive member name is empty")
    if name.startswith("/") or "\\" in name or "\x00" in name:
        fail("unsafe archive member path: %r" % name)
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        fail("unsafe archive member path: %r" % name)
    parts = PurePosixPath(name).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        fail("unsafe archive member path: %r" % name)
    if PurePosixPath(name).is_absolute():
        fail("unsafe archive member path: %r" % name)


def add_entry(entries, folded_names, name, contents, mode):
    validate_member_name(name)
    if name == MANIFEST_PATH:
        fail("module source reserves %s for the generated manifest" % MANIFEST_PATH)
    if name in entries:
        fail("duplicate archive member: %s" % name)
    folded = name.casefold()
    if folded in folded_names:
        fail("case-insensitive archive member collision: %s and %s" % (folded_names[folded], name))
    if not isinstance(contents, bytes):
        fail("internal error: archive contents for %s are not bytes" % name)
    if mode not in (0o644, 0o755):
        fail("internal error: unsupported archive mode for %s" % name)
    entries[name] = (contents, mode)
    folded_names[folded] = name


def module_mode(relative_name):
    parts = PurePosixPath(relative_name).parts
    if relative_name.endswith(".sh") or (parts and parts[0] == "bin"):
        return 0o755
    return 0o644


def collect_module(module_root, entries, folded_names):
    module_root = Path(module_root)
    try:
        root_status = os.lstat(module_root)
    except OSError as error:
        fail("cannot inspect module source %s: %s" % (module_root, error.strerror))
    if stat.S_ISLNK(root_status.st_mode) or not stat.S_ISDIR(root_status.st_mode):
        fail("module source must be a real directory: %s" % module_root)

    def visit(directory, relative_parts):
        try:
            children = sorted(os.scandir(directory), key=lambda item: item.name.encode("utf-8"))
        except OSError as error:
            fail("cannot inspect module source directory %s: %s" % (directory, error.strerror))
        for child in children:
            child_parts = relative_parts + (child.name,)
            relative_name = PurePosixPath(*child_parts).as_posix()
            validate_member_name(relative_name)
            try:
                child_status = child.stat(follow_symlinks=False)
            except OSError as error:
                fail("cannot inspect module source member %s: %s" % (relative_name, error.strerror))
            if stat.S_ISLNK(child_status.st_mode):
                fail("module source contains a symlink: %s" % relative_name)
            if stat.S_ISDIR(child_status.st_mode):
                visit(Path(directory) / child.name, child_parts)
            elif stat.S_ISREG(child_status.st_mode):
                contents = read_regular(Path(directory) / child.name, "module source member")
                add_entry(entries, folded_names, relative_name, contents, module_mode(relative_name))
            else:
                fail("module source contains a special file: %s" % relative_name)

    visit(module_root, ())
    actual_paths = set(entries)
    missing = sorted(MODULE_SOURCE_PATHS - actual_paths)
    unexpected = sorted(actual_paths - MODULE_SOURCE_PATHS)
    if missing:
        fail("missing module source member: %s" % missing[0])
    if unexpected:
        fail("unexpected module source member: %s" % unexpected[0])


def parse_module_properties(contents):
    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError:
        fail("module.prop is not UTF-8")
    properties = {}
    for line in text.splitlines():
        if not line or "=" not in line:
            fail("module.prop contains a malformed line")
        key, value = line.split("=", 1)
        if not key or key in properties:
            fail("module.prop contains an empty or duplicate key")
        properties[key] = value
    if properties.get("id") != MODULE_ID:
        fail("module.prop has an unexpected module id")
    version = properties.get("version", "")
    installer_ascii(version, "module version", SAFE_NAME_PATTERN)
    if version.endswith("-dev"):
        fail("installable module must not use a development-only version")
    if not re.fullmatch(r"[1-9][0-9]*", properties.get("versionCode", "")):
        fail("module.prop has an invalid versionCode")
    if "updateJson" in properties:
        fail("v0.1 module must not contain updateJson")
    return properties


def validate_installable_customize(contents):
    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError:
        fail("customize.sh is not UTF-8")
    if not text.startswith("#!/system/bin/sh\n"):
        fail("customize.sh has an unexpected interpreter")
    if "Development source is not an installable module" in text:
        fail("customize.sh retains the development installation refusal")
    if re.search(r"(^|[;&|\s])exit([;&|\s]|$)", text):
        fail("sourced customize.sh must use abort rather than exit")
    continued = text.replace("\\\n", " ")
    install_host_call = re.compile(
        r'INSTALL_HOST_OUTPUT=\$\(KSU="\$KSU"\s+BOOTMODE="\$BOOTMODE"\s+'
        r'ARCH="\$ARCH"\s+KSU_VER="\$KSU_VER"\s+'
        r'KSU_VER_CODE="\$KSU_VER_CODE"\s+'
        r'KSU_RUNTIME_MODE="\$KSU_RUNTIME_MODE"\s+TMPDIR="\$TMPDIR"\s+'
        r'"\$MODPATH/bin/install-host" 2>&1\)'
    )
    if install_host_call.search(continued) is None:
        fail("customize.sh does not invoke the bounded install-host subprocess")
    for required in (
        '"$MODPATH/bin/kernelctl"',
        '"$MODPATH/action.sh"',
        '"$MODPATH/uninstall.sh"',
        'abort "host installation failed before a usable module was committed"',
    ):
        if required not in text:
            fail("customize.sh is missing the installable module contract: %s" % required)


def validate_static_aarch64(contents, description):
    if len(contents) < 64 or contents[:4] != b"\x7fELF":
        fail("%s is not an ELF binary" % description)
    if contents[4] != 2:
        fail("%s is not ELF64" % description)
    if contents[5] != 1:
        fail("%s is not little-endian ELF" % description)
    if contents[6] != 1:
        fail("%s has an unsupported ELF version" % description)
    try:
        (
            elf_type,
            machine,
            elf_version,
            _entry,
            program_offset,
            _section_offset,
            _flags,
            header_size,
            program_entry_size,
            program_count,
            _section_entry_size,
            _section_count,
            _section_names,
        ) = struct.unpack_from("<HHIQQQIHHHHHH", contents, 16)
    except struct.error:
        fail("%s has a truncated ELF header" % description)
    if elf_type not in (2, 3):
        fail("%s is not an executable ELF" % description)
    if machine != 183:
        fail("%s is not AArch64 ELF (e_machine=%d)" % (description, machine))
    if elf_version != 1 or header_size < 64:
        fail("%s has a malformed ELF header" % description)
    if program_count in (0, 0xFFFF) or program_entry_size < 56:
        fail("%s has no usable ELF program headers" % description)
    table_end = program_offset + program_entry_size * program_count
    if program_offset < header_size or table_end > len(contents):
        fail("%s has an out-of-range ELF program header table" % description)

    has_load = False
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        try:
            (
                segment_type,
                _segment_flags,
                file_offset,
                _virtual_address,
                _physical_address,
                file_size,
                _memory_size,
                _alignment,
            ) = struct.unpack_from("<IIQQQQQQ", contents, offset)
        except struct.error:
            fail("%s has a truncated ELF program header" % description)
        if file_offset > len(contents) or file_size > len(contents) - file_offset:
            fail("%s has an out-of-range ELF segment" % description)
        if segment_type == 1:
            has_load = True
        elif segment_type == 3:
            fail("%s has PT_INTERP and is not static" % description)
        elif segment_type == 2:
            if file_size == 0 or file_size % 16 != 0:
                fail("%s has a malformed PT_DYNAMIC segment" % description)
            terminated = False
            for dynamic_offset in range(file_offset, file_offset + file_size, 16):
                tag, _value = struct.unpack_from("<qQ", contents, dynamic_offset)
                if tag == 0:
                    terminated = True
                    break
                if tag == 1:
                    fail("%s has DT_NEEDED and is not static" % description)
            if not terminated:
                fail("%s has an unterminated PT_DYNAMIC segment" % description)
    if not has_load:
        fail("%s has no loadable ELF segment" % description)


def validate_toolchain_provenance(provenance, musl_license):
    if provenance.get("schemaVersion") != 1:
        fail("toolchain provenance has an unsupported schemaVersion")
    identity = provenance.get("identity")
    if not isinstance(identity, dict):
        fail("toolchain provenance is missing identity")
    target = identity.get("target")
    if (
        not isinstance(target, dict)
        or target.get("architecture") != "aarch64"
        or target.get("elfClass") != "ELF64"
        or target.get("elfMachine") != "AArch64"
        or not isinstance(target.get("toolPrefix"), str)
        or not target["toolPrefix"].startswith("aarch64")
        or "musl" not in target["toolPrefix"]
    ):
        fail("toolchain provenance does not identify an AArch64 musl target")
    licenses = provenance.get("licenses")
    musl = licenses.get("musl") if isinstance(licenses, dict) else None
    if not isinstance(musl, dict):
        fail("toolchain provenance is missing musl license metadata")
    if musl.get("archivePath") != MUSL_LICENSE_PATH:
        fail("toolchain provenance has an unexpected musl archive path")
    if musl.get("size") != len(musl_license):
        fail("musl license size does not match toolchain provenance")
    if musl.get("sha256") != sha256_hex(musl_license):
        fail("musl license sha256 does not match toolchain provenance")


def installer_ascii(value, description, pattern=None):
    if not isinstance(value, str) or not value:
        fail("%s must be a nonempty string" % description)
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError:
        fail("%s must be ASCII" % description)
    if any(byte < 32 or byte == 127 for byte in encoded):
        fail("%s contains a control character" % description)
    if pattern is not None and pattern.fullmatch(value) is None:
        fail("%s has an invalid form" % description)
    return value


def installer_positive_integer(value, description):
    if type(value) is not int or value <= 0:
        fail("%s must be a positive integer" % description)
    return value


def installer_nonnegative_integer(value, description):
    if type(value) is not int or value < 0:
        fail("%s must be a nonnegative integer" % description)
    return value


def installer_sha256(value, description):
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        fail("%s must be a lowercase SHA-256" % description)
    return value


def make_installer_inputs(engine_configuration, build_configuration, module_properties):
    """Compile JSON records into a strict, non-executable BusyBox input format."""
    module_version = installer_ascii(
        module_properties.get("version"), "module version", SAFE_NAME_PATTERN
    )
    module_version_code = installer_positive_integer(
        int(module_properties["versionCode"]), "module versionCode"
    )

    engine = engine_configuration.get("engine")
    if not isinstance(engine, dict):
        fail("engine configuration is missing engine metadata")
    engine_version = installer_ascii(
        engine.get("version"), "engine version", SEMVER_PATTERN
    )
    tarball = engine.get("tarball")
    if not isinstance(tarball, dict):
        fail("engine configuration is missing tarball metadata")
    tarball_url = installer_ascii(tarball.get("url"), "engine tarball URL")
    try:
        parsed_url = urlsplit(tarball_url)
        parsed_port = parsed_url.port
    except ValueError:
        fail("engine tarball URL has an invalid authority")
    if (
        parsed_url.scheme != "https"
        or not parsed_url.hostname
        or parsed_url.username is not None
        or parsed_url.password is not None
        or parsed_url.query
        or parsed_url.fragment
    ):
        fail("engine tarball URL must be HTTPS without credentials, query, or fragment")
    tarball_name = parsed_url.path.rsplit("/", 1)[-1]
    installer_ascii(tarball_name, "engine tarball basename", SAFE_NAME_PATTERN)
    if tarball_name != "docker-%s.tgz" % engine_version:
        fail("engine tarball basename does not match engine version")
    if (
        parsed_url.hostname != "download.docker.com"
        or parsed_port is not None
        or parsed_url.path != "/linux/static/stable/aarch64/%s" % tarball_name
    ):
        fail("engine tarball URL is outside the accepted Docker AArch64 origin")
    tarball_size = installer_positive_integer(tarball.get("size"), "engine tarball size")
    tarball_hash = installer_sha256(tarball.get("sha256"), "engine tarball sha256")

    rules = engine_configuration.get("rules")
    if not isinstance(rules, list) or len(rules) != 3:
        fail("engine configuration must contain exactly three ordered rules")
    normalized_rules = []
    seen_rule_sources = set()
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict) or set(rule) != {"from", "to"}:
            fail("engine rule %d must contain only from and to" % index)
        source = installer_ascii(rule.get("from"), "engine rule %d source" % index)
        replacement = installer_ascii(rule.get("to"), "engine rule %d replacement" % index)
        if not source.startswith("/") or not replacement.startswith("/"):
            fail("engine rule %d must use absolute strings" % index)
        if len(source.encode("ascii")) != len(replacement.encode("ascii")):
            fail("engine rule %d changes byte length" % index)
        if source in seen_rule_sources:
            fail("engine rules contain a duplicate source")
        seen_rule_sources.add(source)
        normalized_rules.append((source, replacement))

    binaries = engine_configuration.get("binaries")
    if not isinstance(binaries, dict):
        fail("engine configuration binaries must be an object")
    missing = sorted(ENGINE_RUNTIME_NAMES - set(binaries))
    unexpected = sorted(set(binaries) - ENGINE_RUNTIME_NAMES)
    if missing:
        fail("engine configuration omits required runtime binary: %s" % missing[0])
    if unexpected:
        fail("engine configuration contains unexpected runtime binary: %s" % unexpected[0])
    binary_rows = []
    for name in ENGINE_RUNTIME_ORDER:
        record = binaries[name]
        if not isinstance(record, dict):
            fail("engine runtime record must be an object: %s" % name)
        size = installer_positive_integer(record.get("size"), "engine runtime size: %s" % name)
        input_hash = installer_sha256(
            record.get("inputSha256"), "engine runtime input sha256: %s" % name
        )
        output_hash = installer_sha256(
            record.get("sha256"), "engine runtime output sha256: %s" % name
        )
        replacements = record.get("replacements")
        if not isinstance(replacements, dict):
            fail("engine runtime replacements must be an object: %s" % name)
        unknown_rules = sorted(set(replacements) - seen_rule_sources)
        if unknown_rules:
            fail("engine runtime names an unknown replacement rule: %s" % name)
        counts = []
        for source, _replacement in normalized_rules:
            count = replacements.get(source, 0)
            counts.append(installer_nonnegative_integer(
                count, "engine replacement count: %s" % name
            ))
        patch = 1 if replacements else 0
        if patch == 0 and any(count != 0 for count in counts):
            fail("unpatched engine runtime has replacement counts: %s" % name)
        if patch == 1 and not any(count > 0 for count in counts):
            fail("patched engine runtime has no replacements: %s" % name)
        binary_rows.append((
            "BINARY", name, size, input_hash, output_hash, patch, *counts
        ))

    if not isinstance(build_configuration, dict):
        fail("build configuration must be an object")
    if build_configuration.get("schemaVersion") != 1:
        fail("build configuration has an unsupported schemaVersion")
    if build_configuration.get("repository") != MODULE_ID:
        fail("build configuration has an unexpected repository")
    builds = build_configuration.get("builds")
    if not isinstance(builds, list) or not builds:
        fail("build configuration must contain at least one build")

    build_rows = []
    ksu_rows = []
    boot_rows = []
    seen_build_ids = set()
    seen_observable_builds = set()
    for record in builds:
        if not isinstance(record, dict):
            fail("build record must be an object")
        build_id = installer_ascii(record.get("buildId"), "build ID", BUILD_ID_PATTERN)
        if build_id in seen_build_ids:
            fail("build configuration contains duplicate build ID: %s" % build_id)
        seen_build_ids.add(build_id)
        if record.get("status") not in ("candidate", "released"):
            fail("build is not eligible for installer inputs: %s" % build_id)
        device = record.get("device")
        kernel = record.get("kernel")
        boot = record.get("boot")
        candidate = record.get("candidateImage")
        ksu = record.get("kernelSuNext")
        if not all(isinstance(value, dict) for value in (device, kernel, boot, candidate, ksu)):
            fail("build record is missing installer metadata: %s" % build_id)
        codename = installer_ascii(
            device.get("codename"), "%s codename" % build_id,
            re.compile(r"^[a-z0-9_-]+$"),
        )
        fingerprint = installer_ascii(
            device.get("buildFingerprint"), "%s build fingerprint" % build_id,
            re.compile(r"^[A-Za-z0-9._:/+-]+$"),
        )
        android_version = installer_positive_integer(
            device.get("androidVersion"), "%s Android version" % build_id
        )
        security_patch = installer_ascii(
            device.get("securityPatch"), "%s security patch" % build_id,
            re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"),
        )
        kernel_release = installer_ascii(
            kernel.get("release"), "%s kernel release" % build_id, SAFE_NAME_PATTERN
        )
        partition_size = installer_positive_integer(
            boot.get("partitionSize"), "%s boot partition size" % build_id
        )
        page_size = installer_positive_integer(
            boot.get("pageSize"), "%s boot page size" % build_id
        )
        header_version = installer_nonnegative_integer(
            boot.get("headerVersion"), "%s boot header version" % build_id
        )
        header_size = installer_positive_integer(
            boot.get("headerSize"), "%s boot header size" % build_id
        )
        ramdisk_size = installer_nonnegative_integer(
            boot.get("ramdiskSize"), "%s boot ramdisk size" % build_id
        )
        if (page_size, header_version, header_size, ramdisk_size) != (4096, 4, 1584, 0):
            fail("%s boot metadata is incompatible with swap-boot-kernel" % build_id)
        candidate_name = installer_ascii(
            candidate.get("name"), "%s candidate image name" % build_id,
            SAFE_NAME_PATTERN,
        )
        if candidate_name != "Image-%s.lz4" % build_id:
            fail("%s candidate image name is not build-qualified" % build_id)
        candidate_size = installer_positive_integer(
            candidate.get("size"), "%s candidate image size" % build_id
        )
        candidate_hash = installer_sha256(
            candidate.get("sha256"), "%s candidate image sha256" % build_id
        )
        candidate_partition_hash = installer_sha256(
            boot.get("candidateOutputPartitionSha256"),
            "%s candidate output partition sha256" % build_id,
        )
        observable_build = (
            codename, fingerprint, android_version, security_patch, kernel_release
        )
        if observable_build in seen_observable_builds:
            fail("build configuration contains an ambiguous observable device identity")
        seen_observable_builds.add(observable_build)
        build_rows.append((
            "BUILD", build_id, codename, fingerprint, android_version,
            security_patch, kernel_release, partition_size, page_size,
            header_version, header_size, ramdisk_size, candidate_name,
        ))

        if ksu.get("installationMode") != "LKM":
            fail("%s installer supports only the LKM KernelSU mode" % build_id)
        tested_versions = ksu.get("testedVersions")
        if not isinstance(tested_versions, list) or not tested_versions:
            fail("%s must name at least one tested KernelSU version" % build_id)
        if len(tested_versions) != len(set(tested_versions)):
            fail("%s has duplicate tested KernelSU versions" % build_id)
        for version in tested_versions:
            installer_ascii(version, "%s tested KernelSU version" % build_id, SEMVER_PATTERN)
            ksu_rows.append(("KSU", build_id, "lkm", version))

        accepted_inputs = boot.get("acceptedInputs")
        if not isinstance(accepted_inputs, list) or not accepted_inputs:
            fail("%s must contain at least one accepted boot input" % build_id)
        roles = set()
        boot_pairs = set()
        full_to_payload = {}
        for item in accepted_inputs:
            if not isinstance(item, dict):
                fail("%s accepted boot input must be an object" % build_id)
            role = installer_ascii(
                item.get("role"), "%s boot role" % build_id,
                re.compile(r"^[a-z][a-z0-9-]*$"),
            )
            if role == "current-public" or role in roles:
                fail("%s has a duplicate or reserved boot role: %s" % (build_id, role))
            roles.add(role)
            payload = item.get("payload")
            partition = item.get("partition")
            if not isinstance(payload, dict) or not isinstance(partition, dict):
                fail("%s boot state is missing identity metadata" % build_id)
            payload_size = installer_positive_integer(
                payload.get("size"), "%s %s payload size" % (build_id, role)
            )
            payload_hash = installer_sha256(
                payload.get("sha256"), "%s %s payload sha256" % (build_id, role)
            )
            input_partition_size = installer_positive_integer(
                partition.get("size"), "%s %s partition size" % (build_id, role)
            )
            if input_partition_size != partition_size:
                fail("%s %s partition size disagrees with build" % (build_id, role))
            partition_hash = installer_sha256(
                partition.get("sha256"), "%s %s partition sha256" % (build_id, role)
            )
            pair = (payload_size, payload_hash, input_partition_size, partition_hash)
            full_identity = (input_partition_size, partition_hash)
            payload_identity = (payload_size, payload_hash)
            if pair in boot_pairs:
                fail("%s has duplicate boot identity pairs" % build_id)
            if (
                full_identity in full_to_payload
                and full_to_payload[full_identity] != payload_identity
            ):
                fail("%s maps one full boot identity to multiple payloads" % build_id)
            boot_pairs.add(pair)
            full_to_payload[full_identity] = payload_identity
            boot_rows.append((
                "BOOT_STATE", build_id, role, payload_size, payload_hash,
                input_partition_size, partition_hash,
            ))
        current_pair = (
            candidate_size, candidate_hash, partition_size, candidate_partition_hash
        )
        current_full_identity = (partition_size, candidate_partition_hash)
        current_payload_identity = (candidate_size, candidate_hash)
        if current_pair in boot_pairs:
            fail("%s current-public boot identity duplicates an accepted input" % build_id)
        if (
            current_full_identity in full_to_payload
            and full_to_payload[current_full_identity] != current_payload_identity
        ):
            fail("%s current-public full identity maps to another payload" % build_id)
        boot_rows.append((
            "BOOT_STATE", build_id, "current-public", candidate_size,
            candidate_hash, partition_size, candidate_partition_hash,
        ))

    build_rows.sort(key=lambda row: row[1].encode("ascii"))
    ksu_rows.sort(key=lambda row: (row[1].encode("ascii"), row[3].encode("ascii")))
    boot_rows.sort(key=lambda row: (row[1].encode("ascii"), row[2].encode("ascii")))
    rows = [
        ("MODULE", module_version, module_version_code),
        ("ENGINE", engine_version, tarball_name, tarball_size, tarball_hash, tarball_url),
    ]
    rows.extend(("RULE", index, source, replacement)
                for index, (source, replacement) in enumerate(normalized_rules))
    rows.extend(binary_rows)
    rows.extend(build_rows)
    rows.extend(ksu_rows)
    rows.extend(boot_rows)
    lines = ["INSTALLER_INPUTS_VERSION=1"]
    lines.extend("\t".join(str(field) for field in row) for row in rows)
    return ("\n".join(lines) + "\n").encode("ascii")


def make_release_manifest(engine_configuration, entries):
    binaries = engine_configuration.get("binaries")
    if not isinstance(binaries, dict):
        fail("engine configuration binaries must be an object")
    actual_names = set(binaries)
    missing = sorted(ENGINE_RUNTIME_NAMES - actual_names)
    unexpected = sorted(actual_names - ENGINE_RUNTIME_NAMES)
    if missing:
        fail("engine configuration omits required runtime binary: %s" % missing[0])
    if unexpected:
        fail("engine configuration contains unexpected runtime binary: %s" % unexpected[0])

    records = {}
    for name in ENGINE_RUNTIME_NAMES:
        record = binaries[name]
        if not isinstance(record, dict):
            fail("engine runtime record must be an object: %s" % name)
        size = record.get("size")
        if type(size) is not int or size <= 0:
            fail("engine runtime size must be a positive integer: %s" % name)
        digest = record.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            fail("engine runtime output sha256 is invalid: %s" % name)
        records[name] = (size, digest)

    for name, archive_path in PACKAGED_RUNTIME_PATHS.items():
        try:
            contents, mode = entries[archive_path]
        except KeyError:
            fail("packaged runtime member is missing: %s" % archive_path)
        if mode != 0o755:
            fail("packaged runtime member is not executable: %s" % archive_path)
        records[name] = (len(contents), sha256_hex(contents))

    lines = ["RELEASE_MANIFEST_VERSION=1"]
    for name in sorted(records, key=lambda value: value.encode("ascii")):
        size, digest = records[name]
        lines.append("%s\t%d\t%s\t0755" % (name, size, digest))
    if len(records) != 13:
        fail("internal error: release manifest does not contain exactly 13 members")
    return ("\n".join(lines) + "\n").encode("ascii")


def make_manifest(entries, module_properties):
    records = []
    for name in sorted(entries):
        contents, mode = entries[name]
        records.append(
            {
                "mode": "%04o" % mode,
                "path": name,
                "sha256": sha256_hex(contents),
                "size": len(contents),
                "type": "file",
            }
        )
    manifest = {
        "artifact": "eip-pixel8a-forge-module",
        "entries": records,
        "installable": True,
        "manifestPath": MANIFEST_PATH,
        "module": {
            "id": module_properties["id"],
            "version": module_properties["version"],
            "versionCode": int(module_properties["versionCode"]),
        },
        "schemaVersion": 1,
        "zipTimestamp": "1980-01-01T00:00:00Z",
    }
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


def zip_info(name, mode):
    info = zipfile.ZipInfo(name, FIXED_ZIP_TIME)
    info.compress_type = zipfile.ZIP_STORED
    info.create_system = 3
    info.create_version = 20
    info.extract_version = 20
    info.external_attr = (stat.S_IFREG | mode) << 16
    info.internal_attr = 0
    info.extra = b""
    info.comment = b""
    return info


def write_archive(handle, entries, manifest_contents):
    with zipfile.ZipFile(handle, "w", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        archive_entries = dict(entries)
        archive_entries[MANIFEST_PATH] = (manifest_contents, 0o644)
        for name in sorted(archive_entries):
            contents, mode = archive_entries[name]
            archive.writestr(zip_info(name, mode), contents)


def publish_new_archive(output_path, entries, manifest_contents):
    absolute_output = os.path.abspath(os.fspath(output_path))
    directory = os.path.dirname(absolute_output)
    output_name = os.path.basename(absolute_output)
    if not output_name:
        fail("output path must name a file")

    directory_fd = None
    descriptor = None
    temporary_name = None
    published = False
    try:
        directory_fd = os.open(
            directory,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        flags = (
            os.O_RDWR
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        for _ in range(128):
            candidate = ".assemble-module.%s.tmp" % secrets.token_hex(16)
            try:
                descriptor = os.open(candidate, flags, 0o600, dir_fd=directory_fd)
                temporary_name = candidate
                break
            except FileExistsError:
                pass
        if descriptor is None:
            raise OSError(errno.EEXIST, "cannot allocate a unique temporary output")

        with os.fdopen(descriptor, "w+b") as handle:
            descriptor = None
            write_archive(handle, entries, manifest_contents)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), 0o644)
            try:
                os.link(
                    temporary_name,
                    output_name,
                    src_dir_fd=directory_fd,
                    dst_dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                published = True
            except FileExistsError:
                fail("output %s exists; refusing to overwrite" % output_path)
            except OSError as error:
                fail("cannot publish output %s: %s" % (output_path, error.strerror))
    except AssemblyError:
        raise
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        detail = error.strerror if isinstance(error, OSError) else str(error)
        fail("cannot write output %s: %s" % (output_path, detail))
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        cleanup_error = None
        if temporary_name is not None and directory_fd is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_error = error
        if directory_fd is not None:
            try:
                os.close(directory_fd)
            except OSError:
                pass
        if cleanup_error is not None:
            message = "cannot remove temporary archive: %s" % cleanup_error.strerror
            if not published:
                fail(message)
            sys.stderr.write("%s: warning: %s\n" % (PROGRAM, message))


def assemble(args):
    if not args.installable:
        fail("refusing to assemble an executable installer without --installable")
    if os.path.lexists(args.output):
        fail("output %s exists; refusing to overwrite" % args.output)

    entries = {}
    folded_names = {}
    collect_module(args.module_source, entries, folded_names)
    if "module.prop" not in entries or "customize.sh" not in entries:
        fail("module source must contain module.prop and customize.sh")
    module_properties = parse_module_properties(entries["module.prop"][0])
    validate_installable_customize(entries["customize.sh"][0])

    engine_configuration = None
    build_configuration = None
    fixed_inputs = [
        ("engine.json", args.engine_config, "engine configuration"),
        ("builds.json", args.builds_config, "build configuration"),
        ("LICENSE", args.license, "repository license"),
        ("NOTICE.md", args.notice, "repository notice"),
    ]
    for destination, source, description in fixed_inputs:
        contents = read_regular(source, description)
        if destination in ("engine.json", "builds.json"):
            document = parse_json_object(contents, description)
            if destination == "engine.json":
                engine_configuration = document
            else:
                build_configuration = document
        add_entry(entries, folded_names, destination, contents, 0o644)

    for argument_name, destination in RUNTIME_SCRIPT_DESTINATIONS.items():
        contents = read_regular(getattr(args, argument_name), "%s runtime script" % destination)
        if not contents.startswith(b"#!/system/bin/sh\n"):
            fail("%s runtime script has an unexpected interpreter" % destination)
        add_entry(entries, folded_names, destination, contents, 0o755)

    musl_license = read_regular(args.musl_license, "musl license")
    if not musl_license:
        fail("musl license is empty")
    provenance_contents = read_regular(args.toolchain_provenance, "toolchain provenance")
    provenance = parse_json_object(provenance_contents, "toolchain provenance")
    validate_toolchain_provenance(provenance, musl_license)
    add_entry(entries, folded_names, MUSL_LICENSE_PATH, musl_license, 0o644)
    add_entry(
        entries,
        folded_names,
        TOOLCHAIN_PROVENANCE_PATH,
        provenance_contents,
        0o644,
    )

    for argument_name, destination in TOOL_DESTINATIONS.items():
        source = getattr(args, argument_name)
        contents = read_regular(source, "%s binary" % destination)
        validate_static_aarch64(contents, destination)
        add_entry(entries, folded_names, destination, contents, 0o755)

    release_manifest = make_release_manifest(engine_configuration, entries)
    installer_inputs = make_installer_inputs(
        engine_configuration, build_configuration, module_properties
    )
    add_entry(entries, folded_names, INSTALLER_INPUTS_PATH, installer_inputs, 0o644)
    add_entry(entries, folded_names, RELEASE_MANIFEST_PATH, release_manifest, 0o644)
    manifest_contents = make_manifest(entries, module_properties)
    publish_new_archive(args.output, entries, manifest_contents)
    sys.stdout.write("%s  %s\n" % (sha256_hex(read_regular(args.output, "output archive")), args.output))


def argument_parser():
    parser = argparse.ArgumentParser(prog=PROGRAM)
    parser.add_argument(
        "--installable",
        action="store_true",
        help="explicitly authorize assembly of the executable installer",
    )
    parser.add_argument("--module-source", type=Path, default=REPOSITORY_ROOT / "module",
                        help="module source directory (default: repository module/)")
    parser.add_argument("--engine-config", type=Path,
                        default=REPOSITORY_ROOT / "tools" / "engine.json",
                        help="engine.json source copied verbatim")
    parser.add_argument("--builds-config", type=Path,
                        default=REPOSITORY_ROOT / "kernel" / "builds.json",
                        help="builds.json source copied verbatim")
    parser.add_argument("--license", type=Path, default=REPOSITORY_ROOT / "LICENSE",
                        help="first-party LICENSE source copied verbatim")
    parser.add_argument("--notice", type=Path, default=REPOSITORY_ROOT / "NOTICE.md",
                        help="NOTICE.md source copied verbatim")
    parser.add_argument("--dockerd-script", type=Path,
                        default=REPOSITORY_ROOT / "android" / "dockerd.sh",
                        help="generic Android dockerd.sh copied verbatim")
    parser.add_argument("--buildkit-runc-script", type=Path,
                        default=REPOSITORY_ROOT / "android" / "buildkit-runc.sh",
                        help="generic Android buildkit-runc.sh copied verbatim")
    parser.add_argument("--patch-engine", type=Path, required=True, help="prebuilt static AArch64 patch-engine")
    parser.add_argument("--swap-boot-kernel", type=Path, required=True,
                        help="prebuilt static AArch64 swap-boot-kernel")
    parser.add_argument("--privns", type=Path, required=True, help="prebuilt static AArch64 privns")
    parser.add_argument("--route-policy", type=Path, required=True,
                        help="prebuilt static AArch64 route-policy")
    parser.add_argument("--toolchain-provenance", type=Path, required=True,
                        help="tools/aarch64-musl-toolchain.json provenance copied verbatim")
    parser.add_argument("--musl-license", type=Path, required=True,
                        help="exact musl COPYRIGHT named by toolchain provenance")
    parser.add_argument("-o", "--output", type=Path, required=True, help="new output zip path")
    return parser


def main(argv):
    args = argument_parser().parse_args(argv)
    try:
        assemble(args)
    except AssemblyError as error:
        sys.stderr.write("%s: %s\n" % (PROGRAM, error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
