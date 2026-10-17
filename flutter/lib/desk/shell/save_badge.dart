// 自动保存状态（G-030）：位于标题栏右侧；点击立即保存，悬停显示具体信息。
// V15：已保存状态写作“草稿已自动保存”，悬停说明与项目文件的区别（G-066）。
import 'package:flutter/material.dart';

import '../tokens.dart';
import '../widgets.dart';

enum DeskSaveState { saved, pending, saving, failed, session }

class DeskSaveBadge extends StatelessWidget {
  const DeskSaveBadge({
    super.key,
    required this.state,
    this.message = '',
    this.onTap,
    this.compact = false,
  });
  final DeskSaveState state;
  final String message;
  final VoidCallback? onTap;
  final bool compact;

  static String label(DeskSaveState state) => switch (state) {
    DeskSaveState.saved => '草稿已自动保存',
    DeskSaveState.pending => '待保存',
    DeskSaveState.saving => '保存中…',
    DeskSaveState.failed => '保存失败',
    DeskSaveState.session => '当前会话',
  };

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final text = label(state);
    final failed = state == DeskSaveState.failed;
    final Widget mark = switch (state) {
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
    return Tooltip(
      // 草稿自动保存与项目文件是两回事（G-066）：悬停时说明两者的区别。
      message: [
        message.isNotEmpty ? message : text,
        '草稿保存在本机，关闭后再打开可以继续。',
        '项目文件的另存与更新在“书稿概览”中。',
      ].join('\n'),
      child: InkWell(
        key: const ValueKey('desk-save-badge'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              mark,
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
    );
  }
}
