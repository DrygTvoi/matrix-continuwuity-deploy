#!/usr/bin/env python3
"""Register mautrix appservices with Continuwuity through the admin room.

Continuwuity registers appservices at runtime: an admin sends
`!admin appservices register` followed by the registration YAML in a code
block. This script does that for every generated bridge registration.

Usage:
  python3 scripts/matrix_admin.py --domain example.com --user admin --bridges telegram,discord

The password is prompted for (not passed on the command line). Alternatively
pass --token with an admin access token.
"""

from __future__ import annotations

import argparse
import getpass
import json
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def api(domain: str, method: str, path: str, token: str | None = None,
        payload: dict | None = None) -> dict:
    url = f"https://{domain}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:500]
        raise SystemExit(f"HTTP {exc.code} from {method} {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Cannot reach {url}: {exc.reason}") from exc


def login(domain: str, user: str, password: str | None) -> str:
    if password is None:
        password = getpass.getpass(f"Matrix password for {user}: ")
    result = api(domain, "POST", "/_matrix/client/v3/login", payload={
        "type": "m.login.password",
        "identifier": {"type": "m.id.user", "user": user},
        "password": password,
    })
    token = result.get("access_token")
    if not token:
        raise SystemExit(f"login returned no access_token: {result}")
    return token


def find_admin_room(domain: str, token: str) -> str:
    result = api(domain, "GET", "/_matrix/client/v3/joined_rooms", token)
    rooms = result.get("joined_rooms", [])
    names: list[tuple[str, str]] = []
    for room_id in rooms:
        path = f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id, safe='')}/state/m.room.name"
        try:
            state = api(domain, "GET", path, token)
        except SystemExit:
            continue
        name = state.get("name", "")
        names.append((room_id, name))
        if "admin" in name.lower():
            return room_id
    if names:
        print("Could not identify the admin room. Joined rooms:", file=sys.stderr)
        for room_id, name in names:
            print(f"  {room_id}  {name!r}", file=sys.stderr)
        print("Re-run with --room-id <id>.", file=sys.stderr)
    else:
        print("No joined rooms found; is this account the first server admin?", file=sys.stderr)
    raise SystemExit(1)


def send(domain: str, token: str, room_id: str, body: str) -> None:
    txn = secrets.token_hex(8)
    path = (f"/_matrix/client/v3/rooms/{urllib.parse.quote(room_id, safe='')}"
            f"/send/m.room.message/{txn}")
    api(domain, "PUT", path, token, {"msgtype": "m.text", "body": body})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain", required=True)
    parser.add_argument("--user", default="")
    parser.add_argument("--password", default=None,
                        help="prefer omitting this; the script prompts instead")
    parser.add_argument("--token", default="", help="admin access token")
    parser.add_argument("--room-id", default="", help="admin room ID")
    parser.add_argument("--bridges", default="")
    parser.add_argument("--repo", default=str(ROOT))
    args = parser.parse_args()

    bridges = [b.strip() for b in args.bridges.split(",") if b.strip()]
    if not bridges:
        raise SystemExit("--bridges is empty")

    token = args.token or (login(args.domain, args.user, args.password)
                           if args.user else "")
    if not token:
        raise SystemExit("provide --token or --user")

    room_id = args.room_id or find_admin_room(args.domain, token)
    print(f"Admin room: {room_id}")

    for bridge in bridges:
        reg = Path(args.repo) / "bridges" / bridge / "registration.yaml"
        if not reg.is_file():
            print(f"warning: {reg} not found, skipping {bridge}", file=sys.stderr)
            continue
        yaml_text = reg.read_text(encoding="utf-8").strip()
        body = f"!admin appservices register\n```\n{yaml_text}\n```"
        send(args.domain, token, room_id, body)
        print(f"Sent registration for {bridge}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
