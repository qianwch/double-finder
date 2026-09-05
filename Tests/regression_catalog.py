#!/usr/bin/env python3
"""Builds Tests/REGRESSION.md — the full regression test catalogue — from the
XCTest sources. Each suite's and case's description is the `///` doc comment
that precedes it in the source, so keeping those comments meaningful keeps
the catalogue meaningful.

    python3 Tests/regression_catalog.py > Tests/REGRESSION.md
"""
import glob
import os
import re

TESTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "double-finderTests")

GROUPS = [
    ("归档 / 压缩包", ["Archive", "Zip", "SevenZip", "Rar", "Solid", "Extract", "Encrypted",
                       "Pack", "VolumeSize", "FileSplit", "LibArchive", "SplitVol"]),
    ("远端：SFTP / S3 / Android(MTP) / 连接", ["S3", "SFTP", "Sftp", "Remote", "Android", "MTP", "Mtp",
                                             "Connect", "Ssh", "SSH", "Bonjour", "Smb", "SMB"]),
    ("文件操作 / 传输 / 队列 / 同步", ["FileOperation", "Transfer", "Queue", "Sync", "Delete", "Copy",
                                     "Move", "Conflict", "Rename", "Checksum", "Attribute"]),
    ("面板 / 列表 / 视图 / 搜索", ["Panel", "FileList", "Column", "Sort", "Filter", "Search", "Find",
                                  "Branch", "Icon", "Row", "Selection", "Drive", "Tab", "Favorite", "History"]),
    ("Lister 查看器 / 渲染", ["Lister", "Viewer", "Markdown", "Syntax", "Diagram", "Mermaid",
                             "PlantUML", "Highlight", "Hex"]),
    ("设置 / 快捷键 / 本地化 / 其它", []),
]


def group_of(name):
    for group, keys in GROUPS:
        if any(k in name for k in keys):
            return group
    return GROUPS[-1][0]


def collect():
    """[(file, suite, suite_doc, [(case, case_doc), …]), …] in source order."""
    suites = []
    for path in sorted(glob.glob(os.path.join(TESTS, "*.swift"))):
        current = None
        pending = []
        for line in open(path, encoding="utf-8"):
            st = line.strip()
            m = re.match(r"(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", st)
            if m:
                current = [os.path.basename(path), m.group(1), " ".join(pending), []]
                suites.append(current)
                pending = []
                continue
            if st.startswith("///"):
                pending.append(st[3:].strip())
                continue
            m = re.match(r"func\s+(test\w+)\s*\(", st)
            if m and current:
                current[3].append((m.group(1), " ".join(pending)))
            pending = []
    return suites


def main():
    suites = collect()
    cases = sum(len(s[3]) for s in suites)
    out = [
        "# Double Finder 全量回归测试用例清单",
        "",
        f"自动从 `Tests/double-finderTests/*.swift` 提取（{len(suites)} 个测试类，{cases} 个用例）。"
        "每个用例的说明取自源码中紧邻的 `///` 注释；没有注释的只列名称。",
        "重新生成：`python3 Tests/regression_catalog.py > Tests/REGRESSION.md`。",
        "",
        "运行方式：",
        "",
        "```bash",
        "swift test                              # 全量（跑在真实 UserDefaults + 钥匙串上，先 defaults export 备份）",
        "swift test --filter SevenZipEngineTests # 单个测试类",
        "```",
        "",
        "带 Live 后缀 / 需要外部工具的测试在条件不满足时自动 `XCTSkip`：远端 live 测试要设 "
        "`DF_KEYCHAIN_LIVE=1`、`ANDROID_LIVE=1` 等环境变量并有真实设备；`RarVolumeTests` 需要 `brew install rar`。",
        "",
    ]
    by_group = {}
    for suite in suites:
        by_group.setdefault(group_of(suite[1]), []).append(suite)
    for group, _ in GROUPS:
        if group not in by_group:
            continue
        out += [f"## {group}", ""]
        for file, name, doc, cases_ in by_group[group]:
            out.append(f"### `{name}` — {file}")
            if doc:
                out += ["", doc]
            out += ["", "| 用例 | 覆盖点 |", "|---|---|"]
            for case, case_doc in cases_:
                out.append(f"| `{case}` | {case_doc.replace('|', '\\|') if case_doc else '—'} |")
            out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
