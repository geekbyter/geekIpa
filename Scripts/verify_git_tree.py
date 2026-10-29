#!/usr/bin/env python3
"""推送前自检：确认 git 里真的有新工程树，而不是只有旧的 GeekSign 树。

用法（在仓库根目录）：
    python Scripts/verify_git_tree.py            # 检查 HEAD（= 将要推送的内容）
    python Scripts/verify_git_tree.py --index    # 检查暂存区（git add 之后、commit 之前）

背景：本项目的目录经历了一次重命名 GeekSign → geekIpa，且依赖被大改。
如果只用 `git commit -am`，新增目录（geekIpa/、geekIpa.xcodeproj/、Scripts/）不会入库，
CI 拉到的仍是旧工程 → Actions 上永远编译失败。
"""
from __future__ import annotations

import subprocess
import sys


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def tree_files(use_index: bool) -> list[str]:
    if use_index:
        out = git("ls-files", "--cached")
    else:
        out = git("ls-tree", "-r", "--name-only", "HEAD")
    return [line.strip() for line in out.splitlines() if line.strip()]


def main() -> int:
    use_index = "--index" in sys.argv
    scope = "暂存区" if use_index else "HEAD"
    files = tree_files(use_index)
    problems: list[str] = []
    notes: list[str] = []

    print(f"== git 树自检（{scope}，共 {len(files)} 个文件）==")

    def has_prefix(prefix: str) -> int:
        return sum(1 for f in files if f.startswith(prefix))

    # 1) 新工程必须存在
    required = {
        "geekIpa.xcodeproj/project.pbxproj": "Xcode 工程",
        "geekIpa.xcodeproj/xcshareddata/xcschemes/geekIpa.xcscheme": "共享 scheme",
        "geekIpa.xcconfig": "构建配置",
        "geekIpa/Resources/Info.plist": "Info.plist",
        "geekIpa/Supporting Files/geekIpa.entitlements": "entitlements",
        "geekIpa/Backend/Server/LocalHTTPServer.swift": "自研 HTTP 服务",
        "geekIpa/Extensions/Color+Hex.swift": "Color(hex:) 扩展",
        "Scripts/preflight.py": "CI 预检脚本",
        ".github/workflows/build.yml": "CI 工作流",
    }
    for path, label in required.items():
        if path not in files:
            problems.append(f"缺少 {label}：{path}")

    # 2) 源码数量
    swift = [f for f in files if f.startswith("geekIpa/") and f.endswith(".swift")]
    if len(swift) < 80:
        problems.append(f"geekIpa/ 下 Swift 文件只有 {len(swift)} 个（应约 82）")

    # 3) 旧工程树必须已删除
    legacy = [
        p for p in ("GeekSign/", "GeekSign.xcodeproj/", "GeekSign.xcworkspace/",
                    "GeekSign.xcconfig", "AltSourceKit/", "IDeviceKitten/")
        if any(f == p.rstrip("/") or f.startswith(p) for f in files)
    ]
    if legacy:
        problems.append("旧工程/已删依赖仍在 git 树里：" + ", ".join(legacy))

    # 4) 残留旧模型
    stale_models = [
        f for f in files
        if "Feather.xcdatamodeld" in f or f.endswith("Feather.xcdatamodel/contents")
    ]
    if stale_models:
        dirs = sorted({m.split("/.xccurrentversion")[0].split("/contents")[0]
                       for m in stale_models})
        problems.append("旧 Core Data 模型仍在树里：" + ", ".join(dirs))
        for d in dirs:
            problems.append(f"  删除命令： git rm -r \"{d}\"")

    # 5) 新模型存在
    if not any("geekIpa.xcdatamodeld" in f for f in files):
        problems.append("缺少 geekIpa.xcdatamodeld（App 启动会崩）")

    # 6) 不该入库的东西
    for bad in ("debug/", "_build/"):
        n = has_prefix(bad)
        if n:
            notes.append(f"注意：{bad} 有 {n} 个文件在树里（建议加入 .gitignore 并移除）")

    print(f"  geekIpa/ Swift 文件: {len(swift)}")
    print(f"  geekIpa/ 全部文件  : {has_prefix('geekIpa/')}")
    for n in notes:
        print("  " + n)

    if problems:
        print("\n== 自检未通过 ==")
        for p in problems:
            print("  - " + p)
        print("\n修复：git add -A   （必须用 -A，确保新增目录与删除都被暂存）")
        return 1

    print("\n== 自检通过：这条提交里确实包含新工程树 ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
