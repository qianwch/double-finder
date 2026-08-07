# Vendored PlantUML (`plantuml.jar`, MIT edition)

捆绑进 `.app` 的官方 PlantUML jar，用于 Lister markdown 预览里 ` ```plantuml ` / ` ```puml `
围栏的渲染——本机起子进程 `java -jar plantuml.jar -tsvg -pipe`，源码从 stdin 喂、SVG 从
stdout 收，不联网（`Utils/Lister/DiagramRenderer.swift` + `Utils/PlantUML.swift`，见
`spec/ui.md`）。

- `plantuml.jar`：官方 GitHub release 的 **MIT edition**（资产名 `plantuml-mit-<ver>.jar`）。
- `LICENSE`：MIT（`plantuml-mit` 子模块的 `mit-license.txt`）。

## 为什么不用默认版（GPL）

PlantUML 的 GitHub release 里默认资产 `plantuml.jar` / `plantuml-gplv2-<ver>.jar` 是 GPLv2
授权（其余还有 LGPL / EPL / BSD 等多个 edition）。Double Finder 是 Apache-2.0 开源项目，随附
分发 GPL 组件会引入不必要的授权兼容性问题；官方专门提供了 **`plantuml-mit-<ver>.jar`**
（与其它 edition 功能等价，只是依赖组合限定为 MIT 兼容的库），随附这个不给整体授权添麻烦，
与 THIRD-PARTY.md 的其它条目（libarchive BSD-2-Clause、7-Zip LGPL 但作为独立子进程调用）
口径一致。

## 需要系统 Java

`plantuml.jar` 只是字节码，**不含 JRE**——Double Finder 不捆绑 JRE（明确不做，见
`spec/roadmap.md`）。运行时靠 `/usr/libexec/java_home` 探测一个可用的 Java（`/usr/bin/java`
在没装 JDK 的机器上也存在、只是个提示装 JDK 的桩，不能只测文件存在性，见 `Utils/PlantUML.swift`）。
本机没有 Java 时 plantuml 块保留代码块 + "PlantUML 渲染需要 Java——已显示源码" 提示，不弹框。

## 当前版本

- 1.2026.6

## 来源 / 更新方法

```bash
curl -s "https://api.github.com/repos/plantuml/plantuml/releases/latest" \
  | grep -o '"name": *"plantuml-mit-[^"]*jar"'   # 确认资产名与版本号，排除 -javadoc/-sources 变体

ver="1.2026.6"
curl -fsSL -o "<repo>/vendor/plantuml/plantuml.jar" \
  "https://github.com/plantuml/plantuml/releases/download/v${ver}/plantuml-mit-${ver}.jar"
```

许可证文本同步更新（PlantUML 仓库 `plantuml-mit/mit-license.txt`，随 jar 内 `META-INF` 附带的
同一份文本）：

```bash
curl -fsSL -o "<repo>/vendor/plantuml/LICENSE" \
  "https://raw.githubusercontent.com/plantuml/plantuml/master/plantuml-mit/mit-license.txt"
```

若某个版本官方**没有**提供 MIT edition 资产，退而求其次用 `plantuml-asl-<ver>.jar`
（Apache-2.0）——**绝不用默认/GPL 版**。换用 ASL 版时要同步改这份 README、
`package_app.sh` 里的资产名与注释、`THIRD-PARTY.md` 的许可描述，三处都不能漏。

`package_app.sh` 打包时会把这个 `plantuml.jar` 复制进 `Contents/Resources/plantuml.jar`
（不走 SwiftPM 资源机制，与捆绑 7zz 同一套路：固定相对路径，运行时
`PlantUML.bundledJarPath()` 按 `Bundle.main.resourcePath` 解析）。

> **开发裸跑**（不打 .app）时没有捆绑资源，`DiagramSupport.devVendorPath()` 会探测仓库根的
> `vendor/plantuml/plantuml.jar`（需要手工 `curl` 到位，见上）；两处都没有时会继续尝试
> Homebrew（`brew install plantuml`）与 PATH 上的 `plantuml` 包装脚本，全部找不到才提示
> "未找到 PlantUML——已显示源码"，不弹框。
