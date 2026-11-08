# V90 书源离线兼容样本

40 份实际录制了三个免费章节的真实合集样本、2 份仅一章的补充样本，
另有 8 份明确标注“手写”的协议夹具；录制日期 2026-10-20。补充样本不计入 40 份门槛。

这些是插件的兼容回归材料，不是推荐书源或可用性名单。真实书站可能随时变化。
每个目录的 `source.json` 保存脱敏规则，`exchanges.json` 保存请求顺序、响应结构、
书名、作者、章数、首章、前 3 个免费章节的 SHA-256、字数和最多前 300 个字符。
正文尾部以长度占位保存，回放补自拟文字；比较元数据和字数 ±5%，不证明原文逐字一致。
GBK 按原编码复现。网络回放只能命中录制请求，未命中直接失败，不能访问原站。
WebView / 轻悦夹具仍执行 DOM 和桥接，但禁止浏览器另开网络通道。

正文很短的章节可能是前言；本样本库不能证明整本书完整、版权状态或长期可用。
8 份手写样本用于真实录制未能覆盖的写法，不能当成对应真实书源已经适配的证明。
`:contains`、JSONPath、XPath 的实际解析分支有测试专用突变注入，正常样本必须通过，
注入后必须失败，恢复后再通过；正式插件不编入突变。

复跑：先加载 `tools/project_env.ps1`，再执行 `cargo test --locked -p easypub_booksource`。
单独重放真实插件：`python -I -X utf8 tools/booksource_corpus.py replay --exe <插件路径> --work <独立证据目录>`。

| 编号 | 来源 | 覆盖写法 |
|---|---|---|
| [manual-batch](manual-batch/source.json) | 手写夹具；自拟内容 | 手写、contentBatch |
| [manual-html](manual-html/source.json) | 手写夹具；自拟内容 | 手写、jsoup默认规则、CSS、:contains、{{}}、GBK、正则、目录分页、正文分页 |
| [manual-json](manual-json/source.json) | 手写夹具；自拟内容 | 手写、JSONPath、POST、@js:、<js>、{{}}、@put/@get、put/get |
| [manual-mainjs](manual-mainjs/source.json) | 手写夹具；自拟内容 | 手写、mainJs、contentBatch、POST |
| [manual-qysg](manual-qysg/source.json) | 手写夹具；自拟内容 | 手写、轻悦HTML、桥接HTTP |
| [manual-sonovel](manual-sonovel/source.json) | 手写夹具；自拟内容 | 手写、so-novel |
| [manual-webview](manual-webview/source.json) | 手写夹具；自拟内容 | 手写、WebView、webJs |
| [manual-xpath](manual-xpath/source.json) | 手写夹具；自拟内容 | 手写、XPath |
| [real-0069b63398](real-0069b63398/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}}、正则 |
| [real-062cdc7d80](real-062cdc7d80/source.json) | yckceo-1316-20261020-133502.json | <js>、jsoup默认规则、{{}}、正则、正文分页 |
| [real-0728489e60](real-0728489e60/source.json) | yckceo-1315-20261020-133713.json | jsoup默认规则、{{}}、正则 |
| [real-0979e6669d](real-0979e6669d/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}}、正则 |
| [real-185a31b948](real-185a31b948/source.json) | yckceo-1315-20261020-133713.json | jsoup默认规则、{{}}、正则 |
| [real-20caf81ba0](real-20caf81ba0/source.json) | yckceo-1315-20261020-133713.json | jsoup默认规则、{{}}、正则 |
| [real-29d37d9419](real-29d37d9419/source.json) | yckceo-1316-20261020-133502.json | JSONPath、jsoup默认规则、{{}}、正则 |
| [real-30234c6160](real-30234c6160/source.json) | yckceo-1315-20261020-133713.json | POST、jsoup默认规则、{{}}、正则、正文分页 |
| [real-30a2487fdc](real-30a2487fdc/source.json) | yckceo-1315-20261020-133713.json | <js>、POST、jsoup默认规则、{{}}、正则、正文分页、目录分页 |
| [real-38915ba73d](real-38915ba73d/source.json) | yckceo-1315-20261020-133713.json | <js>、POST、jsoup默认规则、{{}}、正则、正文分页 |
| [real-4533d61b9b](real-4533d61b9b/source.json) | yckceo-1316-20261020-133502.json | POST、jsoup默认规则、{{}}、正文分页 |
| [real-4612e32e33](real-4612e32e33/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}}、正则、正文分页 |
| [real-5b9b017e48](real-5b9b017e48/source.json) | yckceo-1315-20261020-133713.json | POST、jsoup默认规则、{{}} |
| [real-5c6167d152](real-5c6167d152/source.json) | yckceo-1316-20261020-133502.json | @js:、jsoup默认规则、{{}}、正则、正文分页 |
| [real-67a62ac59f](real-67a62ac59f/source.json) | yckceo-1315-20261020-133713.json | @put/@get、POST、jsoup默认规则、{{}}、正则、正文分页、目录分页 |
| [real-681c545b23](real-681c545b23/source.json) | yckceo-1315-20261020-133713.json | @js:、jsoup默认规则、{{}}；仅一章，补充样本 |
| [real-75b5ffd593](real-75b5ffd593/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}} |
| [real-907704036e](real-907704036e/source.json) | yckceo-1315-20261020-133713.json | CSS、jsoup默认规则、{{}}、正则 |
| [real-941c80b91f](real-941c80b91f/source.json) | yckceo-1316-20261020-133502.json | JSONPath、jsoup默认规则、{{}}、正则 |
| [real-9aa2a86977](real-9aa2a86977/source.json) | yckceo-1315-20261020-133713.json | POST、jsoup默认规则、{{}} |
| [real-9b8a7913e7](real-9b8a7913e7/source.json) | yckceo-1315-20261020-133713.json | @js:、jsoup默认规则、{{}}、正则、正文分页 |
| [real-9e968b1653](real-9e968b1653/source.json) | yckceo-1316-20261020-133502.json | <js>、@js:、JSONPath、jsoup默认规则、{{}}、目录分页 |
| [real-9f2bfdf0d7](real-9f2bfdf0d7/source.json) | yckceo-1315-20261020-133713.json | POST、jsoup默认规则、{{}}、正则 |
| [real-a004ddf728](real-a004ddf728/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}}、正则 |
| [real-a3f1d8ca25](real-a3f1d8ca25/source.json) | yckceo-1315-20261020-133713.json | GBK、jsoup默认规则、{{}}、正则 |
| [real-a55875a3fc](real-a55875a3fc/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}}、正则、正文分页、目录分页 |
| [real-aa5333a793](real-aa5333a793/source.json) | yckceo-1315-20261020-133713.json | jsoup默认规则、{{}}、正文分页、目录分页 |
| [real-b2177c7151](real-b2177c7151/source.json) | yckceo-1315-20261020-133713.json | <js>、@js:、XPath、jsoup默认规则、{{}}、正则 |
| [real-b9bbe1996e](real-b9bbe1996e/source.json) | yckceo-1315-20261020-133713.json | @js:、jsoup默认规则、{{}}、正则 |
| [real-bc78ecbbeb](real-bc78ecbbeb/source.json) | yckceo-1315-20261020-133713.json | jsoup默认规则、{{}}、正文分页 |
| [real-c029fa98d5](real-c029fa98d5/source.json) | yckceo-1316-20261020-133502.json | <js>、jsoup默认规则、{{}}、正则 |
| [real-c077e07dc7](real-c077e07dc7/source.json) | yckceo-1315-20261020-133713.json | <js>、@js:、POST、XPath、jsoup默认规则、{{}}、正则、正文分页、目录分页 |
| [real-c142241098](real-c142241098/source.json) | yckceo-1316-20261020-133502.json | GBK、jsoup默认规则、{{}}、正则 |
| [real-c150c48ada](real-c150c48ada/source.json) | yckceo-1316-20261020-133502.json | @js:、JSONPath、jsoup默认规则、put/get、{{}} |
| [real-c2e6eb1637](real-c2e6eb1637/source.json) | yckceo-1316-20261020-133502.json | POST、jsoup默认规则、{{}}、正则、正文分页 |
| [real-c39b2702a4](real-c39b2702a4/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}}、正则、正文分页、目录分页 |
| [real-ccebed7c5d](real-ccebed7c5d/source.json) | yckceo-1315-20261020-133713.json | jsoup默认规则、{{}}、正则 |
| [real-d7d9ecb87e](real-d7d9ecb87e/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、{{}}、正则、正文分页 |
| [real-e9971872e3](real-e9971872e3/source.json) | yckceo-1316-20261020-133502.json | jsoup默认规则、正则 |
| [real-ebd7a027e2](real-ebd7a027e2/source.json) | yckceo-1316-20261020-133502.json | <js>、jsoup默认规则、{{}}、正则 |
| [real-f58fc1c12a](real-f58fc1c12a/source.json) | yckceo-1315-20261020-133713.json | jsoup默认规则、{{}}、正则；仅一章，补充样本 |
| [real-f9a60faad1](real-f9a60faad1/source.json) | yckceo-1316-20261020-133502.json | @js:、POST、jsoup默认规则、正文分页 |
