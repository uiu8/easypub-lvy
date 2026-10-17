# Bokai 0.2.0 — EasyPub Windows 兼容修订 2

原始源码为同目录 bokai-0.2.0.crate；版本、提交和 SHA256 见 UPSTREAM.json。Bokai 为 GPL-3.0-or-later；LICENSE 随附。EasyPub 通过独立命令行进程调用，没有引入 Sidle 桌面程序。

2026-10-08 的修改在 patches.json 中逐项列出，由 apply_patches.py 应用：

- src/import/mod.rs：EPUB 内部路径规范化后还原 `/`，修正 Windows 章节锚点无法解析的问题。
- src/validate/fidelity/nav.rs：重复目录统计保留 `#fragment`；manifest 查找仍只使用文件路径。同一 XHTML 的多个有效章节不再误报重复。
- src/validate/fidelity/metadata.rs：以引擎已有语言规则比较语种，接受 zh-CN→zh-hans、zh-TW→zh-hant，仍拒绝不同语种。

- src/export/kfx.rs：格式能力改为 Ion 列表，声明位置映射 v2 和实际存在的文本块 v1；正文按 UTF-8 字节切分为至多 8192 字节的块并更新引用（单段超长文本不截断）；内置封面直接使用图片，避免继承正文样式污染原生封面结构。

并未取消正文、目录、图片、链接及元信息的校验。原包其余代码未变。nav.rs 原有“每章一个文件”的说明不适用于此次补丁后的统计。

在 EasyPub 源码根运行 `./tools/build_bokai.ps1`。脚本先核验原归档，再应用精确补丁，最后使用 Cargo.lock 和 `bin,svg,validate` 功能编译。单独重建时：解开 crate，执行 `python apply_patches.py <源码目录>`，在源码目录执行 UPSTREAM.json 中的 cargo build 命令；需要 Rust/Cargo 和平台链接器，Cargo 依赖按 Cargo.lock 取得。

EasyPub 的 KFX 输入单独将内置封面 CSS 改成等比显示；Kindle 原生封面不使用 EPUB 的 object-fit。自定义 CSS 不会被这一步批量删除。复杂 CSS 仍可能被校验拒绝；真实设备效果另行验证。
