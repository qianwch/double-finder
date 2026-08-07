# Vendored Mermaid (`mermaid.min.js`)

捆绑进 `.app` 的官方 Mermaid UMD 构建，用于 Lister markdown 预览里 ` ```mermaid ` 围栏的
**离屏渲染**（`Utils/Lister/DiagramRenderer.swift` 里一个隐藏 `WKWebView` 加载它、跑
`mermaid.render()` 产出 SVG，再回填进主页面；主 `ListerWebView` 的 JS 全程保持关闭，见
`spec/ui.md`）。

- `mermaid.min.js`：官方 npm 包 `mermaid` 的 `dist/mermaid.min.js`（单文件 UMD bundle，浏览器
  可直接 `<script>`/`evaluateJavaScript` 跑，无需打包工具）。
- `LICENSE`：MIT。

## 当前版本

- 11.16.1

## 来源 / 更新方法

走 jsdelivr CDN（`@11` 这种 major-only 标签会重定向到该 major 下的最新版，响应头
`x-jsd-version` 里能看到解析到的确切版本）：

```bash
curl -sI "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js" | grep -i '^x-jsd-version'
# 记下确切版本号，例如 11.16.1，然后固定拉取该版本：
curl -fsSL -o "<repo>/vendor/mermaid/mermaid.min.js" \
  "https://cdn.jsdelivr.net/npm/mermaid@11.16.1/dist/mermaid.min.js"
```

许可证文本同步更新（mermaid 仓库根 `LICENSE`，MIT）：

```bash
curl -fsSL -o "<repo>/vendor/mermaid/LICENSE" \
  "https://raw.githubusercontent.com/mermaid-js/mermaid/develop/LICENSE"
```

升级大版本号前先看 mermaid 的 changelog 有无渲染 API（`mermaid.initialize`/`mermaid.render`）
破坏性变更，再同步改 `package_app.sh` 里的 `MERMAID_VER`。

`package_app.sh` 打包时会把这个 `mermaid.min.js` 复制进 `Contents/Resources/mermaid.min.js`
（不走 SwiftPM 资源机制，与捆绑 7zz 同一套路：固定相对路径，运行时
`DiagramRenderer.mermaidJSPath()` 按 `Bundle.main.resourcePath` 解析）。

> **开发裸跑**（不打 .app）时没有捆绑资源，`DiagramSupport.devVendorPath()` 会探测仓库根的
> `vendor/mermaid/mermaid.min.js`（需要手工 `curl` 到位，见上）；两处都没有则 mermaid 块保留
> 代码块 + "Mermaid 渲染器不可用——已显示源码" 提示，不弹框。
