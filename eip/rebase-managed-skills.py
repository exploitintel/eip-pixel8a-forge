#!/usr/bin/env python3
"""Reconcile Forge's managed-skill baseline with the running phone image."""

from __future__ import annotations

import argparse
import http.cookiejar
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_ENV_FILE = "/data/eip-cve/config/eip-cve-ui.env"
DEFAULT_TIMEOUT_SECONDS = 15
REBASE_TIMEOUT_SECONDS = 60
REVISION_PATTERN = re.compile(r"^[0-9a-f]{16}$")
CSRF_PATTERN = re.compile(r"^[0-9a-f]{64}$")
REQUIRED_ENV_KEYS = ("EIP_CVE_UI_USER", "EIP_CVE_UI_PASSWORD", "EIP_CVE_UI_URL")


class MigrationError(Exception):
    """An expected, safely reportable migration refusal."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def read_private_environment(path: str) -> dict[str, str]:
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise MigrationError(f"cannot read UI environment file: {error.strerror}") from None
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise MigrationError("UI environment path must be a regular non-symlink file")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise MigrationError("UI environment file must not grant group or other permissions")

    values: dict[str, str] = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.rstrip("\n")
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key not in REQUIRED_ENV_KEYS:
                    continue
                if key in values:
                    raise MigrationError(f"duplicate {key} in UI environment file")
                if not value or "\r" in value or "\x00" in value:
                    raise MigrationError(f"invalid {key} in UI environment file")
                values[key] = value
    except (OSError, UnicodeError) as error:
        raise MigrationError(f"cannot parse UI environment file: {error.__class__.__name__}") from None

    missing = [key for key in REQUIRED_ENV_KEYS if key not in values]
    if missing:
        raise MigrationError(f"UI environment file is missing {', '.join(missing)}")
    return values


def loopback_origin(value: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError:
        raise MigrationError("EIP_CVE_UI_URL is malformed") from None
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "::1"}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or port is None
    ):
        raise MigrationError("EIP_CVE_UI_URL must be an explicit HTTP loopback origin")
    host = f"[{parsed.hostname}]" if ":" in parsed.hostname else parsed.hostname
    return f"http://{host}:{port}"


def read_json(response) -> dict:
    try:
        payload = response.read(1024 * 1024 + 1)
    except OSError:
        raise MigrationError("could not read the UI response") from None
    if len(payload) > 1024 * 1024:
        raise MigrationError("UI response exceeded the one-megabyte limit")
    try:
        value = json.loads(payload)
    except (UnicodeError, json.JSONDecodeError):
        raise MigrationError("UI returned malformed JSON") from None
    if not isinstance(value, dict):
        raise MigrationError("UI returned a non-object response")
    return value


def request_json(
    opener,
    origin: str,
    path: str,
    *,
    method: str = "GET",
    body=None,
    csrf=None,
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
):
    headers = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if csrf is not None:
        headers["x-eip-csrf"] = csrf
    request = urllib.request.Request(f"{origin}{path}", data=data, headers=headers, method=method)
    try:
        with opener.open(request, timeout=timeout) as response:
            if response.status != 200:
                raise MigrationError(f"{path} returned HTTP {response.status}")
            return read_json(response)
    except urllib.error.HTTPError as error:
        if path == "/api/skills/rebase" and error.code == 409:
            raise MigrationError("managed-skills rebase conflicted; no reset was attempted") from None
        raise MigrationError(f"{path} returned HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise MigrationError(f"request to {path} failed") from None


def validate_catalog(catalog: object) -> tuple[str, bool]:
    if not isinstance(catalog, dict):
        raise MigrationError("skills catalog is missing")
    revision = catalog.get("revision")
    outdated = catalog.get("baselineOutdated")
    if not isinstance(revision, str) or REVISION_PATTERN.fullmatch(revision) is None:
        raise MigrationError("skills catalog revision is malformed")
    if type(outdated) is not bool:
        raise MigrationError("skills catalog baseline status is malformed")
    return revision, outdated


def migrate(env_file: str) -> str:
    environment = read_private_environment(env_file)
    origin = loopback_origin(environment["EIP_CVE_UI_URL"])
    cookies = http.cookiejar.CookieJar()
    # The login carries operator credentials and must never inherit a proxy
    # route around the explicit loopback-origin restriction above.
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        NoRedirect(),
        urllib.request.HTTPCookieProcessor(cookies),
    )

    login = request_json(
        opener,
        origin,
        "/api/auth/login",
        method="POST",
        body={
            "username": environment["EIP_CVE_UI_USER"],
            "password": environment["EIP_CVE_UI_PASSWORD"],
        },
    )
    csrf = login.get("csrf")
    if login.get("ok") is not True or not isinstance(csrf, str) or CSRF_PATTERN.fullmatch(csrf) is None:
        raise MigrationError("UI authentication response is invalid")

    revision, outdated = validate_catalog(request_json(opener, origin, "/api/skills"))
    if not outdated:
        return f"managed-skills baseline is current at revision {revision}; no rebase needed"

    result = request_json(
        opener,
        origin,
        "/api/skills/rebase",
        method="POST",
        body={"expectedRevision": revision},
        csrf=csrf,
        timeout=REBASE_TIMEOUT_SECONDS,
    )
    result_revision = result.get("revision")
    catalog_revision, still_outdated = validate_catalog(result.get("catalog"))
    if (
        not isinstance(result_revision, str)
        or REVISION_PATTERN.fullmatch(result_revision) is None
        or result_revision != catalog_revision
    ):
        raise MigrationError("rebase response revisions do not agree")
    if still_outdated:
        raise MigrationError("rebase returned an outdated skills catalog; no reset was attempted")
    return f"managed-skills rebase completed at revision {catalog_revision}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", default=DEFAULT_ENV_FILE, help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    try:
        message = migrate(arguments.env_file)
    except MigrationError as error:
        print(f"managed-skills migration: {error}", file=sys.stderr)
        return 1
    print(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
