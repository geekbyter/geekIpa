#!/usr/bin/env python3
"""按 CI 视角验证「将要推送的那棵树」：把 git 索引导出到临时目录再跑校验。

背景：本地工作区通过检查 ≠ 推送后有检查。若某些文件没被 git 跟踪（例如重命名后
新目录未 add），CI 拿到的树就缺文件。本脚本把索引（= commit 后 CI 看到的内容）
原样导出，然后在那棵树上跑 preflight 与关键资源检查。

用法：
    python Scripts/verify_staged_tree.py        # 需先 git add -A
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(cmd: list[str], cwd: str | None = None) -> tuple[int, str]:
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr)


def main() -> int:
    repo = Path(__file__).resolve().parents[1]

    # 1) 确认有暂存内容
    rc, out = run(["git", "diff", "--cached", "--name-only"], cwd=str(repo))
    staged = [l for l in out.splitlines() if l.strip()]
    if not staged:
        print("暂存区为空。请先执行: git add -A")
        return 2
    print(f"暂存文件数: {len(staged)}")

    tmp = tempfile.mkdtemp(prefix="geekipa_tree_")
    try:
        # 2) 把索引内容物化到临时目录
        rc, out = run(["git", "checkout-index", "-a", "-f", f"--prefix={tmp}/"], cwd=str(repo))
        if rc != 0:
            print("导出索引失败：")
            print(out[:2000])
            return 2
        files = sum(len(f) for _, _, f in os.walk(tmp))
        print(f"导出的树: {tmp}（{files} 个文件）")

        # 3) 在这棵树上跑 preflight（它的 ROOT 取自脚本位置，故直接指向临时树）
        preflight = os.path.join(tmp, "Scripts", "preflight.py")
        if not os.path.exists(preflight):
            print("临时树里没有 Scripts/preflight.py —— 说明它没被提交！")
            return 1
        rc, out = run([sys.executable, preflight], cwd=tmp)
        tail = "\n".join(out.strip().splitlines()[-6:])
        print("\n=== 临时树 preflight ===")
        print(tail)
        if rc != 0:
            print("\n失败的树就是你将要推送的内容。")
            return 1

        # 4) 关键文件抽查（CI 编译所需）
        required = [
            "geekIpa.xcodeproj/project.pbxproj",
            "geekIpa.xcodeproj/xcshareddata/xcschemes/geekIpa.xcscheme",
            "geekIpa.xcconfig",
            "geekIpa/Resources/Info.plist",
            "geekIpa/Supporting Files/geekIpa.entitlements",
            "geekIpa/Supporting Files/geekIpa-Bridging-Header.h",
            "geekIpa/Utilities/iconPoc.m",
            "geekIpa/Backend/Storage/geekIpa.xcdatamodeld/geekIpa.xcdatamodel/contents",
            "AltSign/Package.swift",
            "Zsign/Package.swift",
            "NimbleKit/Package.swift",
        ]
        missing = [r for r in required if not os.path.exists(os.path.join(tmp, r))]
        swift = sum(1 for dp, _, fns in os.walk(os.path.join(tmp, "geekIpa"))
                    for f in fns if f.endswith(".swift"))
        print(f"\n临时树 Swift 文件数: {swift}")
        if missing:
            print("缺失关键文件：")
            for m in missing:
                print("  -", m)
            return 1
        print("关键文件齐全 ✔")
        print("\n=== 结论：这棵树（= 推送后 CI 看到的内容）自检通过 ===")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
