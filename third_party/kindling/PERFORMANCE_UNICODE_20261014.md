# Kindling 中文包内路径优化（2026-10-14 后续）

普通中文及其他 Unicode 包内路径现在保留并行解压和内容缓存。此前 `!entry.name().is_ascii()` 会让整本 EPUB 回退，本轮去掉该条件，改为检测路径之间的大小写别名。没有更改书籍内容生成、CSS 顺序、线程参数或缓存读取接口。

## 修改

- `src/epub.rs`：Windows 下对规范化后的文件路径和所有父目录路径各做一次 UTF-16 编码，使用 `CompareStringOrdinal(..., TRUE)` 排序，再检查相邻的等价路径。复杂度 O(n log n)，不为每个文件新增磁盘探测，也未新增依赖。
- 普通中文、带重音字母、emoji 等名称可以并行解压并缓存。确实按 Windows ordinal 大小写规则相等的文件/目录名称，以及原来的流名称，仍回退到按 ZIP 顺序写盘和磁盘读取，保留覆盖结果与实际目录拼写。
- 不进行语言学比较或 Unicode 规范化，因此 `é.xhtml` 与 `e` 加组合重音的文件名保持独立。微软将 `CompareStringOrdinal` 用于包括 NTFS 文件名在内的非语言学比较，忽略大小写时使用操作系统大写表：[官方说明](https://learn.microsoft.com/en-us/windows/win32/intl/handling-sorting-in-your-applications)。
- 扩展原有两组解压测试，覆盖中文外部路径、中文包内目录/文件、重音字母及 emoji、组合字符、点段重复文件、Unicode 大小写文件别名，以及显式目录别名。正常场景删除磁盘文件后仍能读缓存；别名场景保留最后写入内容，并回退磁盘。
- `EASYPUB_PATCHES.md` 更新当前边界，上一份 `PERFORMANCE_20261014.md` 保留当时的历史测量。

## 样书和测量

证据目录：`%TEMP%\easypub-kindling-unicode-20261014-01`。

`verify_unicode.py` 复用上一轮的成品比较函数，从原 3000 章样书副本生成中文路径版本：`EPUB/` 改为 `正文/`，2999 个 `body-NNNN.xhtml` 名称改为 `章节-NNNN.xhtml`，同步对应引用。全部 3003 个 HTML 均位于中文目录内，EPUB 外部文件名为 `中文3000.epub`。输入、输出及临时解压均位于证据目录，未在书库里执行转换。

中文样书 SHA256：`4403b484fab0dcda6b713bf44e9129f76179bae632c63724a05f80b89efb6f17`，详见 `inputs.json`。

“改进前”是上一轮已经完成缓存、并行和正则优化的引擎，不是最初的原版 Kindling。其保全副本 `kindling-before.exe` SHA256 为 `d1040dd31710a9e4dc365152ede04abef6dec5a199786c6e5d6e1655865228cf`。本轮各项串行运行，计时前等待已发现的另一进程的默认引擎编译结束。

| 版本 / 线程 | AZW3 秒 | MOBI 秒 |
| --- | ---: | ---: |
| 改进前，8 线程 | 12.1926 | 10.9985 |
| 改进后，1 线程 | 6.7391 | 8.6999 |
| 改进后，4 线程 | 5.5874 | 5.3061 |
| 改进后，8 线程 | 4.6030 | 5.0795 |

以上是每组单次墙钟时间，包含进程启动和退出，未用后续较快结果替换。日志使用 `KINDLING_PROFILE=1`。8 线程主要阶段变化：

| 阶段，ms | AZW3 前 → 后 | MOBI 前 → 后 |
| --- | ---: | ---: |
| 解压 | 1329 → 993 | 1275 → 931 |
| 类型识别 | 2910 → 3 | 1682 → 3 |
| 预检合计 | 3025 → 410 | 3036 → 387 |

8 线程连续 8 次的完整统计：

| 格式 | 平均秒 | 中位秒 | 范围秒 | 字节一致 |
| --- | ---: | ---: | --- | --- |
| AZW3 | 4.5875 | 4.5560 | 4.4682–4.8296 | 8 / 8 |
| MOBI | 5.0999 | 5.0376 | 4.9926–5.3019 | 8 / 8 |

## 验收结果

- 中文样书改进前后、改进后 1 / 4 / 8 线程：两格式成品逐字节一致，仅忽略 PDB `[36, 44)` 时间戳；排序后的预检行和退出码也一致。
- 原来的 6 本样书按上一轮 16 项口径在 8 线程下复核：12 个成功成品及 4 个既有预检失败，均与上一轮 `final-v4-t8` 的输出、预检、退出码一致。没有新增 CSS 例外。
- 中文样书两格式各连续 8 次：成品与预检完全一致，并匹配单次线程验收成品。`acceptance-summary.json` 的全部检查均为 true。
- `cargo test --locked --manifest-path third_party/kindling/Cargo.toml`：1185 passed、0 failed、2 ignored（既有）。沿用上一轮测试进程 PATH 中的系统 bsdtar 副本。日志 `cargo-test.log`。
- `cargo clippy --locked --manifest-path third_party/kindling/Cargo.toml --all-targets`：通过，仍为原来的 4 条警告，没有新增。日志 `clippy.log`。
- `git diff --check -- third_party/kindling`：通过。

中文样书成品 SHA256（屏蔽时间戳后，改进前后相同）：

```text
AZW3 51efb36dbd64e28293586d71376026cd6e16963e6f45bea587c869a5c8acd360
MOBI 7d8c086ac439ef42d613f0f7dca6c35979774e47dc013f0d27ad5b8505729665
```

## 默认引擎

候选验收完成后执行默认目录正式编译及 `tools/verify_kindling_release.ps1`，均成功。

- 默认引擎：`third_party/kindling/target/release/kindling-cli.exe`。
- 正式 EXE SHA256：`93125aa52234c67b717c618f634d0d47f8cf1c8db773b2b3fa0865b94a2d7391`。
- 发布验证：[verification.json](../../artifacts/kindling-release-check-68d83205064f45339b81362ca8c8ba06/verification.json)，`passed=true`；两格式 MOBI7 / KF8 的九项书目信息验证通过。`reader_acceptance=false`，不代表新增 Kindle 真机验收。
- 默认引擎另生成中文样书两格式成品，与候选再次比对，成品、预检及退出码均相同；发布验证中的源码哈希也与当前文件一致。`delivery-final.json` 的 `converter_acceptance_pass=true`。

外部工作区快照没有保持完全相同：并发工作新增了 6 项 `docs/` 状态记录，一项 KFX 证据不再处于未跟踪状态。原始 `delivery-summary.json` 因此保留 `outside_unchanged=false` 和总审计 `passed=false`；其中 `release_verified`、`smoke_equal` 均为 true。`delivery-final.json` 单独列出转换器验收结论与全部外部差异，没有把外部快照差异改写为通过。本轮未编辑或还原这些外部文件。

本轮只修改上述 Kindling 源码、补丁说明和新增本报告，没有提交、推送或修改其他源码。开始时 HEAD 为 `6f99b9f`；执行期间另一批工作推进到了 `988cf54`，两次提交均不由本轮创建。

```text
 third_party/kindling/EASYPUB_PATCHES.md |  13 ++-
 third_party/kindling/src/epub.rs        | 155 +++++++++++++++++++++++---------
 2 files changed, 121 insertions(+), 47 deletions(-)
```

上表是 tracked diff；本报告为新文件，未计入该统计。
