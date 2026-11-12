// 问题队列：按总数虚拟滚动，每 50 条一页按需读取，最多保留 4 页。
// 条目显示级别色点、标题、类型与行号；已有结论的条目变淡并标出结论，待核对为默认不另标。
// 按“要做的事”分组：Rust 已按 认全 → 去重 → 归位 排序，分组位置由各类别计数推出；
// 组头可折叠，折叠只影响显示，不改变分页读取。
// 成片的原因排在最前：一个原因一行，默认收起；点这一行在右边看说明和一次处理的办法，
// 点行尾的箭头展开它名下的问题。
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'cause_copy.dart';

Tone issueTone(String severity) => switch (severity) {
  'error' => Tone.pen,
  'warning' => Tone.warn,
  _ => Tone.info,
};

class IssueResultList extends StatefulWidget {
  const IssueResultList({
    super.key,
    required this.initial,
    required this.read,
    required this.onSelect,
    this.selectedId,
    this.selectedCause,
    this.onCause,
    this.enabled = true,
  });

  /// 当前在右边打开的原因（[ChapterIssueCause.kind]）。
  final String? selectedCause;
  final void Function(ChapterIssueCause cause)? onCause;
  final ChapterIssuePage initial;
  final Future<ChapterIssuePage> Function(int offset) read;
  final void Function(ChapterIssuePage page, ChapterIssue issue) onSelect;
  final String? selectedId;
  final bool enabled;
  @override
  State<IssueResultList> createState() => _IssueResultListState();
}

/// 一组连续的问题：[start] 为该组第一项在结果中的序号。
/// [cause] 不为空时这一组是一个成片的原因，[group] 从 100 起编。
class _Segment {
  const _Segment(this.group, this.start, this.count, [this.cause]);
  final int group, start, count;
  final ChapterIssueCause? cause;
}

class _IssueResultListState extends State<IssueResultList> {
  final pages = <int, ChapterIssuePage>{};
  final pending = <int>{}, failed = <int>{};
  final scroll = ScrollController();
  late final List<_Segment> segments = _segments(widget.initial);

  /// 原因默认收起。
  late final collapsed = <int>{
    for (final s in segments)
      if (s.cause != null) s.group,
  };

  /// 由当前筛选结果的类别计数推出分组；与总数对不上时不分组（按原列表显示）。
  /// 有成片的原因时，它们名下的问题排在最前，各占一组；其余问题按类别计数分组。
  static List<_Segment> _segments(ChapterIssuePage page) {
    final counts = List.filled(chapterIssueGroups.length, 0);
    final causes = page.causes;
    final plain = causes.isEmpty
        ? page.filteredCategoryCounts
        : page.plainCategoryCounts;
    for (final e in plain.entries) {
      counts[chapterIssueGroupOf(e.key)] += e.value;
    }
    final caused = causes.fold(0, (a, c) => a + c.total);
    if (counts.fold(0, (a, b) => a + b) + caused != page.total) return const [];
    final result = <_Segment>[];
    var start = 0;
    for (var i = 0; i < causes.length; i++) {
      result.add(_Segment(100 + i, start, causes[i].total, causes[i]));
      start += causes[i].total;
    }
    for (var g = 0; g < counts.length; g++) {
      if (counts[g] == 0) continue;
      result.add(_Segment(g, start, counts[g]));
      start += counts[g];
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initial.offset % 50 == 0) {
      pages[widget.initial.offset] = widget.initial;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients && widget.initial.offset > 0) {
        scroll.jumpTo(
          pixelsBefore(widget.initial.offset)
              .clamp(0, scroll.position.maxScrollExtent),
        );
      }
    });
  }

  double get extent => 58 * MediaQuery.textScalerOf(context).scale(1);
  double get headerExtent => 34 * MediaQuery.textScalerOf(context).scale(1);

  double headerOf(_Segment s) => s.cause == null ? headerExtent : extent + 4;

  int get flatCount => segments.isEmpty
      ? widget.initial.total
      : segments.fold(
          0,
          (sum, s) => sum + 1 + (collapsed.contains(s.group) ? 0 : s.count),
        );

  /// 列表中第 [flat] 行：组头返回 (组, null)，问题返回 (组, 结果序号)。
  (int?, int?) entryAt(int flat) {
    if (segments.isEmpty) return (null, flat);
    var cursor = 0;
    for (final s in segments) {
      if (flat == cursor) return (s.group, null);
      cursor++;
      final shown = collapsed.contains(s.group) ? 0 : s.count;
      if (flat < cursor + shown) return (s.group, s.start + flat - cursor);
      cursor += shown;
    }
    return (null, null);
  }

  double pixelsBefore(int index) {
    if (segments.isEmpty) return index * extent;
    var pixels = 0.0;
    for (final s in segments) {
      pixels += headerOf(s);
      if (index < s.start + s.count) {
        return collapsed.contains(s.group)
            ? pixels
            : pixels + (index - s.start) * extent;
      }
      if (!collapsed.contains(s.group)) pixels += s.count * extent;
    }
    return pixels;
  }

  Widget header(Desk d, int group) {
    final s = segments.firstWhere((s) => s.group == group);
    final open = !collapsed.contains(group);
    final cause = s.cause;
    if (cause != null) {
      return _CauseRow(
        key: ValueKey('check-cause-${cause.kind}'),
        cause: cause,
        open: open,
        selected: widget.selectedCause == cause.kind,
        onTap: widget.enabled ? () => widget.onCause?.call(cause) : null,
        onToggle: () => setState(() {
          if (!collapsed.remove(group)) collapsed.add(group);
        }),
      );
    }
    final (name, detail) = chapterIssueGroups[group];
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: DeskGroupBanner(
        key: ValueKey('check-issue-group-$group'),
        title: name,
        detail: detail,
        count: s.count,
        open: open,
        onTap: () => setState(() {
          if (!collapsed.remove(group)) collapsed.add(group);
        }),
      ),
    );
  }

  Future<void> load(int offset) async {
    if (!pending.add(offset)) return;
    try {
      final page = await widget.read(offset);
      if (!mounted) return;
      if (page.total != widget.initial.total) {
        throw const FormatException('问题已变化');
      }
      setState(() {
        pages[offset] = page;
        failed.remove(offset);
        while (pages.length > 4) {
          pages.remove(pages.keys.first);
        }
      });
    } catch (_) {
      if (mounted) setState(() => failed.add(offset));
    } finally {
      pending.remove(offset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Scrollbar(
      controller: scroll,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: ListView.builder(
          key: const ValueKey('check-issue-list'),
          controller: scroll,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          itemCount: flatCount,
          itemExtentBuilder: (flat, _) {
            if (flat >= flatCount) return null;
            final (group, entry) = entryAt(flat);
            if (entry != null) return extent;
            return group == null
                ? headerExtent
                : headerOf(segments.firstWhere((s) => s.group == group));
          },
          itemBuilder: (_, flat) {
            final (group, entry) = entryAt(flat);
            if (entry == null) {
              return group == null ? const SizedBox.shrink() : header(d, group);
            }
            final index = entry;
            final offset = index ~/ 50 * 50;
            final page = pages[offset];
            if (page == null) {
              if (!pending.contains(offset) && !failed.contains(offset)) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) load(offset);
                });
              }
              return Center(
                child: failed.contains(offset)
                    ? TextButton(
                        onPressed: () => load(offset),
                        child: const Text('重试读取问题'),
                      )
                    : Text('读取中…', style: ui(12, c: d.ink3)),
              );
            }
            final issue = page.items[index - offset];
            return _QueueItem(
              key: ValueKey('check-issue-${issue.id}'),
              issue: issue,
              selected: widget.selectedId == issue.id,
              onTap: widget.enabled ? () => widget.onSelect(page, issue) : null,
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }
}

/// 一个成片的原因：标题、一句提示、数量；行尾箭头展开名下的问题。
class _CauseRow extends StatelessWidget {
  const _CauseRow({
    super.key,
    required this.cause,
    required this.open,
    required this.selected,
    required this.onTap,
    required this.onToggle,
  });
  final ChapterIssueCause cause;
  final bool open, selected;
  final VoidCallback? onTap;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (tone, soft) = d.tone(Tone.warn);
    final done = cause.open == 0;
    return Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? d.surface : soft.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected ? d.shadow1 : null,
          ),
          child: Opacity(
            opacity: done ? .62 : 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 2, 7),
              child: Row(
                children: [
                  DeskStripe(done ? d.line : tone, height: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                causeTitle(cause),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ui(12.5, w: 650, c: d.ink),
                              ),
                            ),
                            const SizedBox(width: 6),
                            DeskPill(
                              Text(
                                causeCount(cause),
                                style: ui(10.5, w: 600, c: d.ink2),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          done
                              ? '${cause.total} 条都已有结论'
                              : '${cause.total} 条问题 · ${causeHint(cause)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(11.5, c: d.ink2),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: open
                        ? '收起这 ${cause.total} 条'
                        : '展开这 ${cause.total} 条',
                    visualDensity: VisualDensity.compact,
                    onPressed: onToggle,
                    icon: Icon(
                      open
                          ? Icons.expand_more_rounded
                          : Icons.chevron_right_rounded,
                      size: 18,
                      color: d.ink2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueItem extends StatelessWidget {
  const _QueueItem({
    super.key,
    required this.issue,
    required this.selected,
    required this.onTap,
  });
  final ChapterIssue issue;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (tone, _) = d.tone(issueTone(issue.severity));
    final decided = switch (issue.decision) {
      'confirmed_normal' => '核对无误',
      'ignored' => '已忽略',
      _ => null,
    };
    final line = issue.lines.firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? d.surface : null,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected ? d.shadow1 : null,
          ),
          child: Opacity(
            opacity: decided == null ? 1 : .62,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: DeskStripe(
                      decided == null ? tone : (selected ? d.accent : d.line),
                      height: 34,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: EdgeInsets.only(top: decided == null ? 6 : 3),
                    child: decided == null
                        ? Dot(tone, size: 7)
                        : Icon(Icons.check_rounded, size: 13, color: d.add),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                issue.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    ui(
                                      12.5,
                                      w: selected ? 620 : 520,
                                      c: decided == null ? d.ink : d.ink2,
                                    ).copyWith(
                                      decoration: decided == null
                                          ? null
                                          : TextDecoration.lineThrough,
                                      decorationColor: d.ink3,
                                    ),
                              ),
                            ),
                            if (decided != null) ...[
                              const SizedBox(width: 6),
                              DeskPill(
                                Text(
                                  decided,
                                  style: ui(10.5, w: 600, c: d.ink2),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          line == null
                              ? issue.categoryLabel
                              : '${issue.categoryLabel} · 第 $line 行',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(11.5, c: d.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
