# easypub-lvy

Windows 上把 TXT 小说整理成 Kindle 电子书的桌面工具：识别章节、检查与修复、文本清理、排版，再一键生成 EPUB、AZW3、MOBI、KFX。

下载发布包请到 [Releases](https://github.com/uiu8/easypub-lvy/releases)。

本仓库是程序源码（Rust 核心 + Flutter 桌面界面），构建方法见下方“开发”一节。

## 主要功能

- **章节**：自动识别卷、章、节，检查重复标题、编号跳跃、漏识别的标题等问题，先预览再修复。
- **文本清理**：去广告、合并硬换行、规范标点、简繁转换等，每条规则都可以单独开关，原稿不改。
- **排版**：字号、行距、缩进、标题样式、章首图、场景分隔、章首段落，系统提示框与诗词自动识别，弹出注释，前后附页（版权页、献词、后记等）。
- **真机预览**：按所选 Kindle 机型的真实尺寸翻页预览，内容就是生成出来的成品。
- **输出**：EPUB、AZW3 / MOBI（内置 Kindling）、KFX（内置 Bokai）。
- **书源下载（可选插件）**：导入常见格式的文字书源，搜索并下载为 TXT，再直接导入书库整理。插件单独发布，需要时再装。

## 使用

1. 从 Releases 下载 `easypub-lvy-…-win-x64.zip`，**完整解压**。
2. 运行 `easypub_desktop.exe`。同目录下的 DLL、`data`、`converters`、`plugins`、`third_party` 都要保留，不要把 exe 单独移出来。
3. 包里附有使用说明（`先读我.txt`），写了每版新增的功能和尚未验证的内容。
4. 需要书源下载时，从同一个 Release 另外下载 `easypub-lvy-booksource-…-win-x64.zip`，解压后在程序的“插件”页点“从文件夹安装…”，选中解压出来的 `booksource` 文件夹，再启用即可。

系统要求：Windows 10 / 11 x64；“真机预览”需要系统自带的 Microsoft Edge。

## 开发

| 目录 | 内容 |
| --- | --- |
| `rust/crates/` | `easypub_core`（编码、识别、规则）、`easypub_app`（书稿、检查修复、排版、EPUB 输出）、`easypub_bridge`（给 Flutter 的接口） |
| `flutter/` | 桌面界面；测试在 `flutter/test/` |
| `plugins/kindle-preview/` | 真机预览插件 |
| `third_party/` | 内置的 Kindling（AZW3 / MOBI）、Bokai（KFX）补丁与固定版本的依赖源码 |
| `samples/`、`fixtures/` | 测试用的合成样书 |
| `tools/` | 环境、测试与打包脚本 |

需要：Rust 1.98.1（见 `rust-toolchain.toml`）、Flutter 3.47.3、flutter_rust_bridge 2.13.0、Visual Studio C++ 生成工具。`tools/project_env.ps1` 里的工具链目录是作者本机的，请按自己的安装位置修改。

```powershell
cargo build --release -p easypub_bridge
cd flutter
flutter build windows --release --target lib/frontend_rewrite_main.dart --no-tree-shake-icons
copy ..\target\release\easypub_bridge.dll build\windows\x64\runner\Release\
```

生产入口是 `lib/frontend_rewrite_main.dart`，构建时必须显式指定。

## 许可证

本项目自己的代码以 [MIT 许可证](LICENSE) 发布。

`third_party/` 下的组件各按自己的许可证：Kindling 为 MIT；Bokai 为 GPL-3.0-or-later，只作为独立的 `bokai.exe` 由程序调用，发布包附带其源码；其余依赖见各目录内的许可证文件。发布包里的转换器、字体和依赖许可证在压缩包的 `third_party/` 与 `converters/` 目录中。
