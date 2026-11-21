#!/usr/bin/env python3
"""Decompose a .src.patch that consists only of newly added files into individual
source files, and optionally add them to SRC_URI in a .cygport file.

When cygport applies patches, its patchlevel loop (0..5) erroneously succeeds
at -p0 for patches that only create new files, placing them into
${S}/src/${SRC_DIR}/... instead of the source root ${S}. Decomposing such patches
into individual files in the package directory and listing them in SRC_URI
allows cygport to unpack them directly into ${SRC_DIR}.
"""

import argparse
import os
import re
import sys


def parse_patch(patch_path):
    """Parse patch_path. Returns dict of {rel_path: content} if all hunks
    are new files, or None if any hunk modifies an existing file or no files found."""
    if not os.path.isfile(patch_path):
        return None

    with open(patch_path, "r", errors="replace") as f:
        content = f.read()

    file_patches = re.split(r"\n(?=--- )", content)
    extracted = {}
    has_files = False

    for fp in file_patches:
        if not fp.startswith("--- "):
            continue
        lines = fp.splitlines()
        orig_line = lines[0]
        plus_line = (
            lines[1] if len(lines) > 1 and lines[1].startswith("+++ ") else ""
        )
        if not plus_line:
            continue
        has_files = True

        # Check if the original file is empty / newly created
        # Common diff indicators: /dev/null or 1970-01-01 / 1969-12-31 timestamp
        if not (
            "/dev/null" in orig_line
            or "1970-01-01" in orig_line
            or "1969-12-31" in orig_line
        ):
            return None

        raw_path = plus_line.split()[1]
        # Strip leading diff prefixes: src/<dir>/, origsrc/<dir>/, b/, etc.
        clean_path = re.sub(
            r"^(?:(?:src|origsrc|b)/[^/]+/|(?:src|origsrc|b)/)", "", raw_path
        )

        file_lines = []
        in_hunk = False
        for l in lines[2:]:
            if l.startswith("@@ "):
                in_hunk = True
                continue
            if in_hunk:
                if l.startswith("+"):
                    file_lines.append(l[1:])
                elif l.startswith(r"\ No newline at end of file") or l.startswith(
                    r"\\ No newline at end of file"
                ):
                    pass
        extracted[clean_path] = "\n".join(file_lines) + "\n"

    return extracted if has_files else None


def update_src_uri(cygport_path, new_files):
    if not os.path.isfile(cygport_path):
        return False

    with open(cygport_path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    m = re.search(r'^(SRC_URI=")([^"]*)(")', content, re.M | re.S)
    if not m:
        m = re.search(r"^(SRC_URI=')([^']*)(')", content, re.M | re.S)
        if not m:
            return False

    orig_val = m.group(2).strip()
    words = orig_val.split()
    added = []
    for nf in new_files:
        if nf not in words:
            words.append(nf)
            added.append(nf)

    if not added:
        return True

    new_val = "\n\t".join(words)
    new_block = f'SRC_URI="\n\t{new_val}\n"'
    new_content = content[: m.start()] + new_block + content[m.end() :]
    with open(cygport_path, "w", encoding="utf-8") as f:
        f.write(new_content)
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Decompose new-file-only .src.patch into SRC_URI"
    )
    parser.add_argument("--patch", required=True, help="Path to .src.patch")
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Exit 0 if patch is only new files, 1 otherwise",
    )
    parser.add_argument(
        "--dest", help="Destination directory for decomposed files"
    )
    parser.add_argument(
        "--apply-to",
        action="append",
        default=[],
        help="Additional directories to write decomposed files into",
    )
    parser.add_argument(
        "--cygport", help="Path to .cygport file to update SRC_URI in"
    )
    parser.add_argument(
        "--drop-patch", action="store_true", help="Remove patch file after decomposition"
    )

    args = parser.parse_args()

    extracted = parse_patch(args.patch)
    if extracted is None:
        sys.exit(1)

    if args.check_only:
        sys.exit(0)

    dest_dir = args.dest or os.path.dirname(os.path.abspath(args.patch))
    all_targets = [dest_dir] + args.apply_to

    for target_dir in all_targets:
        if not target_dir:
            continue
        for rel_path, file_content in extracted.items():
            full_path = os.path.join(target_dir, rel_path)
            os.makedirs(os.path.dirname(full_path), exist_ok=True)
            with open(full_path, "w", encoding="utf-8") as f:
                f.write(file_content)

    new_file_names = list(extracted.keys())

    if args.cygport:
        update_src_uri(args.cygport, new_file_names)

    if args.drop_patch and os.path.exists(args.patch):
        os.remove(args.patch)

    print(" ".join(new_file_names))


if __name__ == "__main__":
    main()
