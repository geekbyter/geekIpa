#!/usr/bin/env python3
"""Preflight gates for the geekIpa Xcode build.

These checks run on the CI runner *before* xcodebuild so obvious mistakes
fail fast with a concise, actionable message. They are intentionally
read-only with respect to source files.
"""
from __future__ import annotations

import glob
import os
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "geekIpa"
FAILURES: list[str] = []


def fail(msg: str) -> None:
    FAILURES.append(msg)


def ok(msg: str) -> None:
    print(f"  OK   {msg}")


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        ok(name)
    else:
        fail(f"{name}" + (f" — {detail}" if detail else ""))


def require_file(rel: str) -> None:
    check(f"required file exists: {rel}", (ROOT / rel).exists())


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="ignore")


def main() -> int:
    print("== geekIpa preflight ==")

    # ---- Required project resources (these caused real CI failures) ----
    for rel in [
        "geekIpa.xcodeproj/project.pbxproj",
        "geekIpa.xcconfig",
        "geekIpa/Resources/Info.plist",
        "geekIpa/Supporting Files/geekIpa.entitlements",
        "geekIpa/Supporting Files/geekIpa-Bridging-Header.h",
        "geekIpa/Resources/Launch Screen.storyboard",
        "geekIpa/Resources/Assets.xcassets",
        "geekIpa/Resources/ellekit.deb",
    ]:
        require_file(rel)

    # ---- Local Swift packages ----
    for pkg in ["AltSign", "Zsign", "NimbleKit", "IDeviceKitten"]:
        check(f"local package has Package.swift: {pkg}", (ROOT / pkg / "Package.swift").exists())

    # ---- pbxproj structural sanity + referenced paths ----
    pbx_path = ROOT / "geekIpa.xcodeproj" / "project.pbxproj"
    pbx = read(pbx_path)
    check("pbxproj braces balanced", pbx.count("{") == pbx.count("}"),
          f'{pbx.count("{")} vs {pbx.count("}")}')
    check("pbxproj parentheses balanced", pbx.count("(") == pbx.count(")"),
          f'{pbx.count("(")} vs {pbx.count(")")}')
    check("deployment target is iOS 16", "IPHONEOS_DEPLOYMENT_TARGET = 16.0;" in pbx)

    for setting, filename in [
        ("INFOPLIST_FILE", "Resources/Info.plist"),
        ("CODE_SIGN_ENTITLEMENTS", "Supporting Files/geekIpa.entitlements"),
        ("SWIFT_OBJC_BRIDGING_HEADER", "Supporting Files/geekIpa-Bridging-Header.h"),
    ]:
        m = re.search(r"(?m)^\s*" + setting + r" = \"?([^\";]+)\"?;", pbx)
        if not m:
            fail(f"{setting} missing in project.pbxproj")
        else:
            rel = m.group(1)
            check(f"{setting} points to an existing file",
                  (ROOT / rel).exists(), rel)

    # ---- Core Data model must match NSPersistentContainer name ----
    models = sorted(APP.glob("Backend/Storage/*.xcdatamodeld"))
    check("exactly one .xcdatamodeld bundle", len(models) == 1,
          ", ".join(str(m.relative_to(ROOT)) for m in models))

    storage_path = APP / "Backend" / "Storage" / "Storage.swift"
    if storage_path.exists():
        storage = read(storage_path)
        m = re.search(r'_name:\s*String\s*=\s*"([^"]+)"', storage)
        if not m:
            fail("Storage.swift does not declare a model name")
        else:
            expected = f"{m.group(1)}.xcdatamodeld"
            check(f"Core Data model name matches container ({expected})",
                  models and models[0].name == expected,
                  f"found {models[0].name if models else 'none'}")
            # .xccurrentversion must point to an existing inner model
            for modeld in models:
                xc = modeld / ".xccurrentversion"
                if xc.exists():
                    cur = read(xc)
                    inner = re.search(r"<string>([^<]+\.xcdatamodel)</string>", cur)
                    if inner:
                        check(".xccurrentversion points to an existing model",
                              (modeld / inner.group(1) / "contents").exists(),
                              inner.group(1))
                # Each model dir should have a contents file
                for inner_dir in modeld.glob("*.xcdatamodel"):
                    check(f"model contents exists: {inner_dir.name}",
                          (inner_dir / "contents").exists())

    # ---- Info.plist + entitlements ----
    plist_path = APP / "Resources" / "Info.plist"
    try:
        with plist_path.open("rb") as fh:
            plist = plistlib.load(fh)
        bg = plist.get("BGTaskSchedulerPermittedIdentifiers", [])
        check("BGTaskScheduler identifiers are not wildcards",
              all(not str(i).endswith(".*") for i in bg), str(bg))
    except Exception as exc:  # noqa: BLE001
        fail(f"Info.plist cannot be parsed: {exc}")

    ent_path = APP / "Supporting Files" / "geekIpa.entitlements"
    if ent_path.exists():
        ent = read(ent_path)
        # get-task-allow must not ship in a release-signed app
        check("entitlements do not contain get-task-allow=true",
              not re.search(r"<key>get-task-allow</key>\s*<true\s*/>", ent))

    # ---- Swift source sanity ----
    swift_files = list(APP.rglob("*.swift"))
    check("Swift sources present", len(swift_files) > 0, str(len(swift_files)))

    mains = []
    color_hex_defs = []
    for path in swift_files:
        text = read(path)
        if "@main" in text:
            mains.append(path.relative_to(ROOT).as_posix())
        if re.search(r"\binit\(hex:", text):
            color_hex_defs.append(path.relative_to(ROOT).as_posix())

        # Section(header:/footer:) before the content closure is invalid
        for idx, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if re.match(r"Section\(\s*(header:|footer:)", stripped):
                fail(f"invalid Section argument order at {path.relative_to(ROOT)}:{idx}")
            if "fatalError(" in stripped and not stripped.startswith("//"):
                fail(f"fatalError in production code at {path.relative_to(ROOT)}:{idx}")

    check("exactly one @main entry point", len(mains) == 1, ", ".join(mains))
    check("Color init(hex:) defined exactly once", len(color_hex_defs) == 1,
          ", ".join(color_hex_defs))

    if FAILURES:
        print("\n== Preflight FAILED ==")
        for item in FAILURES:
            print(f"  - {item}")
        return 1

    print(f"\n== Preflight passed ({len(swift_files)} Swift files) ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
