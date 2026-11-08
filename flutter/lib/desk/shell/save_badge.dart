// 自动保存状态（G-030）：位于标题栏右侧，悬停显示具体信息。
// V15：已保存状态写作“草稿已自动保存”，悬停说明与项目文件的区别（G-066）。
// R1：点击打开小浮层——状态、上次保存时间、失败原因、草稿与项目文件的区别、“立即保存”。
import 'package:flutter/material.dart';

import '../controls/controls.dart';
import '../tokens.dart';
import '../widgets.dart';

enum DeskSaveState { saved, pending, saving, failed, session }

class DeskSaveBadge extends StatelessWidget {
  const DeskSaveBadge({
    super.key,
    required this.state,
    this.message = '',
    this.onTap,
    this.savedAt,
    this.compact = false,
  });
  final DeskSaveState state;
  final String message;

  /// 立即保存；为 null 时（本次会话不保存草稿）浮层只做说明。
  final VoidCallback? onTap;
  final DateTime? savedAt;
  final bool compact;

  static String label(DeskSaveState state) => switch (state) {
    DeskSaveState.saved => '草稿已自动保存',
    DeskSaveState.pending => '待保存',
    DeskSaveState.saving => '保存中…',
    DeskSaveState.failed => '保存失败',
    DeskSaveState.session => '当前会话',
  };

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final hms = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    return t.year == now.year && t.month == now.month && t.day == now.day
        ? '今天 $hms'
        : '${t.month}月${t.day}日 $hms';
  }

  Widget _mark(Desk d) => switch (state) {
    DeskSaveState.saved => Dot(d.add),
    DeskSaveState.pending => Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: d.ink3, width: 1.4),
      ),
    ),
    DeskSaveState.saving => SizedBox(
      width: 10,
      height: 10,
      // 定值进度：保存没有可报告的百分比，固定弧段只表示“进行中”，也不阻塞测试稳定。
      child: CircularProgressIndicator(
        strokeWidth: 1.6,
        value: .62,
        color: d.ink2,
        backgroundColor: d.line,
      ),
    ),
    DeskSaveState.failed => Icon(
      Icons.error_outline_rounded,
      size: 14,
      color: d.pen,
    ),
    DeskSaveState.session => Dot(d.ink3),
  };

  Widget _panel(BuildContext context, MenuController controller) {
    final d = context.desk;
    final failed = state == DeskSaveState.failed;
    return Container(
      key: const ValueKey('desk-save-panel'),
      width: 300,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
        boxShadow: d.shadow3,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _mark(d),
              const SizedBox(width: 8),
              Text(
                label(state),
                style: ui(13, w: 650, c: failed ? d.pen : d.ink),
              ),
            ],
          ),
          if (savedAt != null) ...[
            const SizedBox(height: 6),
            Text('上次保存：${_time(savedAt!)}', style: ui(12, c: d.ink2)),
          ],
          if (message.isNotEmpty && message != label(state)) ...[
            const SizedBox(height: 6),
            Text(message, style: ui(12, c: failed ? d.pen : d.ink2, h: 1.5)),
          ],
          const SizedBox(height: 8),
          Text(
            state == DeskSaveState.session
                ? '这次运行没有开启草稿保存，关闭后不会保留未应用的输入。'
                : '草稿保存在本机，关闭后再打开可以继续。项目文件的打开与另存在顶栏右侧的“项目”菜单里。',
            style: ui(12, c: d.ink3, h: 1.5),
          ),
          if (onTap != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: DeskButton(
                failed ? '重试' : '立即保存',
                key: const ValueKey('desk-save-now'),
                primary: failed,
                busy: state == DeskSaveState.saving,
                onPressed: state == DeskSaveState.saving ? null : onTap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final text = label(state);
    final failed = state == DeskSaveState.failed;
    return MenuAnchor(
      alignmentOffset: const Offset(-120, 6),
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      menuChildren: [
        Builder(
          builder: (context) =>
              _panel(context, MenuController.maybeOf(context)!),
        ),
      ],
      builder: (context, controller, _) => Tooltip(
        // 草稿自动保存与项目文件是两回事（G-066）：悬停时说明两者的区别。
        message: [
          message.isNotEmpty ? message : text,
          '草稿保存在本机，关闭后再打开可以继续。',
          '项目文件的打开与另存在顶栏右侧的“项目”菜单里。',
        ].join('\n'),
        child: InkWell(
          key: const ValueKey('desk-save-badge'),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _mark(d),
                if (!compact || failed) ...[
                  const SizedBox(width: 6),
                  Text(
                    text,
                    style: ui(
                      12,
                      w: failed ? 600 : 400,
                      c: failed ? d.pen : d.ink2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
