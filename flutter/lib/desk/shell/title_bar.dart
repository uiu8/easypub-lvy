// 编辑台标题栏（G-001–004、G-022、G-030、G-062）：标识、面包屑、命令搜索、
// 保存状态、项目菜单与窗口按钮。拖动空白处移动窗口；关闭先走离开保护。
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../tokens.dart';
import '../widgets.dart';

class DeskTitleBar extends StatefulWidget {
  const DeskTitleBar({
    super.key,
    this.onClose,
    this.crumbs,
    this.onSearch,
    this.status,
    this.trailing,
  });

  /// 返回 false 时保持窗口；不会替用户应用任何预览或丢弃输入。
  final Future<bool> Function()? onClose;
  final Widget? crumbs, status, trailing;
  final VoidCallback? onSearch;
  @override
  State<DeskTitleBar> createState() => _DeskTitleBarState();
}

class _DeskTitleBarState extends State<DeskTitleBar> with WindowListener {
  bool maximized = false;
  bool closing = false;
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (widget.onClose != null) windowManager.setPreventClose(true);
    refresh();
  }

  Future<void> refresh() async {
    final value = await windowManager.isMaximized();
    if (mounted) setState(() => maximized = value);
  }

  Future<void> requestClose() async {
    if (closing) return;
    closing = true;
    try {
      final allow = await widget.onClose?.call() ?? true;
      if (allow && mounted) await windowManager.destroy();
    } finally {
      closing = false;
    }
  }

  @override
  void onWindowClose() {
    requestClose();
  }

  @override
  void onWindowMaximize() => refresh();
  @override
  void onWindowUnmaximize() => refresh();
  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    final width = MediaQuery.sizeOf(context).width / scale;
    final narrow = width < 1120;
    return Container(
      height: 40 * scale,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          // 拖动区放在内容之下：面包屑、搜索框等可点控件在上层直接响应单击，
          // 不再被拖动区的“双击最大化”识别器拖慢约 300ms；空白处仍可拖动与双击。
          Expanded(
            child: Stack(
              children: [
                const Positioned.fill(
                  child: DragToMoveArea(child: SizedBox.expand()),
                ),
                Row(
                  children: [
                    const SizedBox(width: 14),
                    Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: d.accent,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        'E',
                        style: serif(12, w: 700, c: d.accentInk),
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (widget.crumbs != null)
                      Flexible(flex: 3, child: widget.crumbs!),
                    const Spacer(),
                    if (widget.onSearch != null)
                      Flexible(
                        flex: 4,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: narrow
                                ? 170
                                : (width * .28).clamp(260.0, 420.0),
                          ),
                          child: _SearchField(
                            narrow: narrow,
                            onTap: widget.onSearch!,
                          ),
                        ),
                      ),
                    const Spacer(),
                  ],
                ),
              ],
            ),
          ),
          ?widget.status,
          const SizedBox(width: 8),
          ?widget.trailing,
          const SizedBox(width: 4),
          _WindowButton('最小化', Icons.remove_rounded, windowManager.minimize),
          _WindowButton(
            maximized ? '还原' : '最大化',
            maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
            () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
              await refresh();
            },
            iconSize: maximized ? 12 : 13,
          ),
          _WindowButton('关闭', Icons.close_rounded, requestClose, close: true),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.narrow, required this.onTap});
  final bool narrow;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Semantics(
      button: true,
      label: '命令面板',
      child: Tooltip(
        message: '命令面板（Ctrl+K）',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('desk-command-search'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(7),
            child: Ink(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: d.surface,
                borderRadius: BorderRadius.circular(7),
                boxShadow: d.shadow1,
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 16, color: d.ink3),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      narrow ? '搜索' : '搜索命令与页面',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(12.5, c: d.ink3),
                    ),
                  ),
                  if (!narrow) const Kbd('Ctrl K'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton(
    this.name,
    this.icon,
    this.action, {
    this.iconSize = 16,
    this.close = false,
  });
  final String name;
  final IconData icon;
  final VoidCallback action;
  final double iconSize;
  final bool close;
  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final danger = widget.close && hover;
    return Tooltip(
      message: widget.name,
      child: MouseRegion(
        onEnter: (_) => setState(() => hover = true),
        onExit: (_) => setState(() => hover = false),
        child: Semantics(
          button: true,
          label: widget.name,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.action,
            child: Container(
              width: 46,
              height: double.infinity,
              color: danger
                  ? const Color(0xFFC42B1C)
                  : hover
                  ? d.ink.withValues(alpha: .06)
                  : null,
              child: Icon(
                widget.icon,
                size: widget.iconSize,
                color: danger ? Colors.white : d.ink2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
