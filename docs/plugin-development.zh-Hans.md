# Double Finder 插件开发指南

Double Finder 的插件机制按 Total Commander 的插件族设计。一个插件就是一个
**`.dfplugin` bundle**——Swift 动态库加一个 `Info.plist`——放进用户的插件目录即可。
插件链接一个公共动态库 **`DoubleFinderPluginKit`**（即 SDK），运行时宿主和所有插件共用同一份。

| 扩展点              | TC 对应 | 提供什么                                                                 |
|---------------------|---------|--------------------------------------------------------------------------|
| `FileSystemPlugin`  | WFX     | 驱动器栏里的一个盘：浏览、F5/F6、F7/F8、改名、F3/F4、同步、查找、拖放      |
| `ViewerPlugin`      | WLX     | Lister（F3）里某类文件的查看模式（第 4 段）                               |
| `PackerPlugin`      | WCX     | 可浏览/解压的压缩格式；可选支持在 ⌥F5 打包里创建                          |
| `ContentPlugin`     | WDX     | 文件列表的自定义列                                                       |
| `CommandPlugin`     | —       | 插件菜单、工具栏、快捷键里的一条命令                                     |

一个插件可以同时提供任意数量的各类扩展。

---

## 1. 上手

### 需要什么

- macOS 13+，Xcode 15+（Swift 5.9 或更新的工具链）。
- SDK：`PluginKit/` 包。可以直接用 Double Finder 源码树里的，也可以用每个
  [GitHub release](https://github.com/qianwch/double-finder/releases) 附带的 `DoubleFinderPluginKit-SDK-<版本>.zip`
  （CI 用 `./package_sdk.sh` 打出）——里面还带模板、脚手架脚本、本文档和示例插件。

> 请用 **路径依赖**（`.package(path:)`）引用 PluginKit。该包通过一个 unsafe 编译标志开启了 library evolution，
> SwiftPM 不允许 URL 拉取的依赖带 unsafe 标志，路径依赖则没有这个限制。

### 用模板生成插件

```bash
Tools/new-plugin.sh MyPlugin com.example.myplugin ~/Developer   # → ~/Developer/MyPlugin
cd ~/Developer/MyPlugin
./build.sh --install       # 构建 → 包成 MyPlugin.dfplugin → 装进用户插件目录
```

`new-plugin.sh` 复制 `Templates/PluginTemplate`，替换名字，并把 `Package.swift` 里的 PluginKit 指向相对路径。

然后启动 Double Finder，或在 设置 ▸ 插件 里点「重新扫描」。不开界面就想知道加载了什么（以及 bundle 被拒的原因）：

```bash
NC_PLUGIN_DIAG=1 "/Applications/Double Finder.app/Contents/MacOS/Double Finder"
```

### 安装位置

- `~/Library/Application Support/Double Finder/Plugins/*.dfplugin`——用户插件（设置 ▸ 插件 ▸「打开插件文件夹」）。
- `Double Finder.app/Contents/PlugIns/*.dfplugin`——随应用内置的插件。

启动时加载。之后放进去的 bundle 靠「重新扫描」加载；已加载的 bundle 不重启无法替换。

---

## 2. 插件的结构

```
MyPlugin.dfplugin/
  Contents/
    Info.plist
    MacOS/MyPlugin          ← SwiftPM 构建出的动态库
```

**Info.plist** 里要紧的键：

| 键                   | 值                                                       |
|----------------------|----------------------------------------------------------|
| `NSPrincipalClass`   | `DFPlugin` 类的 Objective-C 名（`MyPlugin`）              |
| `DFPluginAPIVersion` | 整数，必须等于 `PluginKit.apiVersion`（当前 **1**）        |
| `CFBundleIdentifier` | 与 `PluginInfo.identifier` 用同一个字符串                 |
| `CFBundleExecutable` | `MacOS/` 下动态库的文件名                                  |

**主类**必须是暴露给 Objective-C 的 `NSObject` 子类，`Bundle.principalClass` 才找得到：

```swift
import AppKit
import DoubleFinderPluginKit

@objc(MyPlugin)
public final class MyPlugin: NSObject, DFPlugin {
    public let info = PluginInfo(identifier: "com.example.myplugin", name: "My Plugin",
                                 version: "1.0", summary: "它做什么", author: "我")
    private var host: PluginHost?

    public required override init() { super.init() }

    public func activate(host: PluginHost) throws { self.host = host }
    public func deactivate() { host = nil }

    public var commands: [CommandPlugin] { [HelloCommand()] }
    // fileSystems / viewers / packers / contentProviders 默认为 []
}
```

**生命周期**：`init()` → `activate(host:)` → 各扩展数组读一次 → … → 用户停用或应用退出时 `deactivate()`。
`activate` 抛错则插件保持未激活，错误信息显示在 设置 ▸ 插件。停用**不会卸载代码**（Swift 镜像不能安全卸载）：
只是弹出该插件的盘、撤销其扩展、调用 `deactivate`。

**rpath 规则**：你的动态库引用的是 `@rpath/libDoubleFinderPluginKit.dylib`，宿主会把它解析到**自己那一份**
（可执行文件旁边或 `Contents/Frameworks`）。你的 bundle **不能**带指向自己构建目录的 `LC_RPATH`，否则 dyld 会再加载一份
PluginKit，协议一致性检查会静默失败。模板的 `build.sh` 构建后会把所有 rpath 删掉。

---

## 3. 线程与错误

- `activate`、`deactivate`、`FileSystemPlugin.connect`、`ViewerPlugin.makeView`、`CommandPlugin.perform`、
  `makeSettingsView` 在**主线程**执行，可以在 `host.mainWindow` 上弹界面。
- `PluginFileSystemSession`、`PluginArchiveSession` 的方法、`PackerPlugin.create`、`ContentPlugin.value`
  在**主线程之外**执行。文件系统会话可能被并发调用，后端不耐并发就自己加锁；压缩包会话每个包同一时刻只有一次调用。
- 进度回调是 `@Sendable` 的，任何线程都能调。
- 错误：`PluginError.cancelled` = 静默取消（用户关掉了你的登录框）；`PluginError.unsupported` = 宿主有兜底
  （服务端拷贝/移动 → 经临时文件中转）；`PluginError.failed(msg)` = 给用户看的信息。其它 `Error` 按 `localizedDescription` 显示。

---

## 4. 扩展点

### 4.1 FileSystemPlugin（一个盘）

```swift
public protocol FileSystemPlugin: AnyObject {
    var identifier: String { get }        // 插件内唯一
    var displayName: String { get }       // 驱动器栏标题
    var symbolName: String { get }        // SF Symbol，默认 "puzzlepiece.extension"
    @MainActor func connect(host: PluginHost) async throws -> PluginFileSystemSession
}
```

驱动器栏给每个文件系统插件一个按钮，点击调用 `connect`——凭据提示放这里，用户退出就抛 `.cancelled`。
返回的会话成为一个带 ⏏ 的盘，直到被弹出。

```swift
public protocol PluginFileSystemSession: AnyObject {
    var label: String { get }                                   // 连接后驱动器栏显示的标签
    func list(_ directory: String) async throws -> [PluginFileEntry]
    func download(_ path: String, to localURL: URL, progress: @escaping @Sendable (Int64) -> Void) async throws
    func upload(_ localURL: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws
    func delete(_ path: String) async throws                    // 文件，或目录连同子树
    func createDirectory(_ path: String) async throws
    func rename(_ path: String, to newName: String) async throws
    func copy(_ path: String, toDirectory: String) async throws // 可选：抛 .unsupported
    func move(_ path: String, toDirectory: String) async throws // 可选：抛 .unsupported
    func disconnect()                                           // 可选
}
```

约定：

- 路径是 POSIX 风格、以 `/` 为根、无尾斜杠。`list` 返回叶名，宿主拼成 `<目录>/<名字>`。
- `download` / `upload` 只搬**一个文件**。目录树的遍历、父目录创建、以及你抛 `.unsupported` 时经临时目录中转，都由宿主完成。
  `progress` 收到的是该文件的累计字节数。
- 只实现这些就得到：浏览、F5 上下行（文件级字节进度）、盘内 F5/F6、F7、F8、改名、F3（下载临时副本）、F4 及回写、
  盘上的压缩包（先下载再浏览）、查找文件（名称 + 内容）、目录同步、拖放到面板、两侧面板同时进入同一会话。
- 插件盘不支持：命令行、权限。

### 4.2 ViewerPlugin（Lister 模式）

```swift
public protocol ViewerPlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    func canView(url: URL, sample: Data) -> Bool          // sample = 前 ≤64 KiB；要快
    @MainActor func makeView(for url: URL) throws -> NSView
}
```

`url` 永远是本地文件（远端条目先取下来）。插件认领的文件自动进入插件模式，即第 4 段 / 按键 `4`；1/2/3 切回文本/十六进制/预览。
`makeView` 抛错则回落内置模式。插件视图不参与 Lister 的查找、缩放、编码控件；⌘方向键翻文件照常（每个文件重建视图）。

### 4.3 PackerPlugin（压缩格式）

```swift
public protocol PackerPlugin: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var fileExtensions: [String] { get }                 // ["pak"]，复合后缀也行（"tar.lz"）
    func open(_ url: URL) throws -> PluginArchiveSession
    var canCreate: Bool { get }                          // 默认 false
    func create(_ url: URL, sources: [PluginArchiveSource],
                progress: @escaping @Sendable (Int64) -> Void,
                isCancelled: @escaping @Sendable () -> Bool) throws
}
public protocol PluginArchiveSession: AnyObject {
    func entries() throws -> [PluginArchiveEntry]        // path "docs/a.txt"、isDirectory、size、modified
    func extract(_ entryPath: String, to localURL: URL) throws
    func close()
}
```

读取：带你后缀的文件按压缩包着色，双击进入，F5 复制条目出来，⌥F6 解压，F3 看条目。目录由嵌套推断，只列文件也可以。
含 `..` 或绝对路径的条目被忽略。宿主按「路径 + 大小 + mtime」缓存已打开的会话并串行化调用。同一后缀插件优先于内置的 libarchive。

创建：实现 `canCreate = true` 和 `create`，格式就出现在打包表单里。宿主把目录展开成平铺的
`PluginArchiveSource(localPath:entryPath:)` 清单；用 `progress` 报累计字节，`isCancelled()` 为真时抛 `CancellationError`，宿主会删掉半成品。

插件格式不支持：包内改名、F4 回写、查找文件的「搜索压缩包」、加密与分卷选项。

### 4.4 ContentPlugin（自定义列）

```swift
public protocol ContentPlugin: AnyObject {
    var identifier: String { get }
    var columns: [PluginColumn] { get }                  // id、title、defaultWidth
    func value(column: String, path: String, isDirectory: Bool) -> String?   // nil → "—"
}
```

列出现在列头右键菜单里，可存入列集。`value` 在后台队列执行，每个（列、路径、大小、mtime）只算一次并缓存，
所以打开文件读个头是可以的。只对本地文件求值，远端和包内的行显示为空。插件列不能作为排序列。

### 4.5 CommandPlugin

```swift
public protocol CommandPlugin: AnyObject {
    var identifier: String { get }
    var title: String { get }                            // 你自己本地化好
    var symbolName: String { get }                       // 工具栏图标，默认 "puzzlepiece.extension"
    @MainActor func perform(_ context: PluginCommandContext) async throws
}
```

`PluginCommandContext` 带着活动面板和对侧面板的目录、选中路径（没选中则是光标项）、两侧是否为普通本地目录，以及 `host`。
命令出现在**插件**菜单，可在 设置 ▸ 工具栏 加成按钮，在 设置 ▸ 快捷键 绑定按键。

---

## 5. 宿主服务

```swift
@MainActor public protocol PluginHost: AnyObject {
    var mainWindow: NSWindow? { get }                      // 挂 sheet / alert 用
    func storageDirectory(for plugin: PluginInfo) -> URL   // Application Support 下属于你的目录
    func refreshPanels()                                   // 绕过应用改了文件之后刷新
    func presentError(_ error: Error)
    func log(_ message: String)                            // NSLog "[plugin] …"
    var languageTag: String { get }                        // "en"、"zh-Hans"……自己选文案
}
```

在 `activate` 里留住 host。设置存到 `storageDirectory(for:)`，通过 `makeSettingsView()` 暴露——
设置 ▸ 插件 ▸「插件设置…」会用 sheet 显示它。

---

## 6. 本地化

宿主不翻译插件的字符串。在 `activate` 里读 `host.languageTag` 自己选文案；`PluginColumn.title`、`CommandPlugin.title`
和各 `displayName` 原样显示。

---

## 7. 兼容与版本

- `PluginKit.apiVersion` 是契约，只在不兼容改动时递增；`DFPluginAPIVersion` 不一致的 bundle 会被拒绝，设置 ▸ 插件 里有明确原因。
- PluginKit 开启了 library evolution：同一 API 版本下，用旧 PluginKit 编译的插件在宿主换新编译器重编后仍能加载。
- 进程里只有一份 PluginKit——宿主的那份。永远不要自带一份（见上面的 rpath 规则）。

---

## 8. 调试

- `NC_PLUGIN_DIAG=1 "<app>/Contents/MacOS/Double Finder"` 列出找到的每个 bundle、状态和注册的扩展。
- `host.log` 走系统日志，前缀 `[plugin]`（Console.app，或 `log stream --predicate 'eventMessage CONTAINS "[plugin]"'`）。
- 设置 ▸ 插件 显示每个插件的状态和失败原因。
- 加载你的 bundle 时应用崩溃了，下次启动会隔离它（「上次加载时崩溃」）；修好后点「重新扫描」。
- 插件跑在应用进程里：未捕获的异常或崩溃会带走整个应用。解析文件时做好防护，宁可抛错也别 trap。

---

## 9. 发布前检查

- [ ] `NSPrincipalClass` 指向一个 `@objc` 的、遵循 `DFPlugin` 的 `NSObject` 子类
- [ ] `DFPluginAPIVersion` = 1，`CFBundleIdentifier` = `PluginInfo.identifier`
- [ ] 构建出的库没有 `LC_RPATH`（`otool -l MyPlugin.dfplugin/Contents/MacOS/MyPlugin | grep -A2 LC_RPATH`）
- [ ] 会话能承受并发调用，没有阻塞主线程
- [ ] `create` 和长传输响应取消
- [ ] `NC_PLUGIN_DIAG=1` 显示插件已激活、扩展齐全

## 10. 参考实现

`Examples/SamplePlugin` 用约 400 行实现了全部扩展点：内存盘、CSV 表格查看器、Quake PAK 格式（读 + 创建）、
图片尺寸列、选择摘要命令、设置页。它的 `build.sh` 就是打包参考。
