#!/usr/bin/env python3
"""
SQX MQL5 GV_DISABLE patcher (cross-platform / Linux-friendly).

Patches StrategyQuant-exported .mq5 files so they respect the
`HCPropsControllerDisableTrading` global variable that HCPropsController sets
when a risk limit or a news window blocks trading. A patched EA stops opening
new positions while that flag is 1.0, instead of immediately re-opening what
HCPropsController just closed.

This is the non-Windows equivalent of `Patch-SQX-GV-Disable.ps1`; both inject
the exact same line of MQL5 code.

What it injects (at the very start of `bool sqHandleTradingOptions()`):

    // Check global variable to disable trading
    if(GlobalVariableGet("HCPropsControllerDisableTrading") == 1.0) return false;

Usage
-----
  # 1) In-place: patch a single file or every .mq5 in a folder (recursive).
  #    A .backup copy is made before each file is modified.
  python3 patch-gv-disable.py /path/to/Experts
  python3 patch-gv-disable.py /path/to/MyEA.mq5

  # 2) Mirror: copy SRC into DST, patching the .mq5 on the way.
  #    Originals in SRC are never touched; DST becomes a full mirror.
  python3 patch-gv-disable.py /path/to/MQL5 /path/to/MQL5_Patched

Files that are already patched, or that have no sqHandleTradingOptions()
function, are left/copied unchanged so the output is always complete.
Exit code is 1 if any file errored, 0 otherwise.
"""

import re
import shutil
import sys
from pathlib import Path

FUNCTION_SIGNATURE = "bool sqHandleTradingOptions()"
ALREADY_PATCHED_MARKER = "HCPropsControllerDisableTrading"
PATCH_PATTERN = re.compile(r"(bool\s+sqHandleTradingOptions\s*\(\s*\)\s*\{)")


def patch_content(content: str):
    """Returns (status, new_content). Statuses: Patched, AlreadyPatched,
    NoSignature, PatternNotFound."""
    if FUNCTION_SIGNATURE not in content:
        return "NoSignature", content
    if ALREADY_PATCHED_MARKER in content:
        return "AlreadyPatched", content
    if not PATCH_PATTERN.search(content):
        return "PatternNotFound", content

    # Preserve the file's existing line-ending convention
    nl = "\r\n" if "\r\n" in content else "\n"
    check_code = (
        f"{nl}"
        f"   // Check global variable to disable trading{nl}"
        f"   if(GlobalVariableGet(\"HCPropsControllerDisableTrading\") == 1.0) return false;{nl}"
    )
    # Lambda replacement avoids backslash/group interpretation in the inserted code
    new_content = PATCH_PATTERN.sub(lambda m: m.group(1) + check_code, content, count=1)
    return "Patched", new_content


def read_mq5(path: Path):
    """Read an .mq5 file as text. SQX exports UTF-8; tolerate a BOM. Returns
    None if the file is not UTF-8 (e.g. UTF-16) so the caller can copy it as-is
    instead of crashing."""
    try:
        return path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        return None


def process_inplace(targets):
    patched = skipped = errors = 0
    for i, src in enumerate(targets, 1):
        print(f"[{i}/{len(targets)}] {src.name}")
        try:
            content = read_mq5(src)
            if content is None:
                print("  [!] Not UTF-8, left untouched")
                skipped += 1
                continue
            status, new_content = patch_content(content)
            if status == "Patched":
                backup = src.with_suffix(src.suffix + ".backup")
                shutil.copy2(src, backup)
                src.write_bytes(new_content.encode("utf-8"))
                print(f"  [OK] Patched (backup: {backup.name})")
                patched += 1
            elif status == "AlreadyPatched":
                print("  [!] Already patched")
                skipped += 1
            elif status == "NoSignature":
                print("  [!] No sqHandleTradingOptions()")
                skipped += 1
            else:
                print("  [ERROR] Signature found but the pattern did not match")
                errors += 1
        except Exception as e:  # noqa: BLE001
            print(f"  [ERROR] {e}")
            errors += 1
    return patched, skipped, errors


def process_mirror(src_dir: Path, dst_dir: Path, files):
    patched = copied = errors = 0
    for i, src in enumerate(files, 1):
        rel = src.relative_to(src_dir)
        dst = dst_dir / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        print(f"[{i}/{len(files)}] {rel}")
        try:
            content = read_mq5(src)
            if content is None:
                shutil.copy2(src, dst)
                print("  [!] Not UTF-8, copied as-is")
                copied += 1
                continue
            status, new_content = patch_content(content)
            if status == "Patched":
                dst.write_bytes(new_content.encode("utf-8"))
                print("  [OK] Patched and saved to destination")
                patched += 1
            else:
                shutil.copy2(src, dst)
                reason = {"AlreadyPatched": "already patched",
                          "NoSignature": "no sqHandleTradingOptions()",
                          "PatternNotFound": "pattern did not match"}.get(status, status)
                print(f"  [!] Copied as-is ({reason})")
                copied += 1
        except Exception as e:  # noqa: BLE001
            print(f"  [ERROR] {e}")
            errors += 1
    return patched, copied, errors


def main():
    args = sys.argv[1:]
    if not args or len(args) > 2:
        print(__doc__)
        sys.exit(2)

    print("=" * 60)
    print("  SQX MQL5 Patcher (GV_DISABLE)  ->  HCPropsController")
    print("=" * 60)

    src = Path(args[0]).expanduser().resolve()

    # ---- Mirror mode: SRC_DIR DST_DIR ----
    if len(args) == 2:
        dst = Path(args[1]).expanduser().resolve()
        if not src.is_dir():
            print(f"ERROR: the source is not a folder: {src}", file=sys.stderr)
            sys.exit(1)
        files = sorted(src.rglob("*.mq5"))
        if not files:
            print(f"WARNING: no .mq5 found in {src}")
            sys.exit(0)
        print(f"  Mode: MIRROR\n  Source:      {src}\n  Destination: {dst}\n")
        dst.mkdir(parents=True, exist_ok=True)
        patched, copied, errors = process_mirror(src, dst, files)
        label_b = "Copied unchanged"
        b = copied
    # ---- In-place mode: PATH (file or dir) ----
    else:
        if src.is_file():
            if src.suffix.lower() != ".mq5":
                print(f"ERROR: not a .mq5 file: {src}", file=sys.stderr)
                sys.exit(1)
            targets = [src]
        elif src.is_dir():
            targets = sorted(src.rglob("*.mq5"))
            if not targets:
                print(f"WARNING: no .mq5 found in {src}")
                sys.exit(0)
        else:
            print(f"ERROR: the path does not exist: {src}", file=sys.stderr)
            sys.exit(1)
        print(f"  Mode: IN-PLACE (with .backup backup)\n  Path: {src}\n")
        patched, b, errors = process_inplace(targets)
        label_b = "Skipped"

    print()
    print("=" * 60)
    print("                    SUMMARY")
    print("=" * 60)
    print(f"  [OK]    Patched:           {patched}")
    print(f"  [!]     {label_b + ':':<18}{b}")
    print(f"  [ERROR] Errors:            {errors}")
    print("=" * 60)
    if patched:
        print("Done. Compile the patched .mq5 in MetaEditor and use them instead of the originals.")

    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
