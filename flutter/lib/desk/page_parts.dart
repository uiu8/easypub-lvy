// 编辑台页面通用件（设计来源 design_review_v37/d4_*.dart 的 _hdr、_info 与表格卡片）：
// 页头、提示条、浮起卡片、表头。D4 各页共用，避免每页自造。
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 页头：标题、说明与右侧操作；窄窗时操作换到第二行。
class DeskPageHeader extends StatelessWidget {
  const DeskPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.status,
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final Widget? status;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    final lead = [
      Text(title, style: ui(16, w: 650, c: d.ink)),
      if (status != null) ...[const SizedBox(width: 10), status!],
      if (subtitle != null) ...[
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ui(12, c: d.ink3),
          ),
        ),
      ] else
        const Spacer(),
    ];
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide = bounds.maxWidth / scale >= 760;
        return Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: d.line)),
          ),
          child: wide
              ? Row(
                  children: [
                    ...lead,
                    for (final a in actions) ...[const SizedBox(width: 6), a],
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: lead),
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.end,
                        children: actions,
                      ),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

/// 页内提示条：语义色浅底，左图标、文字，右侧可带操作。
class DeskInfoBar extends StatelessWidget {
  const DeskInfoBar(
    this.text, {
    super.key,
    this.tone = Tone.neutral,
    this.action,
    this.icon,
  }) : selectable = false;

  /// 文字可选择复制（错误信息、路径）。
  const DeskInfoBar.selectable(
    this.text, {
    super.key,
    this.tone = Tone.neutral,
    this.action,
    this.icon,
  }) : selectable = true;
  final String text;
  final Tone tone;
  final Widget? action;
  final IconData? icon;
  final bool selectable;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (fg, bg) = tone == Tone.neutral ? (d.ink2, d.sunken) : d.tone(tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      constraints: const BoxConstraints(minHeight: 38),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            icon ??
                (tone == Tone.pen
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded),
            size: 15,
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: ui(12, c: fg, h: 1.45)),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

/// 浮起卡片：表面色、10 圆角、轻阴影，内容裁切；列表项在其中用 Material 承接点按效果。
class DeskCard extends StatelessWidget {
  const DeskCard({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Container(
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: d.shadow1,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: padding == null
            ? child
            : Padding(padding: padding!, child: child),
      ),
    );
  }
}

/// 表头单元：列名用小号半粗三级墨色。
class DeskColumnLabel extends StatelessWidget {
  const DeskColumnLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: ui(11.5, w: 600, c: context.desk.ink3),
  );
}

/// 卡片小节标题：标题 + 可选说明 + 右侧操作。
class DeskSectionTitle extends StatelessWidget {
  const DeskSectionTitle(this.title, {super.key, this.note, this.trailing});
  final String title;
  final String? note;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Row(
      children: [
        Text(title, style: ui(13, w: 650, c: d.ink)),
        if (note != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(11.5, c: d.ink3),
            ),
          ),
        ] else
          const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// 页面纸面：画布底、10 圆角细边，上为页头，下为内容（与书库、排版页同一外框）。
class DeskPageFrame extends StatelessWidget {
  const DeskPageFrame({super.key, required this.header, required this.child});
  final Widget header, child;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Material(
      color: d.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: d.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(child: child),
        ],
      ),
    );
  }
}
