// 问题队列（CHK-037、CHK-038）：按总数虚拟滚动，每 50 条一页按需读取，最多保留 4 页。
// 条目显示级别色点、标题、类型与行号；已有结论的条目变淡并标出结论，待核对为默认不另标。
// 按“要做的事”分组（CHK-053）：Rust 已按 认全 → 去重 → 归位 排序，分组位置由各类别计数推出；
// 组头可折叠，折叠只影响显示，不改变分页读取。
import 'package:flutter/material.dart';

import '../../application/chapter_service.dart';
import '../tokens.dart';
import '../widgets.dart';

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
    this.enabled = true,
  });
  final ChapterIssuePage initial;
  final Future<ChapterIssuePage> Function(int offset) read;
  final void Function(ChapterIssuePage page, ChapterIssue issue) onSelect;
  final String? selectedId;
  final bool enabled;
  @override
  State<IssueResultList> createState() => _IssueResultListState();
}

/// 一组连续的问题：[start] 为该组第一项在结果中的序号。
class _Segment {
  const _Segment(this.group, this.start, this.count);
  final int group, start, count;
}

class _IssueResultListState extends State<IssueResultList> {
  final pages = <int, ChapterIssuePage>{};
  final pending = <int>{}, failed = <int>{};
  final scroll = ScrollController();
  final collapsed = <int>{};
  late final List<_Segment> segments = _segments(widget.initial);

  /// 由当前筛选结果的类别计数推出分组；与总数对不上时不分组（按原列表显示）。
  static List<_Segment> _segments(ChapterIssuePage page) {
    final counts = List.filled(chapterIssueGroups.length, 0);
    for (final e in page.filteredCategoryCounts.entries) {
      counts[chapterIssueGroupOf(e.key)] += e.value;
    }
    if (counts.fold(0, (a, b) => a + b) != page.total) return const [];
    final result = <_Segment>[];
    var start = 0;
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
      pixels += headerExtent;
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
    final (name, detail) = chapterIssueGroups[group];
    final open = !collapsed.contains(group);
    return InkWell(
      key: ValueKey('check-issue-group-$group'),
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() {
        if (!collapsed.remove(group)) collapsed.add(group);
      }),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 10, 4),
        child: Row(
          children: [
            Icon(
              open ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
              size: 16,
              color: d.ink3,
            ),
            const SizedBox(width: 4),
            Text(name, style: ui(12, w: 650, c: d.ink2)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(11, c: d.ink3),
              ),
            ),
            Text('${s.count}', style: mono(11, c: d.ink3)),
          ],
        ),
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
            return entryAt(flat).$2 == null ? headerExtent : extent;
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
      'confirmed_normal' => '已核实',
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
            opacity: decided == null ? 1 : .55,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      width: 3,
                      height: 30,
                      decoration: BoxDecoration(
                        color: selected ? d.accent : Colors.transparent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Dot(tone, size: 7),
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
                                style: ui(
                                  12.5,
                                  w: selected ? 620 : 520,
                                  c: d.ink,
                                ),
                              ),
                            ),
                            if (decided != null) ...[
                              const SizedBox(width: 6),
                              Text(decided, style: ui(11, c: d.ink3)),
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
