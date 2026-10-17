// 自适应导航栏（G-005–018）：宽窗（≥1440 逻辑像素）展开为图标+文字，其余为
// 图标在上、短名在下；窗口不够高时只留图标（悬停提示全名），再不够时可滚动。
import 'package:flutter/material.dart';

import '../tokens.dart';
import '../widgets.dart';

class DeskRailEntry {
  const DeskRailEntry({
    required this.label,
    required this.icon,
    required this.onTap,
    this.shortLabel,
    this.selected = false,
    this.shortcut,
    this.badge,
    this.badgeTone = Tone.neutral,
    this.dot,
    this.dotNote,
  });

  /// 全名用于悬停提示与读屏；短名用于紧凑栏。
  final String label;
  final String? shortLabel, shortcut, badge;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;
  final Tone badgeTone;

  /// 无数字时的状态点（例如“检查”有待核对项）；[dotNote] 进入悬停提示与读屏。
  final Tone? dot;
  final String? dotNote;
}

class DeskRail extends StatelessWidget {
  const DeskRail({
    super.key,
    required this.top,
    required this.book,
    required this.bookEntries,
    required this.output,
    required this.bottom,
  });
  final List<DeskRailEntry> top, bookEntries, output, bottom;
  final Widget Function(bool expanded) book;

  static bool expandedFor(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    return MediaQuery.sizeOf(context).width / scale >= 1440;
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    final expanded = expandedFor(context);
    final height = MediaQuery.sizeOf(context).height / scale;
    final short = height < 780, tiny = height < 700;
    Widget item(DeskRailEntry e) =>
        _RailItem(entry: e, expanded: expanded, short: short, tiny: tiny);
    Widget group(String title) => expanded
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 0, 6),
            child: Text(
              title,
              style: ui(11, w: 600, c: d.ink3).copyWith(letterSpacing: .4),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
            child: Container(height: 1, color: d.line),
          );
    return Container(
      key: const ValueKey('desk-rail'),
      width: (expanded ? 212 : 64) * scale,
      decoration: BoxDecoration(
        color: d.rail,
        border: Border(right: BorderSide(color: d.line)),
      ),
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: expanded ? 10 : 6,
              vertical: 10,
            ),
            sliver: SliverFillRemaining(
              hasScrollBody: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final e in top) item(e),
                  const SizedBox(height: 8),
                  book(expanded),
                  for (final e in bookEntries) item(e),
                  group('输出'),
                  for (final e in output) item(e),
                  const Spacer(),
                  for (final e in bottom) item(e),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.entry,
    required this.expanded,
    required this.short,
    required this.tiny,
  });
  final DeskRailEntry entry;
  final bool expanded, short, tiny;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final on = entry.selected;
    final (tc, tb) = d.tone(entry.badgeTone);
    final fg = on ? d.ink : d.ink2;
    final badge = entry.badge;
    final Widget body;
    if (expanded) {
      body = SizedBox(
        height: 32,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(entry.icon, size: 17, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(13, w: on ? 620 : 480, c: fg),
                ),
              ),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: entry.badgeTone == Tone.neutral ? null : tb,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    badge,
                    style: ui(
                      11,
                      w: 620,
                      c: entry.badgeTone == Tone.neutral ? d.ink3 : tc,
                    ),
                  ),
                )
              else if (entry.dot != null)
                Dot(d.tone(entry.dot!).$1, size: 6)
              else if (entry.shortcut != null && on)
                Text(entry.shortcut!, style: mono(10, c: d.ink3)),
            ],
          ),
        ),
      );
    } else {
      body = SizedBox(
        height: tiny ? 33 : (short ? 38 : 44),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.icon, size: 19, color: fg),
                  if (!short) ...[
                    const SizedBox(height: 3),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          entry.shortLabel ?? entry.label,
                          maxLines: 1,
                          style: ui(10.5, w: on ? 620 : 480, c: fg),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (badge != null && entry.badgeTone != Tone.neutral)
              Positioned(
                right: 3,
                top: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: tc,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badge,
                    style: ui(
                      9.5,
                      w: 700,
                      c: entry.badgeTone == Tone.accent
                          ? d.accentInk
                          : (d.dark ? d.canvas : Colors.white),
                    ),
                  ),
                ),
              )
            else if (entry.dot != null)
              Positioned(
                right: 12,
                top: short ? 7 : 8,
                child: Dot(d.tone(entry.dot!).$1, size: 6),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        selected: on,
        button: true,
        label: entry.label,
        value: entry.dotNote,
        excludeSemantics: true,
        child: Tooltip(
          // 提示只写功能全名；快捷键显示在展开栏选中项尾部与命令面板中。
          message: entry.label,
          child: Material(
            type: MaterialType.transparency,
            child: Ink(
              decoration: BoxDecoration(
                color: on ? d.surface : null,
                borderRadius: BorderRadius.circular(8),
                boxShadow: on ? d.shadow1 : null,
              ),
              child: InkWell(
                onTap: entry.onTap,
                borderRadius: BorderRadius.circular(8),
                hoverColor: d.ink.withValues(alpha: .04),
                child: body,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 当前书卡（G-018）：展开时显示封面、书名、作者；点击打开选书。
class DeskBookSwitch extends StatelessWidget {
  const DeskBookSwitch({
    super.key,
    required this.expanded,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.cover,
  });
  final bool expanded;
  final String? title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? cover;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final has = title != null;
    final mark =
        cover ??
        (has
            ? BookMonogram(title!)
            : Container(
                width: 30,
                height: 42,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: d.lineStrong),
                ),
                child: Icon(Icons.add_rounded, size: 16, color: d.ink3),
              ));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: title ?? '选择书稿',
        child: Material(
          color: d.surface.withValues(alpha: d.dark ? .6 : .7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
            side: BorderSide(color: d.line),
          ),
          child: InkWell(
            key: const ValueKey('workspace-book-picker'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(9),
            child: Padding(
              padding: EdgeInsets.all(expanded ? 8 : 4),
              child: expanded
                  ? Row(
                      children: [
                        mark,
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title ?? '未选择书稿',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: has
                                    ? serif(14, w: 650, c: d.ink)
                                    : ui(13, w: 560, c: d.ink2),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ui(11, c: d.ink3),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.unfold_more_rounded,
                          size: 16,
                          color: d.ink3,
                        ),
                      ],
                    )
                  : Center(child: mark),
            ),
          ),
        ),
      ),
    );
  }
}
