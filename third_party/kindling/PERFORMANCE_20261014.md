# Kindling V37 多线程优化验收（2026-10-14）

本轮基于 EasyPub 维护的 Kindling 0.45.6 和工作区已有多线程、计时补丁继续优化。源码及文档修改限定于 `third_party/kindling/`，不提交、不推送。3000 章样书的 8 线程单次 AZW3 / MOBI 为 **4.7886 / 5.2474 秒**；各连续 8 次平均为 **5.6980 / 5.4325 秒**，包含下述一次 AZW3 性能离群。

## 测量口径与证据

本次证据根目录：

`%TEMP%\easypub-kindling-codex-20261014-a3746a2c`

下文的证据文件名均相对于此目录。`acceptance.py` 是实际执行的验收脚本；`final-data.json` 汇总候选版本数据，原始 stdout/stderr、命令、退出码、CPU 时间、输出哈希分别保存在每项的 `.log` 和 `.result.json` 中。

- 输入先复制到证据目录再执行，不在 `D:\calibre shuku1` 书库中解压。`input-audit.json` 记录输入 SHA256，并与原 baseline、t1、t4、t8 输入核对一致。
- `split3000` 是每章拆文件的 3000 章样书，包内实际有 3003 个 HTML；`old3000` 为相同内容的旧拆法，实际 38 个 HTML。
- 进程墙钟时间覆盖启动至退出；AZW3 为普通 build，MOBI 加 `--legacy-mobi`。开启 `KINDLING_PROFILE=1`，每次启动新进程。性能验收期间没有并行执行 Cargo 构建或测试。
- 原版使用开始工作时保全的默认引擎，本次重新计时。任务描述中的约 18 / 20 秒是历史测量，不与本次新数据混用。
- 字节比较只清零 PDB 头 `[36, 44)` 两个时间戳；其余所有字节都进入 SHA256。预检行排序时保留重复行，仅规范化每次解压目录，另独立比较真实退出码。

## 3000 章性能

| 版本 / 线程 | AZW3 墙钟秒 | MOBI 墙钟秒 | AZW3 CPU 秒 | MOBI CPU 秒 |
| --- | ---: | ---: | ---: | ---: |
| 原版（本次实测） | 28.2170 | 30.2186 | 16.9063 | 19.8438 |
| 新版 1 线程 | 6.4195 | 6.5851 | 5.3125 | 6.7031 |
| 新版 4 线程 | 5.2468 | 4.9703 | 7.7656 | 7.9375 |
| 新版 8 线程 | 4.7886 | 5.2474 | 8.2813 | 8.7188 |

证据：`perf-original/timings.json`、`final-v4-t1/timings.json`、`final-v4-t4/timings.json`、`final-v4-t8/timings.json`。这是各组的实际单次结果；4 与 8 线程的细小差距不能据此认定为稳定的线程数排名。

8 线程连续 8 次统计（不剔除样本）：

| 格式 | 平均秒 | 中位秒 | 最小秒 | 最大秒 | 字节 / 预检一致 |
| --- | ---: | ---: | ---: | ---: | --- |
| AZW3 | 5.6980 | 4.5733 | 4.4587 | 12.9882 | 8 / 8 |
| MOBI | 5.4325 | 5.3854 | 5.2134 | 5.7645 | 8 / 8 |

AZW3 第 8 次是性能离群：总耗时 12.9882 秒，`check #12` 的整个 CrossRefsChecks 组（标签 `R9.1`，包含 R9.1–R9.12）耗时 8606 ms，预检合计 8753 ms。前 7 次总耗时为 4.4587–5.0214 秒。输出与预检均未变化；现有证据不足以确定这次延迟的具体原因。该样本完整保留在 `repeat8/azw3/repeat-08.azw3.result.json`，未补跑替换。全部重复结果见 `repeat8.json`。

## 8 线程分阶段计时

以下来自 `final-v4-t8/split3000.*.result.json`，单位 ms。`check #...` 子项包含在预检合计中，不重复加总。

| 阶段 | AZW3 | MOBI |
| --- | ---: | ---: |
| 读取 SRCS | 1 | 1 |
| 解压 EPUB | 1080 | 1115 |
| 解析 OPF | 4 | 4 |
| Profile::autodetect | 2 | 2 |
| 预检合计 | 368 | 375 |
| 图片、缩略图、字体阶段 | 405 | 431 |
| 读取、清理 HTML | 206 | 187 |
| 封面处理与长度限制 | 261 | 186 |
| 去字体 CSS | 1 | 1 |
| 提取 CSS | 2 | 3 |
| 导航点 | 4 | 4 |
| build_mobi 剩余阶段 | 458 | 929 |
| 清理临时目录 | 487 | 457 |
| 构建后检查 | 13 | 11 |
| 已记录阶段合计 | 3292 | 3706 |
| 进程启动、退出及计时未覆盖区间（墙钟差额，约） | 1497 | 1541 |

`build_mobi 剩余阶段` 包含剩余 KF8 构建及对应格式的合并、压缩、写出等工作，并非独立测量的纯 KF8 算法时间。预检中的大小写检查为 4 / 3 ms，清单检查为 24 / 22 ms，CrossRefsChecks 为 218 / 226 ms（AZW3 / MOBI）。

## 实现与诊断结论

- EPUB 一次读入压缩字节，工作线程使用独立 ZIP 游标解压；父目录只创建一次，按线程数划分写盘块。解压后的原始字节保留在本次构建私有的 `ContentCache` 中，通过 `OPFData`、`ExtractedEpub` 传给消费者。
- 类型识别、预检、图片发现、HTML、CSS、导航、字体及字典路径优先借用缓存；未命中继续读文件。统一处理 Windows verbatim 前缀、分隔符、点段，直接 OPF 的真实 canonicalize 回退保留原语义。
- 类型识别每章读取一次，保留字典优先于固定版式/漫画的判定。实测旧并行候选的识别阶段曾为 1 线程 11916 ms、8 线程 1671 ms；缓存后约 2 ms。仅接通部分消费者时，昂贵读取曾转移到尚未接缓存的导航预检 R5.1（18328 ms），补齐后约 2 ms。因此确认了重复/首次文件读取是可消除的主要成本，未将 Rayon `any()` 或杀毒软件认定为已证实的根因。
- HTML 清理、去字体、图片发现、CSS 链接扫描、媒体检查及部分文件系统查询并行执行，按原输入顺序收集；图片集合仍沿用原排序。MOBI7 每章独立转换后按 spine 顺序合并，再计算偏移和链接，不并行分配全局偏移。
- CSS 按有效 OPF manifest 文档顺序处理，消除原 HashMap 遍历随机性；href 先按首次出现去重，路径解析并行，最终按首次出现的规范路径顺序合并。
- 文件名大小写检查每目录建立精确名称和 ASCII 折叠名称索引，消除重复列目录和内存名称比较两处平方级行为，保留精确名称优先及原来的最后大小写不敏感匹配。
- KF8、MOBI HTML 清理、图片替换、字体样式清理复用编译后的正则；模式及替换语义保持不变。
- 保留 `build --threads N`（1–64；省略时遵循 Rayon 默认）和 `KINDLING_PROFILE` stderr 计时；没有遗留 `KINDLING_SEQ_*` 开关。

缓存随构建持有解压字节，会增加峰值内存；本次未单独测量峰值内存。Windows 下有 ZIP 路径别名、非 ASCII 条目名或流名称等特殊情况，继续顺序解压并回退磁盘读取。仅 EPUB 文件名或其父目录为中文不会禁用缓存。本次性能数字适用于所测样书，不代表这些回退路径的速度。

## 兼容性与测试

每种线程数包含 16 项：`split3000`、`old3000`、`two_line`、`classic`、`shenkong`、`shenkong_nv`、`wenzixue`、`wenzixue_nv` 各两格式。其中每组 12 个成功成品、4 个既有预检失败（两本真实书籍的正常预检构建）；`_nv` 项显式使用 `--no-validate`。

- 1 / 4 / 8 线程共 48 项：所有输出、排序后预检及退出码在线程间一致。
- 与原版：16 项预检和退出码一致；12 个成品中，除已知的 5 项 CSS 顺序外，均直接匹配原 baseline。5 项分别用保全原版重新生成，全部找到逐字节匹配。
- 8 线程 AZW3、MOBI 各连续 8 次：输出哈希一致，也与该格式的线程验收成品一致；预检一致。
- `cargo test --locked --manifest-path third_party/kindling/Cargo.toml`：1185 passed、0 failed、2 ignored（既有忽略项）。Windows 缺少 `bsdtar` 命令名，测试进程 PATH 使用证据目录 `test-tools/bsdtar.exe`，其内容是系统自带 `C:\Windows\System32\tar.exe` 的副本；未修改系统 PATH 或产品代码绕过测试。完整日志：`cargo-test-v4.log`。
- `cargo clippy --locked --manifest-path third_party/kindling/Cargo.toml --all-targets`：通过，无新增警告。保留 4 条既有警告：`mobi.rs`、`repair.rs`、`dict_css.rs` 的 `question_mark`，及 `tests/roundtrip.rs` 的 `useless_borrows_in_formatting`；相关函数/代码与 HEAD 核对。日志：`clippy-v4.log`。
- `git diff --check -- third_party/kindling`：通过。

| 原版 CSS 例外 | 首次匹配的本轮原版运行次数 |
| --- | ---: |
| old3000.azw3 | 2 |
| two_line.azw3 | 1 |
| classic.mobi | 1 |
| old3000.mobi | 3 |
| wenzixue_nv.mobi | 2 |

证据：`acceptance-summary.json`、`css-retries.json`、`compare-final-v4-t1-final-v4-t4.json`、`compare-final-v4-t1-final-v4-t8.json`、`compare-easypub-v37-baseline-final-v4-t1.json`。

3000 章成品 SHA256（仅屏蔽时间戳后，原版 / 新版一致）：

```text
AZW3 211967d61953464b6e161d971d8cfe93d6e9cd3d0092263eb38b76fb651ca163
MOBI 74bf2938be086ac8c91007b4dcb84e8a4cb7d6b1cd909a8118f6fd293dbbfecd
```

原版保全文件 `kindling-original.exe` SHA256：`f4224666759ffef19e6a4e76a508c2b2d5b1bb764c54463dc59ffa34df7d7b62`。

验收候选 `kindling-candidate-v4.exe` SHA256：`0a4e8312a7dc9354231ff7efd0551f74a42badbf28d139e8766aa45e0679e5bc`。

## 默认引擎与发布验证

候选全部验收通过后，才执行正式默认目录编译；覆盖前再次确认默认 EXE 仍为上述原版 SHA256。以下两步均成功退出：

```powershell
. .\tools\project_env.ps1
cargo build --locked --release --manifest-path third_party/kindling/Cargo.toml --bin kindling-cli
.\tools\verify_kindling_release.ps1 -EnginePath 'D:\software\EasyPub-RustFlutter\third_party\kindling\target\release\kindling-cli.exe'
```

正式引擎：[kindling-cli.exe](target/release/kindling-cli.exe)，SHA256 为 `d1040dd31710a9e4dc365152ede04abef6dec5a199786c6e5d6e1655865228cf`。临时与默认 target 生成的 EXE 哈希不同，因此另用正式引擎对 3000 章两格式做了成品复核；两项退出码均为 0，成品均匹配上面的原版 / 候选哈希。该次 AZW3 / MOBI 耗时为 6.2545 / 5.9714 秒，单独保留在 `installed-smoke/timings.json`，未替换前面的候选性能或重复数据。

发布验证结果：[verification.json](../../artifacts/kindling-release-check-a12e2c42792448a5afa6f4021cb8919d/verification.json)，其 `passed=true`，Flutter 验证测试通过。检查覆盖 MOBI、AZW3 的 MOBI7 / KF8 部分，以及 title、author、publisher、description、isbn、translator、category、publication_date、language 九项。验证前后正式引擎 SHA256 一致。

构建及发布日志：证据目录的 `build-default.log`、`verify-kindling-release.log`；完整发布测试日志在上述验证目录的 `test.log`。`reader_acceptance=false`：本轮完成的是转换器兼容性和发布脚本验收，未追加 Kindle 真机排版验收。

最终交付核对保存在 `delivery-summary.json`，`delivery_checks_pass=true`：正式 EXE 及发布验证记录中的全部源码哈希匹配当前文件；正式引擎两项成品、预检、退出码匹配候选；原版和正式引擎均有独立保全副本。

## 改动文件与 diff stat

以下是当前 `git diff --stat -- third_party/kindling`，包含任务开始前已经存在的 Kindling 未提交补丁，不冒充为本轮新增量。表内列出了全部 26 个 tracked 改动文件：

```text
 third_party/kindling/EASYPUB_PATCHES.md            |  50 ++++
 third_party/kindling/src/checks/content.rs         |   3 +-
 third_party/kindling/src/checks/cover.rs           |   2 +-
 third_party/kindling/src/checks/dict.rs            |  33 +--
 third_party/kindling/src/checks/file_case.rs       |  83 ++++---
 third_party/kindling/src/checks/fixed_layout.rs    |   5 +-
 third_party/kindling/src/checks/helpers.rs         |   6 +-
 third_party/kindling/src/checks/image_integrity.rs |   3 +-
 third_party/kindling/src/checks/manifest_spine.rs  | 148 ++++++++----
 third_party/kindling/src/checks/metadata.rs        |   3 +-
 third_party/kindling/src/checks/nav_links.rs       |  11 +-
 third_party/kindling/src/checks/navigation.rs      |  22 +-
 third_party/kindling/src/checks/opf_grammar.rs     |   8 +-
 third_party/kindling/src/checks/parse_encoding.rs  |   5 +-
 third_party/kindling/src/checks/toc_extras.rs      |  22 +-
 third_party/kindling/src/epub.rs                   | 223 ++++++++++++++++--
 third_party/kindling/src/extracted.rs              |  22 +-
 third_party/kindling/src/fonts.rs                  | 116 ++++-----
 third_party/kindling/src/kf8.rs                    |  28 ++-
 third_party/kindling/src/lib.rs                    |   2 +
 third_party/kindling/src/main.rs                   |  33 ++-
 third_party/kindling/src/mobi.rs                   | 261 ++++++++++++---------
 third_party/kindling/src/nav.rs                    |   4 +-
 third_party/kindling/src/opf.rs                    | 132 ++++++-----
 third_party/kindling/src/profile.rs                | 126 +++++++---
 third_party/kindling/src/validate.rs               |  10 +-
 26 files changed, 923 insertions(+), 438 deletions(-)
```

此外有 3 个未跟踪文件，Git diff stat 默认不包含：新建的 `src/content.rs`、本报告，以及任务开始时已经存在的 `src/timing.rs`。

`git status` 另显示 `tests/easypub_bibliography.rs` 为 M，但其内容 diff 为空，`git hash-object` 与 `HEAD` 均为 `3dab0e186ce29bba6a142ed541b9eab420f66af2`，没有内容改动，未计入上表。

Kindling 外部工作区的开始/结束快照均为 24 项，文件列表、状态、大小及 SHA256 逐项一致，差异为空；证据为 `outside-kindling-before.json`、`outside-kindling-after.json`、`delivery-summary.json`。本轮没有提交或推送。
