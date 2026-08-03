#!/usr/bin/env python3
"""Edit Raspberry Pi config.txt while preserving comments and repeated keys."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


DEFAULT_CONFIG = "/boot/firmware/config.txt"


@dataclass
class ParsedLine:
    text: str
    key: str | None = None
    value: str | None = None
    section: str | None = None
    commented: bool = False


def parse_line(line: str) -> ParsedLine:
    body = line.rstrip("\n")
    stripped = body.strip()

    if stripped.startswith("[") and stripped.endswith("]") and len(stripped) >= 3:
        return ParsedLine(text=body, section=stripped[1:-1].strip())

    left = body.lstrip()
    commented = False
    if left.startswith("#"):
        commented = True
        left = left[1:].lstrip()

    if "=" not in left or not left.strip() or left.strip().startswith("#"):
        return ParsedLine(text=body)

    key, value = left.split("=", 1)
    key = key.strip()
    value = value.strip()
    if not key:
        return ParsedLine(text=body)

    return ParsedLine(text=body, key=key, value=value, commented=commented)


def read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return path.read_text(encoding="utf-8").splitlines()


def atomic_write(path: Path, lines: list[str], backup: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if backup and path.exists():
        shutil.copy2(path, path.with_suffix(path.suffix + ".bak"))

    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
            f.write("\n")
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def section_bounds(lines: list[str], section: str) -> tuple[int | None, int | None]:
    start = None
    end = None
    for i, line in enumerate(lines):
        parsed = parse_line(line)
        if parsed.section is None:
            continue
        if start is not None:
            end = i
            break
        if parsed.section == section:
            start = i
    if start is not None and end is None:
        end = len(lines)
    return start, end


def first_section_index(lines: list[str]) -> int:
    for i, line in enumerate(lines):
        if parse_line(line).section is not None:
            return i
    return len(lines)


def iter_range(lines: list[str], section: str | None) -> tuple[int, int]:
    if section is None:
        return 0, first_section_index(lines)
    start, end = section_bounds(lines, section)
    if start is None or end is None:
        return -1, -1
    return start + 1, end


def ensure_section(lines: list[str], section: str) -> tuple[int, int]:
    start, end = section_bounds(lines, section)
    if start is not None and end is not None:
        return start + 1, end
    if lines and lines[-1] != "":
        lines.append("")
    lines.append(f"[{section}]")
    return len(lines), len(lines)


def assignment_body(line: str) -> tuple[str, bool] | tuple[None, bool]:
    body = line.rstrip("\n")
    left = body.lstrip()
    commented = False
    if left.startswith("#"):
        commented = True
        left = left[1:].lstrip()
    if not left or left.startswith("#") or "=" not in left:
        return None, commented
    return left.strip(), commented


def cli_key_matches(line: str, key: str) -> bool:
    """Match keys that may themselves contain '=', e.g. dtparam=i2c_arm."""
    if "=" not in key:
        return parse_line(line).key == key
    body, _ = assignment_body(line)
    return body is not None and body.startswith(f"{key}=")


def set_key(lines: list[str], key: str, value: str, section: str | None = None) -> list[str]:
    target = f"{key}={value}"
    start, end = iter_range(lines, section)
    if section is not None and start == -1:
        start, end = ensure_section(lines, section)

    for i in range(start, end):
        if cli_key_matches(lines[i], key):
            lines[i] = target
            return lines

    insert_at = end
    lines.insert(insert_at, target)
    return lines


def unset_key(lines: list[str], key: str, section: str | None = None) -> list[str]:
    start, end = iter_range(lines, section)
    if start == -1:
        return lines

    for i in range(start, end):
        parsed = parse_line(lines[i])
        if not parsed.commented and (parsed.key == key or cli_key_matches(lines[i], key)):
            lines[i] = "#" + lines[i]
    return lines


def add_pair(lines: list[str], key: str, value: str, section: str | None = None) -> list[str]:
    target = f"{key}={value}"
    start, end = iter_range(lines, section)
    if section is not None and start == -1:
        start, end = ensure_section(lines, section)

    for i in range(start, end):
        parsed = parse_line(lines[i])
        if parsed.key == key and parsed.value == value and not parsed.commented:
            return lines

    lines.insert(end, target)
    return lines


def del_pair(lines: list[str], key: str, value: str, section: str | None = None) -> list[str]:
    start, end = iter_range(lines, section)
    if start == -1:
        return lines

    out: list[str] = []
    for i, line in enumerate(lines):
        if start <= i < end:
            parsed = parse_line(line)
            if parsed.key == key and parsed.value == value:
                continue
        out.append(line)
    return out


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Edit Raspberry Pi config.txt keys, sections, and repeated key=value entries."
    )
    parser.add_argument(
        "-f",
        "--file",
        default=os.environ.get("RPI_CONFIG_FILE", DEFAULT_CONFIG),
        help="config.txt path, default: env RPI_CONFIG_FILE or /boot/firmware/config.txt",
    )
    parser.add_argument("--no-backup", action="store_true", help="do not create .bak backup")

    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("set", help="set first key occurrence globally, or append if missing")
    p.add_argument("key")
    p.add_argument("value")

    p = sub.add_parser("unset", help="comment all matching key occurrences globally")
    p.add_argument("key")

    p = sub.add_parser("add", help="add key=value globally if exact active line is missing")
    p.add_argument("key")
    p.add_argument("value")

    p = sub.add_parser("del", help="delete exact key=value globally, including commented matches")
    p.add_argument("key")
    p.add_argument("value")

    p = sub.add_parser("section-set", aliases=["key-set"], help="set key=value inside section")
    p.add_argument("section")
    p.add_argument("key")
    p.add_argument("value")

    p = sub.add_parser("section-unset", aliases=["key-unset"], help="comment key inside section")
    p.add_argument("section")
    p.add_argument("key")

    p = sub.add_parser("section-add", aliases=["key-add"], help="add key=value inside section")
    p.add_argument("section")
    p.add_argument("key")
    p.add_argument("value")

    p = sub.add_parser("section-del", aliases=["key-del"], help="delete exact key=value inside section")
    p.add_argument("section")
    p.add_argument("key")
    p.add_argument("value")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    path = Path(args.file)
    lines = read_lines(path)

    if args.command == "set":
        lines = set_key(lines, args.key, args.value)
    elif args.command == "unset":
        lines = unset_key(lines, args.key)
    elif args.command == "add":
        lines = add_pair(lines, args.key, args.value)
    elif args.command == "del":
        lines = del_pair(lines, args.key, args.value)
    elif args.command in ("section-set", "key-set"):
        lines = set_key(lines, args.key, args.value, args.section)
    elif args.command in ("section-unset", "key-unset"):
        lines = unset_key(lines, args.key, args.section)
    elif args.command in ("section-add", "key-add"):
        lines = add_pair(lines, args.key, args.value, args.section)
    elif args.command in ("section-del", "key-del"):
        lines = del_pair(lines, args.key, args.value, args.section)
    else:
        raise SystemExit(f"unknown command: {args.command}")

    atomic_write(path, lines, backup=not args.no_backup)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())