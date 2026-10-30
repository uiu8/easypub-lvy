// 章节目录（CH-029–036）：全书标题虚拟列表。分页续载；支持整书目录一次读取；
// 搜索标题（忽略大小写）或精确行号；卷可折叠；方向键单步选择；行尾菜单。
import 'dart:async';

import 'package:flutter/material.dart';

import '../errors.dart';

import 'package:flutter/services.dart';

import '../../application/chapter_service.dart';
import '../controls/action_groups.dart';
import 'chapter_view_state.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'issue_marks.dart';

/// 行尾菜单与“更多”菜单共用的十项结构/正文操作（CH-032）。
const chapterRowActions = [
  DeskActionGroup('章节结构', [
    DeskMenuAction('rename', '重命名章节', Icons.edit_outlined),
    DeskMenuAction('volume', '在本章前新增卷', Icons.bookmark_add_outlined),
    DeskMenuAction('split', '拆分章节', Icons.call_split_rounded),
    DeskMenuAction('merge', '合并章节', Icons.merge_rounded),
    DeskMenuAction('move', '移动章节', Icons.swap_vert_rounded),
  ]),
  DeskActionGroup('正文与标题', [
    DeskMenuAction('boundary', '正文行设为标题', Icons.title_rounded),
    DeskMenuAction('demote', '标题改为正文（保留文字）', Icons.text_snippet_outlined),
    DeskMenuAction('duplicate', '移除重复标题（保留正文）', Icons.layers_clear_outlined),
    DeskMenuAction('compare', '对比两章正文', Icons.compare_outlined),
    DeskMenuAction('deleteBody', '删除正文行', Icons.delete_outline_rounded),
  ]),
];

class ChapterOutline extends StatefulWidget {
  const ChapterOutline({
    super.key,
    required this.session,
    required this.snapshot,
    required this.selectedId,
    required this.enabled,
    required this.onSelect,
    required this.onMenu,
    this.viewState,
    this.restoreNavigation = true,
    this.searchFocus,
    this.leading,
    this.issueMap,
    this.issueStatus = '',
    this.onRetryIssues,
    this.titleTrailing,
  });

  /// “目录”标题右侧的入口（V23：识别规则摘要，CH-261）。
  final Widget? titleTrailing;

  /// 全书问题位置（CH-234–236）；与 [snapshot] 不同版本时不显示。
  final ChapterIssueMap? issueMap;

  /// 'loading' 汇总中，'error' 读取失败，空串为正常。
  final String issueStatus;
  final VoidCallback? onRetryIssues;
  final ChapterTreeViewState? viewState;
  final bool restoreNavigation;
  final FocusNode? searchFocus;
  final ChapterSession session;
  final ChapterPage snapshot;
  final String? selectedId;
  final bool enabled;
  final Future<void> Function(ChapterPage, ChapterNode) onSelect;
  final Future<void> Function(ChapterPage, ChapterNode, String) onMenu;

  /// 列表上方的固定入口（卷前正文）。
  final Widget? leading;
  @override
  State<ChapterOutline> createState() => _ChapterOutlineState();
}

class _ChapterOutlineState extends State<ChapterOutline> {
  final nodes = <ChapterNode>[];
  final owners = <String, ChapterPage>{};
  late final view = widget.viewState ?? ChapterTreeViewState();
  Set<String> get collapsed => view.collapsed;
  final scroll = ScrollController();
  final queryController = TextEditingController();
  final keyboardFocus = FocusNode(debugLabel: 'chapter-tree');
  Timer? debounce;
  int generation = 0, total = 0;
  bool loading = false;
  Future<void>? activeRead;
  String error = '', query = '';
  late String guard;

  double get rowExtent => 32 * MediaQuery.textScalerOf(context).scale(1);

  @override
  void initState() {
    super.initState();
    query = view.query;
    queryController.text = query;
    scroll.addListener(rememberScroll);
    reset(restore: widget.restoreNavigation && view.loadedNodes > 0);
  }

  void rememberScroll() => view.scrollOffset = scroll.offset;

  @override
  void didUpdateWidget(ChapterOutline old) {
    super.didUpdateWidget(old);
    if (widget.snapshot.guard != guard || old.session != widget.session) {
      reset();
    } else if (old.selectedId != widget.selectedId) {
      revealSelected();
    }
  }

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    scroll.dispose();
    queryController.dispose();
    keyboardFocus.dispose();
    super.dispose();
  }

  void reset({bool restore = false}) {
    generation++;
    debounce?.cancel();
    loading = false;
    error = '';
    guard = widget.snapshot.guard;
    total = widget.snapshot.total;
    nodes.clear();
    owners.clear();
    final savedNodes = view.loadedNodes;
    final savedOffset = view.scrollOffset;
    if (widget.snapshot.offset == 0) append(widget.snapshot);
    revealSelected(
      restoreNodes: restore ? savedNodes : null,
      restoreOffset: savedOffset,
    );
  }

  void revealSelected({int? restoreNodes, double restoreOffset = 0}) {
    final ticket = generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || ticket != generation) return;
      await more(
        until: restoreNodes == null
            ? widget.snapshot.offset + widget.snapshot.nodes.length
            : (query.trim().isNotEmpty ? total : restoreNodes.clamp(0, total)),
      );
      if (!mounted || ticket != generation) return;
      if (restoreNodes != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || ticket != generation || !scroll.hasClients) return;
          scroll.jumpTo(
            restoreOffset.clamp(0, scroll.position.maxScrollExtent),
          );
        });
        return;
      }
      if (query.isNotEmpty &&
          !visible().any((n) => n.id == widget.selectedId)) {
        queryController.clear();
        setState(() => view.query = query = '');
      }
      final ancestors = <ChapterNode>[];
      for (final node in nodes) {
        while (ancestors.isNotEmpty && ancestors.last.depth >= node.depth) {
          ancestors.removeLast();
        }
        if (node.id == widget.selectedId) {
          setState(() {
            for (final parent in ancestors) {
              collapsed.remove(parent.id);
            }
          });
          break;
        }
        ancestors.add(node);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ticket != generation || !scroll.hasClients) return;
        final index = visible().indexWhere((n) => n.id == widget.selectedId);
        if (index < 0) return;
        final extent = rowExtent;
        final position = index * extent;
        if (position < scroll.offset ||
            position + extent >
                scroll.offset + scroll.position.viewportDimension) {
          scroll.jumpTo(position.clamp(0, scroll.position.maxScrollExtent));
        }
      });
    });
  }

  void append(ChapterPage page) {
    if (page.guard != guard ||
        page.offset != nodes.length ||
        page.total != total ||
        (page.nodes.isEmpty && page.offset < total)) {
      throw const FormatException('章节结构已变化，请刷新结构。');
    }
    nodes.addAll(page.nodes);
    view.loadedNodes = nodes.length;
    for (final node in page.nodes) {
      owners[node.id] = page;
    }
  }

  Future<void> more({int? until}) async {
    if (!mounted || (until != null && nodes.length >= until)) return;
    final running = activeRead;
    if (running != null) {
      await running;
      if (until != null && mounted) await more(until: until);
      return;
    }
    final work = readMore(until: until);
    activeRead = work;
    try {
      await work;
    } finally {
      if (identical(activeRead, work)) activeRead = null;
    }
  }

  Future<void> readMore({int? until}) async {
    if (loading || nodes.length >= total || error.isNotEmpty) return;
    final ticket = generation;
    setState(() => loading = true);
    try {
      final session = widget.session;
      if (session is ChapterOutlineSession && total <= maxChapterOutlineNodes) {
        final outline = await (session as ChapterOutlineSession).readOutline();
        if (!mounted || ticket != generation) return;
        if (outline.guard != guard ||
            outline.offset != 0 ||
            outline.total != total ||
            outline.nodes.length != total) {
          throw const FormatException('章节结构已变化，请刷新结构。');
        }
        setState(() {
          nodes.clear();
          owners.clear();
          nodes.addAll(outline.nodes);
          view.loadedNodes = nodes.length;
          // 编辑与刷新仍按 30 个节点一页归属；选中靠后的章节后编辑不会回到首页。
          for (var offset = 0; offset < nodes.length; offset += 30) {
            final page = ChapterPage(
              nodes.sublist(offset, (offset + 30).clamp(0, nodes.length)),
              total,
              offset,
              guard,
              editBudget: outline.editBudget,
            );
            for (final node in page.nodes) {
              owners[node.id] = page;
            }
          }
        });
        return;
      }
      do {
        final result = await widget.session.read(nodes.length);
        if (!mounted || ticket != generation) return;
        setState(() => append(result));
      } while (nodes.length < total &&
          (query.trim().isNotEmpty || (until != null && nodes.length < until)));
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() {
          error = deskErrorText(e, '章节读取失败，可重试继续。');
        });
      }
    } finally {
      if (mounted && ticket == generation) setState(() => loading = false);
    }
  }

  List<ChapterNode> visible() {
    final needle = query.trim().toLowerCase();
    if (needle.isNotEmpty) {
      return nodes
          .where(
            (n) =>
                n.title.toLowerCase().contains(needle) ||
                n.line.toString() == needle,
          )
          .toList();
    }
    int? hiddenDepth;
    final result = <ChapterNode>[];
    for (final node in nodes) {
      if (hiddenDepth != null && node.depth > hiddenDepth) continue;
      hiddenDepth = null;
      if (node.role == 'volume' && collapsed.contains(node.id)) {
        hiddenDepth = node.depth;
      }
      result.add(node);
    }
    return result;
  }

  void search(String text) {
    debounce?.cancel();
    setState(() => view.query = query = text);
    debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted && query.trim().isNotEmpty) more();
    });
  }

  KeyEventResult navigate(KeyEvent event, List<ChapterNode> shown) {
    if (event is! KeyDownEvent ||
        !widget.enabled ||
        shown.isEmpty ||
        FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      return KeyEventResult.ignored;
    }
    final index = shown.indexWhere((n) => n.id == widget.selectedId);
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final target = index < 0
          ? 0
          : (index +
                    (event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1))
                .clamp(0, shown.length - 1);
      final node = shown[target];
      widget.onSelect(owners[node.id]!, node);
      return KeyEventResult.handled;
    }
    if (index >= 0 &&
        shown[index].role == 'volume' &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      setState(() {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          collapsed.add(shown[index].id);
        } else {
          collapsed.remove(shown[index].id);
        }
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void toggle(ChapterNode node) => setState(() {
    if (!collapsed.add(node.id)) collapsed.remove(node.id);
  });

  Future<void> openMenu(BuildContext anchor, ChapterNode node) async {
    final value = await showDeskActionGroups(
      anchor,
      title: node.title,
      groups: chapterRowActions,
    );
    if (mounted && value != null) {
      widget.onMenu(owners[node.id]!, node, value);
    }
  }

  /// 刻度条点在空白处：按比例把目录滚到该行附近（居中）。
  void jumpToRow(int row) {
    if (!scroll.hasClients) return;
    final target = row * rowExtent - scroll.position.viewportDimension / 2;
    scroll.jumpTo(target.clamp(0, scroll.position.maxScrollExtent));
  }

  Widget issueSummary(Desk d, ChapterIssueMap? map) {
    if (widget.issueStatus == 'error') {
      return TextButton(
        key: const ValueKey('chapter-issue-retry'),
        style: TextButton.styleFrom(
          foregroundColor: d.pen,
          minimumSize: const Size(0, 24),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        onPressed: widget.onRetryIssues,
        child: const Text('问题分布读取失败 · 重试'),
      );
    }
    if (map == null) {
      return Text(
        widget.issueStatus == 'loading' ? '正在汇总问题…' : '',
        style: ui(11, c: d.ink3),
      );
    }
    if (map.open == 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Dot(d.tone(Tone.ok).$1, size: 6),
          const SizedBox(width: 5),
          Text(map.total == 0 ? '未发现结构问题' : '问题均已审阅', style: ui(11, c: d.ink3)),
        ],
      );
    }
    final parts = [
      for (final level in const ['error', 'warning', 'info'])
        if ((map.openSeverities[level] ?? 0) > 0)
          (level, map.openSeverities[level]!),
    ];
    return Tooltip(
      message:
          '未处理的结构问题：${parts.map((p) => '${chapterIssueSeverities[p.$1]} ${p.$2}').join('，')}',
      child: Row(
        key: const ValueKey('chapter-issue-counts'),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (level, count) in parts) ...[
            Dot(severityTone(d, level).$1, size: 6),
            const SizedBox(width: 4),
            Text('$count', style: ui(11.5, c: d.ink2)),
            const SizedBox(width: 9),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final shown = visible();
    final hasMore = nodes.length < total;
    final map = widget.issueMap?.guard == guard ? widget.issueMap : null;
    final marks = map?.marks ?? const <String, ChapterIssueMark>{};
    final spine = map != null && map.total > 0;
    // 刻度按可见行排列；折叠卷内章节的问题画在卷那一行。搜索时只画匹配行。
    final spineMarks = <SpineMark>[];
    if (spine) {
      var row = -1, next = 0;
      for (final node in query.trim().isEmpty ? nodes : shown) {
        if (next < shown.length && identical(shown[next], node)) row = next++;
        final m = marks[node.id];
        if (m != null && row >= 0) {
          spineMarks.add(SpineMark(row, m.severity, m.open > 0));
        }
      }
    }
    return Focus(
      key: const ValueKey('chapter-tree-keyboard'),
      focusNode: keyboardFocus,
      onKeyEvent: (_, event) => navigate(event, shown),
      child: Material(
        color: d.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
              child: Row(
                children: [
                  Text('目录', style: ui(13, w: 650, c: d.ink)),
                  if (widget.titleTrailing != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: widget.titleTrailing!,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: TextField(
                controller: queryController,
                focusNode: widget.searchFocus,
                style: ui(13, c: d.ink),
                decoration: InputDecoration(
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: d.ink3,
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 34),
                  suffixIcon: const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Kbd('Ctrl F'),
                  ),
                  suffixIconConstraints: const BoxConstraints(),
                  hintText: '搜索全书标题或行号',
                  hintStyle: ui(13, c: d.ink3),
                ),
                onChanged: search,
              ),
            ),
            if (widget.leading != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 2),
                child: widget.leading,
              ),
            SizedBox(
              height: 2,
              child: query.isNotEmpty && loading
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null,
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: list(shown, hasMore, marks, spine)),
                  if (spine)
                    Positioned(
                      right: 5,
                      top: 4,
                      bottom: 8,
                      width: 8,
                      child: IssueSpine(
                        marks: spineMarks,
                        rows: shown.length,
                        rowExtent: rowExtent,
                        scroll: scroll,
                        onJump: jumpToRow,
                        onMark: (row) {
                          if (!widget.enabled || row >= shown.length) return;
                          jumpToRow(row);
                          final node = shown[row];
                          widget.onSelect(owners[node.id]!, node);
                        },
                      ),
                    ),
                ],
              ),
            ),
            Container(
              height: 30,
              padding: const EdgeInsets.only(left: 12, right: 14),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: d.line)),
              ),
              child: Row(
                children: [
                  issueSummary(d, map),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      textAlign: TextAlign.right,
                      query.trim().isEmpty
                          ? '共 $total 个标题'
                          : '${shown.length} 个匹配 · 已查 ${nodes.length}/$total',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(11, c: d.ink3),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget list(
    List<ChapterNode> shown,
    bool hasMore,
    Map<String, ChapterIssueMark> marks,
    bool spine,
  ) => ListView.builder(
    key: const ValueKey('continuous-chapter-list'),
    controller: scroll,
    padding: EdgeInsets.only(left: 6, right: spine ? 18 : 6),
    itemExtentBuilder: (index, _) => index < shown.length
        ? rowExtent
        : error.isNotEmpty
        ? 150
        : 70,
    itemCount: shown.length + (hasMore || error.isNotEmpty ? 1 : 0),
    itemBuilder: (_, index) {
      if (index == shown.length) {
        if (hasMore && !loading && error.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) more();
          });
        }
        return _LoadTail(
          error: error,
          onRetry: () {
            setState(() => error = '');
            more();
          },
        );
      }
      final node = shown[index];
      return _OutlineRow(
        key: ValueKey('tree-node-${node.id}'),
        node: node,
        selected: node.id == widget.selectedId,
        collapsed: collapsed.contains(node.id),
        enabled: widget.enabled,
        onTap: () => widget.onSelect(owners[node.id]!, node),
        onToggle: () => toggle(node),
        onMenu: (anchor) => openMenu(anchor, node),
        mark: marks[node.id],
      );
    },
  );
}

class _OutlineRow extends StatelessWidget {
  const _OutlineRow({
    super.key,
    required this.node,
    required this.selected,
    required this.collapsed,
    required this.enabled,
    required this.onTap,
    required this.onToggle,
    required this.onMenu,
    this.mark,
  });
  final ChapterIssueMark? mark;
  final ChapterNode node;
  final bool selected, collapsed, enabled;
  final VoidCallback onTap, onToggle;
  final void Function(BuildContext anchor) onMenu;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final volume = node.role == 'volume';
    // 性能：滚动时每帧要新建多行。行内不再各自放 Material/Ink/Stack，悬停反馈画在目录面板的
    // Material 上；只有选中行加浅底与左侧竖条。
    final content = Padding(
      padding: EdgeInsets.only(
        left: 4 + node.depth.clamp(0, 4) * 12.0,
        right: 2,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: volume
                ? _RowButton(
                    tooltip: collapsed ? '展开卷' : '收起卷',
                    icon: collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                    size: 17,
                    onPressed: onToggle,
                  )
                : null,
          ),
          if (volume) ...[
            DeskPill(
              Text('卷', style: ui(10, w: 650, c: d.ink2, h: 1.15)),
              color: selected ? d.surface : d.paper,
              outlined: true,
              padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1),
            ),
            const SizedBox(width: 5),
          ],
          Expanded(
            child: Tooltip(
              message: node.title,
              waitDuration: const Duration(milliseconds: 800),
              child: Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(
                  12.5,
                  w: volume ? 620 : (selected ? 600 : 450),
                  c: selected || volume ? d.ink : d.ink2,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (mark != null && mark!.open > 0) ...[
            Semantics(
              label: '${mark!.open} 个未处理问题',
              child: Dot(severityTone(d, mark!.severity).$1, size: 6),
            ),
            const SizedBox(width: 6),
          ],
          Text('${node.line}', style: mono(10.5, c: d.ink3)),
          Builder(
            builder: (anchor) => _RowButton(
              tooltip: '章节菜单',
              icon: Icons.more_horiz_rounded,
              onPressed: enabled ? () => onMenu(anchor) : null,
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        hoverColor: d.ink.withValues(alpha: .04),
        child: !selected
            ? (volume
                  ? DecoratedBox(decoration: d.banner, child: content)
                  : content)
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: d.accentSoft,
                  borderRadius: BorderRadius.circular(6),
                  border: volume
                      ? Border.all(color: d.lineStrong, width: .8)
                      : null,
                ),
                child: Stack(
                  children: [
                    content,
                    Positioned(
                      left: 0,
                      top: 7,
                      bottom: 7,
                      child: DeskStripe(d.accent, width: 2.5),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 目录行内的小图标按钮。滚动时每帧会新建许多行，这里不用 IconButton（自带 Material、
/// 主题动画与按钮状态机），只用 InkResponse；提示文字、读屏语义与键盘焦点保留。
class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 16,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        child: InkResponse(
          onTap: onPressed,
          radius: 13,
          child: SizedBox(
            width: 24,
            height: 26,
            child: Icon(
              icon,
              size: size,
              color: onPressed == null ? d.line : d.ink3,
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadTail extends StatelessWidget {
  const _LoadTail({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    if (error.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error, style: ui(12, c: d.pen)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onRetry,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.refresh_rounded, size: 16),
                SizedBox(width: 6),
                Text('重试加载'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
