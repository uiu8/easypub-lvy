# EasyPub++ Flutter 客户端

当前前端入口是 `lib/frontend_rewrite_main.dart`，实现位于 `lib/frontend_rewrite/`。接手状态、版本和剩余工作以 [16 号交接](../docs/16_新对话启动交接说明.md)及 [20 号账本](../docs/20_补全实施跟踪.md)为准。

## 调用结构

`frontend_rewrite 页面 → application 服务 → infrastructure/legacy_* 适配器 → prototype 非视觉状态/FRB → Rust`

`legacy_*` 是当前使用的适配层；`prototype` 仍承载复用的状态/项目链。不要因目录名称删除它们，也不要将旧 `main.dart` 或原型入口作为当前发布入口。

- `frontend_rewrite/app/rewrite_app.dart`：路由、当前书、转换修复来源、工作区生命周期。
- `application/`：书库、章节、清理、目录、转换、历史与设置接口。
- `infrastructure/`：原生服务和系统选择器实现。
- `src/rust/`：生成桥接代码，协议修改后通过 FRB 生成，不手改。
- `test/completion/` 与 `tool/verify_*_test.dart`：现有业务验证，按改动范围复用。

## 环境与构建

```powershell
Set-Location -LiteralPath 'D:/software/EasyPub-RustFlutter'
. ./tools/project_env.ps1
Set-Location -LiteralPath flutter
flutter build windows --release --no-pub --target lib/frontend_rewrite_main.dart --no-tree-shake-icons
```

先完成一批关联代码再统一测试。使用新构建或新包 DLL/Kindling，明确隔离设置目录；修改 Rust 后先构建桥接库再运行调用它的测试。可复现命令和当前已通过结果见交接，接手时不必立即重复构建和回归。

2026-10-07 最新软件评审包为 1453 版：144 项关联验证与 `dart analyze lib` 通过；完整 41 项/W8 收口仍未结束。
