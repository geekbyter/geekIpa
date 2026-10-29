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
    tip = hint_for(msg)
    FAILURES.append(msg + (f"\n       修复: {tip}" if tip else ""))


def ok(msg: str) -> None:
    print(f"  OK   {msg}")


# 失败时附带的修复提示（按检查名关键词匹配）
HINTS = [
    ("required file exists", "补齐该文件，或从 git 恢复：git checkout -- <path>"),
    ("local package has Package.swift", "本地包目录缺失：git checkout -- <pkg>/ 或确认未被误删"),
    ("local package path exists", "pbxproj 引用了不存在的包目录：删除该 XCLocalSwiftPackageReference"),
    ("workspace ref exists", "workspace 引用了已删除路径：编辑 geekIpa.xcworkspace/contents.xcworkspacedata 删掉该 FileRef"),
    ("sync group dir exists", "同步组路径不存在：确认 PBXFileSystemSynchronizedRootGroup 的 path 与磁盘一致"),
    ("braces balanced", "pbxproj 结构被破坏：从 git 恢复 project.pbxproj 重新编辑"),
    ("parentheses balanced", "同上"),
    ("INFOPLIST_FILE", "工程里的 INFOPLIST_FILE 指向不存在的文件：核对 geekIpa/Resources/Info.plist 路径"),
    ("CODE_SIGN_ENTITLEMENTS", "entitlements 路径不存在：核对 Supporting Files/geekIpa.entitlements"),
    ("SWIFT_OBJC_BRIDGING_HEADER", "桥接头路径不存在：核对 Supporting Files/geekIpa-Bridging-Header.h"),
    ("xcdatamodeld", "模型目录必须与 NSPersistentContainer(name:) 同名；旧目录要从磁盘和 git 一起删"),
    ("Core Data model name", "把 Storage.swift 的 _name 与 .xcdatamodeld 目录名改成一致"),
    ("BGTaskScheduler", "Info.plist 的 BGTaskSchedulerPermittedIdentifiers 必须是精确标识符，不能含 *"),
    ("NSLocalNetworkUsageDescription", "补 Info.plist: NSLocalNetworkUsageDescription（安装服务器需要本地网络）"),
    ("ATS allows local networking", "补 Info.plist: NSAppTransportSecurity → NSAllowsLocalNetworking = true"),
    ("get-task-allow", "生产包不应带调试权限：entitlements 里删掉 get-task-allow"),
    ("removed package", "该依赖已改为自研/移除：不要把 import 或 package 引用加回来"),
    ("LocalHTTPServer", "自研 HTTP 服务缺失：恢复 geekIpa/Backend/Server/LocalHTTPServer.swift"),
    ("@main", "必须且只能有一个 @main 入口"),
    ("init(hex:)", "Color(hex:) 只能有一处定义（Extensions/Color+Hex.swift）"),
    ("Section argument order", "Section 的内容闭包必须在最前：Section { } header: { } footer: { }"),
    ("fatalError", "生产代码禁止 fatalError，请改为降级处理"),
]


def hint_for(name: str) -> str:
    for key, tip in HINTS:
        if key in name:
            return tip
    return ""


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        ok(name)
    else:
        msg = name + (f" — {detail}" if detail else "")
        tip = hint_for(name)
        if tip:
            msg += f"\n       修复: {tip}"
        fail(msg)


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
        "geekIpa/Resources/ellekit.bin",
    ]:
        require_file(rel)

    # ---- Local Swift packages（IDeviceKitten 已移除，不再要求）----
    for pkg in ["AltSign", "Zsign", "NimbleKit"]:
        check(f"local package has Package.swift: {pkg}", (ROOT / pkg / "Package.swift").exists())

    pbx_path = ROOT / "geekIpa.xcodeproj" / "project.pbxproj"
    pbx = read(pbx_path)

    # ---- 本地包引用必须指向真实存在的目录 ----
    for m in re.finditer(r'XCLocalSwiftPackageReference[^}]*?relativePath = ([^;]+);', pbx, re.S):
        rel = m.group(1).strip().strip('"')
        check(f"local package path exists: {rel}", (ROOT / rel).is_dir())

    # ---- workspace 不得引用不存在的路径 ----
    ws_path = ROOT / "geekIpa.xcworkspace" / "contents.xcworkspacedata"
    if ws_path.exists():
        ws = read(ws_path)
        for m in re.finditer(r'location = "(?:group|container):([^"]+)"', ws):
            name = m.group(1)
            check(f"workspace ref exists: {name}", (ROOT / name).exists())

    # ---- 同步组目录存在 ----
    for m in re.finditer(r'PBXFileSystemSynchronizedRootGroup[^}]*?path = ([^;]+);', pbx, re.S):
        rel = m.group(1).strip().strip('"')
        check(f"sync group dir exists: {rel}", (ROOT / rel).is_dir())

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
    # 全仓库递归查找：残留的重复模型会让 Xcode 产出两份 momd
    models = sorted(
        p for p in ROOT.rglob("*.xcdatamodeld")
        if "debug" not in p.relative_to(ROOT).parts
        and not any(part.startswith(".") for part in p.relative_to(ROOT).parts)
    )

    storage_path = APP / "Backend" / "Storage" / "Storage.swift"
    expected_model = None
    if storage_path.exists():
        storage = read(storage_path)
        m = re.search(r'_name:\s*String\s*=\s*"([^"]+)"', storage)
        if not m:
            fail("Storage.swift does not declare a model name")
        else:
            expected_model = f"{m.group(1)}.xcdatamodeld"

    if expected_model is not None:
        stale = [md for md in models if md.name != expected_model]
        if len(models) > 1:
            fail(
                "duplicated Core Data model bundles: "
                + ", ".join(md.name for md in models)
                + f". Keep only {expected_model} (matches NSPersistentContainer(name:)). "
                "Remove the stale copies from disk AND from git, e.g.: "
                + " ".join(f"git rm -r --cached --ignore-unmatch '{md.relative_to(ROOT).as_posix()}'"
                           for md in stale)
            )
        else:
            check("exactly one .xcdatamodeld bundle", len(models) == 1,
                  ", ".join(md.name for md in models))

        matching = [md for md in models if md.name == expected_model]
        check(f"Core Data model name matches container ({expected_model})",
              bool(matching),
              "found " + (", ".join(md.name for md in models) if models else "none"))

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

    # ---- 资源打包 / 链接规则 ----
    # .deb 的 UTI 属于 archive，一旦成为 target 成员会被 Xcode 推断进
    # Link Binary With Libraries 阶段，链接时报
    #   archive member 'debian-binary' not a mach-o file
    # 因此打包资源统一用 .bin，运行时再落盘成 .deb 交给解析器。
    stray_debs = [p.relative_to(ROOT).as_posix() for p in APP.rglob("*.deb")]
    check("app 目录内不存在 .deb（会被链接器当静态库）", not stray_debs, str(stray_debs))
    check("ellekit 资源以 .bin 打包", (APP / "Resources" / "ellekit.bin").exists())
    check("LIBRARY_SEARCH_PATHS 不再指向 Resources 目录",
          "$(PROJECT_DIR)/geekIpa/Resources" not in pbx,
          "残留的 -L 路径会让 ld 扫描资源目录")

    # ---- 代码引用的 Bundle 资源必须存在 ----
    swift_files = list(APP.rglob("*.swift"))
    resource_refs = set()
    for path in swift_files:
        text = read(path)
        for m in re.finditer(r'url\(forResource:\s*"([^"]+)"\s*,\s*withExtension:\s*"([^"]*)"', text):
            name, ext = m.group(1), m.group(2)
            resource_refs.add((f"{name}.{ext}" if ext else name, path))
        for m in re.finditer(r'url\(forResource:\s*"([^"]+)"\s*,\s*withExtension:\s*nil\)', text):
            resource_refs.add((m.group(1), path))

    for fname, path in sorted(resource_refs):
        hits = [p for p in APP.rglob(fname)]
        where = path.relative_to(ROOT).as_posix()
        check(f"Bundle 资源存在: {fname}", bool(hits), f"{where} 引用了它")

    # ---- Info.plist + entitlements ----
    plist_path = APP / "Resources" / "Info.plist"
    try:
        with plist_path.open("rb") as fh:
            plist = plistlib.load(fh)
        bg = plist.get("BGTaskSchedulerPermittedIdentifiers", [])
        check("BGTaskScheduler identifiers are not wildcards",
              all(not str(i).endswith(".*") for i in bg), str(bg))

        # 安装链路依赖局域网 HTTP：缺这两项 iOS 会拦掉
        check("Info.plist has NSLocalNetworkUsageDescription",
              bool(plist.get("NSLocalNetworkUsageDescription")))
        ats = plist.get("NSAppTransportSecurity") or {}
        check("ATS allows local networking (http://<LAN-IP>)",
              bool(ats.get("NSAllowsLocalNetworking")))
    except Exception as exc:  # noqa: BLE001
        fail(f"Info.plist cannot be parsed: {exc}")

    ent_path = APP / "Supporting Files" / "geekIpa.entitlements"
    if ent_path.exists():
        ent = read(ent_path)
        # get-task-allow must not ship in a release-signed app
        check("entitlements do not contain get-task-allow=true",
              not re.search(r"<key>get-task-allow</key>\s*<true\s*/>", ent))

    # ---- 依赖收敛：这些包已自主实现/移除，禁止回退 ----
    swift_files = list(APP.rglob("*.swift"))
    for banned in ["Vapor", "vapor", "Nuke", "NukeUI", "AltSourceKit", "IDeviceSwift", "IDeviceKitten"]:
        if banned in pbx:
            fail(f"project.pbxproj still references removed package: {banned}")
    for banned_import in ["import Vapor", "import NIOSSL", "import NIOTLS", "import Nuke", "import AltSourceKit", "import IDeviceSwift"]:
        for path in swift_files:
            if banned_import in read(path):
                fail(f"{banned_import} found in {path.relative_to(ROOT).as_posix()}")
    check("LocalHTTPServer.swift exists (self-implemented HTTP)",
          (APP / "Backend" / "Server" / "LocalHTTPServer.swift").exists())

    # ---- Swift source sanity ----
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
