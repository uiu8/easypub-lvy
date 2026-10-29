# 真机预览组件（kindle-preview）

EasyPub++ 排版页“真机预览”按钮打开的独立组件（V30，LAY-108–110）。排版页用系统 Edge 以应用窗口
（`--app=`，单独的配置目录）打开 `index.html`。删除这个文件夹不影响软件其他功能，按钮会提示找不到组件。

## 文件

- `plugin.json`：名称、版本、接口版本（`api`）与入口。
- `index.html`、`preview.css`：窗口结构与样式。
- `preview.js`：机身绘制、分页翻页、侧边栏。

## 与主程序的连接

主程序在 `http://127.0.0.1:<随机端口>/<随机口令>/` 提供本组件与以下接口（只接受本机、口令与 Host 都正确的请求；
排版页关闭后停止）：

| 接口 | 用途 |
| --- | --- |
| `GET api/state` | 机型（含机身毫米尺寸）、阅读器设置、当前排版值、当前章节 |
| `POST api/render` `{values, entry}` | 按这些排版值生成本书内容（不保存），返回 `book/<编号>/` 下的正文路径 |
| `POST api/metrics` `{device, level, margin, spacing, values}` | 阅读器根字号、行高与页边距（与排版页小预览同一套参数）；KPW5 另有 `justify`（两端对齐）、`tracking`（字距补偿，em）、`cssPx`（书内 1px 画几个像素），按真机规则排版（V118） |
| `POST api/apply` `{values}` | 写回本书（只接受排版字段，经排版页原有保存流程） |

分页：正文放进与机型 CSS 视口相同大小的 iframe，按列分页——横排的列向右排、竖排（vertical-rl）的列向下排，每页一列。

KPW5 的视口等于屏幕分辨率（1236×1648），一个 CSS 像素就是一个屏幕像素；顶部“叠加真机截图…”可把 Kindle 截图半透明盖在屏幕上逐像素对比（V118）。
