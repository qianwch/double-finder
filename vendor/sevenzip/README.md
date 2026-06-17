# Vendored 7-Zip (`7zz`)

捆绑进 `.app` 的官方 7-Zip 命令行可执行文件，用于 **加密 7z 的读/解压/创建**——
这是 libarchive 唯一覆盖不了的边角（见 `spec/filesystem.md`）。普通归档全走内置 libarchive，**不碰这个**。

- `7zz`：官方 macOS **universal**（x86_64 + arm64）二进制。
- `License.txt`：7-Zip 授权（LGPL 2.1 + BSD + unRAR 限制）。LGPL 要求随附，勿删。

## 当前版本

- 24.09（2024-11-29）

## 来源 / 更新方法

官方 GitHub 镜像 `ip7z/7zip` 的 release（`www.7-zip.org` 在部分内网会被劫持，用 GitHub 更稳）：

```bash
ver=2409   # 对应 24.09
cd /tmp
curl -L -o 7z-mac.tar.xz \
  "https://github.com/ip7z/7zip/releases/download/24.09/7z${ver}-mac.tar.xz"
mkdir 7zext && tar -xf 7z-mac.tar.xz -C 7zext
lipo -archs 7zext/7zz          # 必须是 "x86_64 arm64"（universal），否则别用
cp 7zext/7zz       "<repo>/vendor/sevenzip/7zz"
cp 7zext/License.txt "<repo>/vendor/sevenzip/License.txt"
chmod +x "<repo>/vendor/sevenzip/7zz"
```

`package_app.sh` 打包时会把这个 `7zz` 复制进 `Contents/MacOS/7zz` 并 ad-hoc 签名。
运行时 `Utils/SevenZip.swift` 的 `bundledPath()` 优先用它（手工设置 > 捆绑 > 系统自动检测）。

> **开发裸跑**（不打 .app）时没有捆绑 7zz，加密 7z 会回退到系统 `7z/7zz/7za` 自动检测——属正常。
