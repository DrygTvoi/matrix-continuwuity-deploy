#!/usr/bin/env python3
"""Patch a generated mautrix bridge config for this Docker stack.

The bridge images generate a large default config. We only change the keys that
must point at our homeserver, Docker service names and SQLite database. The
script is section-aware, so it does not accidentally rewrite the example values
in comments or unrelated sections.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

BRIDGES = {
    "telegram": {"port": 29317, "db": "mautrix-telegram.db"},
    "discord": {"port": 29334, "db": "mautrix-discord.db"},
    "whatsapp": {"port": 29318, "db": "mautrix-whatsapp.db"},
    "signal": {"port": 29328, "db": "mautrix-signal.db"},
}

TOP_RE = re.compile(r"^([A-Za-z0-9_]+):\s*$")
SUB_RE = re.compile(r"^    ([A-Za-z0-9_]+):\s*$")
KEY4_RE = re.compile(r"^    ([A-Za-z0-9_]+):\s*(.*)$")
KEY8_RE = re.compile(r"^        ([A-Za-z0-9_]+):\s*(.*)$")


def yaml_scalar(value: str | int | bool) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value)


def walk(lines: list[str]):
    """Yield (index, section, subsection, line) for every line."""
    section: str | None = None
    subsection: str | None = None
    for i, line in enumerate(lines):
        stripped = line.rstrip("\n")
        m = TOP_RE.match(stripped)
        if m:
            section = m.group(1)
            subsection = None
            yield i, section, subsection, stripped
            continue
        m = SUB_RE.match(stripped)
        if m and section:
            subsection = m.group(1)
            yield i, section, subsection, stripped
            continue
        m = KEY4_RE.match(stripped)
        if m and section:
            # A normal key at section level ends any previous subsection.
            subsection = None
            yield i, section, subsection, stripped
            continue
        yield i, section, subsection, stripped


def set_value(lines: list[str], section: str, subsection: str | None,
              key: str, value: str | int) -> bool:
    for i, sec, sub, stripped in walk(lines):
        if sec != section or sub != subsection:
            continue
        m = KEY8_RE.match(stripped) if subsection else KEY4_RE.match(stripped)
        if not m or m.group(1) != key:
            continue
        indent = "        " if subsection else "    "
        lines[i] = f"{indent}{key}: {yaml_scalar(value)}\n"
        return True
    return False


def replace_in_block(lines: list[str], section: str, subsection: str,
                     old: str, new: str) -> int:
    count = 0
    for i, sec, sub, stripped in walk(lines):
        if sec == section and sub == subsection and old in stripped:
            lines[i] = stripped.replace(old, new) + "\n"
            count += 1
    return count


def comment_in_block(lines: list[str], section: str, subsection: str,
                     needle: str) -> int:
    count = 0
    for i, sec, sub, stripped in walk(lines):
        if sec == section and sub == subsection and needle in stripped:
            if not stripped.lstrip().startswith("#"):
                lines[i] = "        # disabled: " + stripped.lstrip() + "\n"
                count += 1
    return count


def empty_map_subsection(lines: list[str], section: str, subsection: str) -> bool:
    """Turn `    name:` into `    name: {}` when all entries were commented out.

    A YAML key with only comments under it parses as null, which makes mautrix
    log "Ignoring incorrect config field type !!null" even though it works.
    """
    for i, sec, sub, stripped in walk(lines):
        if sec != section or sub != subsection:
            continue
        if stripped == f"    {subsection}:":
            lines[i] = f"    {subsection}: {{}}\n"
            return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", required=True, choices=sorted(BRIDGES))
    parser.add_argument("--config", required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--bridge-host", default="")
    parser.add_argument("--telegram-api-id", default="")
    parser.add_argument("--telegram-api-hash", default="")
    args = parser.parse_args()

    bridge_host = args.bridge_host or f"bridge.{args.domain}"

    info = BRIDGES[args.bridge]
    path = Path(args.config)
    if not path.is_file():
        print(f"error: {path} does not exist", file=sys.stderr)
        return 1

    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    changes: list[str] = []

    def setv(section: str, subsection: str | None, key: str, value: str | int):
        if set_value(lines, section, subsection, key, value):
            changes.append(f"{section}.{(subsection + '.') if subsection else ''}{key}")
        else:
            print(f"warning: {section}.{(subsection + '.') if subsection else ''}{key} not found",
                  file=sys.stderr)

    # Homeserver / appservice wiring
    setv("homeserver", None, "address", "http://continuwuity:8008")
    setv("homeserver", None, "domain", args.domain)
    setv("appservice", None, "address",
         f"http://mautrix-{args.bridge}:{info['port']}")
    setv("appservice", None, "hostname", "0.0.0.0")
    setv("appservice", None, "port", info["port"])
    # public_address exists for python bridges and WhatsApp/Signal, not Discord.
    set_value(lines, "appservice", None, "public_address",
              f"https://{bridge_host}/{args.bridge}")

    # SQLite database. Telegram/WhatsApp/Signal put it at top level; Discord
    # nests it under appservice.
    db_uri = f"file:/data/{info['db']}?_txlock=immediate"
    if not set_value(lines, "database", None, "type", "sqlite3-fk-wal"):
        setv("appservice", "database", "type", "sqlite3-fk-wal")
    if not set_value(lines, "database", None, "uri", db_uri):
        setv("appservice", "database", "uri", db_uri)

    # Give local users full access; the admin gets bridge admin commands.
    permissions = replace_in_block(
        lines, "bridge", "permissions", "example.com", args.domain)
    if permissions == 0:
        print("warning: bridge.permissions entries not found", file=sys.stderr)

    # The generated example has a fake double-puppeting secret. Leaving it in
    # makes the bridge try to use an invalid token.
    if comment_in_block(lines, "double_puppet", "secrets", "example.com"):
        empty_map_subsection(lines, "double_puppet", "secrets")
    for sub in ("double_puppet_server_map", "login_shared_secret_map"):
        if comment_in_block(lines, "bridge", sub, "example.com"):
            empty_map_subsection(lines, "bridge", sub)

    # End-to-bridge encryption is supported by Telegram/WhatsApp/Signal.
    if args.bridge in {"telegram", "whatsapp", "signal"}:
        set_value(lines, "encryption", None, "allow", True)

    # Telegram needs API credentials at startup.
    if args.bridge == "telegram":
        if not args.telegram_api_id.isdigit():
            print("error: --telegram-api-id must be numeric", file=sys.stderr)
            return 1
        if not args.telegram_api_hash:
            print("error: --telegram-api-hash is empty", file=sys.stderr)
            return 1
        setv("network", None, "api_id", int(args.telegram_api_id))
        setv("network", None, "api_hash", args.telegram_api_hash)

    mode = path.stat().st_mode
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".config.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.writelines(lines)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(f"patched {args.bridge}: {', '.join(changes) if changes else 'no changes'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
