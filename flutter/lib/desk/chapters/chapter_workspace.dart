// 章节工作区（CH-001–044）：目录 + 纸面正文 + 检查器。
// 所有结构修改都经现有弹窗生成预览、确认后写入并可撤销；本页只组织入口与视图。
// 设计：design/review-20261010-v37-flutter/d2（D2-A、D2-B）；docs/37 第 6 节 V2 行的证据。
import 'package:flutter/material.dart';

import '../errors.dart';

import 'package:flutter/services.dart';

import '../../application/block_annotation_service.dart';
import '../../application/inline_style_service.dart';
import '../../application/manual_note_service.dart';
import '../../application/chapter_rules_service.dart';
import '../../application/chapter_service.dart';
import '../../application/library_service.dart';
import '../../application/rule_catalog_service.dart';
import '../../application/workspace_autosave_service.dart';
import '../controls/action_groups.dart';
import '../controls/controls.dart';
import 'dialogs/body_compare_dialog.dart';
import 'dialogs/body_delete_dialog.dart';
import 'dialogs/checkpoint_dialog.dart';
import '../checks/chapter_issues_panel.dart';
import 'dialogs/title_dialogs.dart';
import '../rules/rules_sheet.dart';
import '../rules/numeric_dialog.dart';
import '../rules/rules_summary.dart';
import 'dialogs/split_dialog.dart';
import 'dialogs/target_dialog.dart';
import 'chapter_view_state.dart';
import '../history/change_history_page.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'block_marks.dart';
import 'inline_style_marks.dart';
import 'layout_view.dart';
import 'note_marks.dart';
import 'manuscript.dart';
import 'outline.dart';
import 'style_segments.dart';
import 'workspace_layout.dart';

class ChapterWorkspace extends StatefulWidget {
  const ChapterWorkspace({
    super.key,
    required this.library,
    required this.bookId,
    this.onRepair,
    this.onRepairIssue,
    this.onCatalog,
    this.onCatalogRepair,
    this.onNumericHeadings,
    this.initialNodeId,
    this.initialOffset = 0,
    this.initialBodyOffset = 0,
    this.initialFocusLine,
    this.initialIssues = false,
    this.viewState,
  });
  final LibraryService library;
  final ChapterViewState? viewState;
  final bool initialIssues;
  final String bookId;
  final int initialBodyOffset;
  final int? initialFocusLine;
  final void Function(bool guided)? onRepair;
  final void Function(ChapterIssue)? onRepairIssue;
  final VoidCallback? onCatalog;

  /// 一键目录修复（CH-245）：参考目录页的一键流程。
  final VoidCallback? onCatalogRepair;
  final VoidCallback? onNumericHeadings;
  final String? initialNodeId;
  final int initialOffset;
  @override
  State<ChapterWorkspace> createState() => _ChapterWorkspaceState();
}

class _ChapterWorkspaceState extends State<ChapterWorkspace> {
  late final ChapterSession session = widget.library.openChapters(
    widget.bookId,
  );

  /// 手工标注（V53，LAY-123）：书库提供标注能力时才有。
  late final BlockMarkController? marks = switch (widget.library) {
    final BlockAnnotationLibrary library => BlockMarkController(
      library.openBlockAnnotations(widget.bookId),
    ),
    _ => null,
  };

  /// 手工注释（V62，LAY-128）：书库提供注释能力时才有。
  late final NoteMarkController? noteMarks = switch (widget.library) {
    final ManualNoteLibrary library => NoteMarkController(
      library.openManualNotes(widget.bookId),
    ),
    _ => null,
  };

  /// 文字样式（V106，LAY-152）：书库提供样式能力时才有。
  late final InlineStyleController? inlineStyles = switch (widget.library) {
    final InlineStyleLibrary library => InlineStyleController(
      library.openInlineStyles(widget.bookId),
    ),
    _ => null,
  };

  /// 排版视图（V104，LAY-149）：打开时才创建，统计整本书的识别结果；关掉时释放。
  ChapterLayoutView? layoutView;

  void setLayoutMode(bool on) {
    setState(() {
      view.layoutView = on;
      if (on) {
        layoutView ??= ChapterLayoutView(
          rules: widget.library as RuleCatalogLibrary,
          library: widget.library,
          bookId: widget.bookId,
        );
      } else {
        layoutView?.dispose();
        layoutView = null;
        marks?.clearSelection();
      }
    });
    // 正文整块重建：从当前读到的行重新读入，停在原来的位置。
    if (page != null && selected != null) {
      read(page!.offset, bodyOffset: continuousOffset ?? body?.offset ?? 0);
    }
  }

  ChapterPage? page;
  ChapterBody? body;
  ChapterNode? selected;
  String message = '';
  bool busy = false;
  bool showIssues = false, showHistory = false;
  bool visitedIssues = false, visitedHistory = false;
  int generation = 0;
  final treeSearchFocus = FocusNode();
  late final view = widget.viewState ?? ChapterViewState();
  final layoutKey = GlobalKey<DeskChapterLayoutState>();

  /// 工作区内容宽度；工具栏据此决定是否显示目录/检查器开关（与分栏断点一致）。
  double workspaceWidth = 0;
  String? get preferredNodeId =>
      selected?.id ?? widget.initialNodeId ?? view.nodeId;

  @override
  void initState() {
    super.initState();
    final explicitTarget = widget.initialNodeId != null;
    showIssues = widget.initialIssues || (!explicitTarget && view.tab == 1);
    showHistory = !widget.initialIssues && !explicitTarget && view.tab == 2;
    visitedIssues = showIssues;
    visitedHistory = showHistory;
    continuousScroll = explicitTarget ? 0 : view.bodyScrollOffset;
    // 上次停在排版视图时照旧打开（V104）。
    if (view.layoutView && widget.library is RuleCatalogLibrary) {
      layoutView = ChapterLayoutView(
        rules: widget.library as RuleCatalogLibrary,
        library: widget.library,
        bookId: widget.bookId,
      );
    }
    read(
      explicitTarget ? widget.initialOffset : view.offset,
      bodyOffset: explicitTarget ? widget.initialBodyOffset : view.bodyOffset,
    );
  }

  @override
  void dispose() {
    generation++;
    marks?.dispose();
    noteMarks?.dispose();
    inlineStyles?.dispose();
    layoutView?.dispose();
    treeSearchFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 读取与编辑流程
  // 与 V1 前的章节页逐行对应；只改视图，不改会话调用顺序与刷新规则。

  Future<void> run(Future<void> Function(int) operation) async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await operation(ticket);
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(
          () => message = deskErrorText(
            e,
            '章节没有改成：书稿可能已在别处变化。重新打开本章后再试，已有内容不受影响。',
          ),
        );
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  int? continuousOffset;
  double continuousScroll = 0;
  void rememberView() {
    view.nodeId = selected?.id;
    view.offset = page?.offset ?? view.offset;
    view.bodyOffset = continuousOffset ?? body?.offset ?? 0;
    view.bodyScrollOffset = continuousScroll;
    view.tab = showHistory
        ? 2
        : showIssues
        ? 1
        : 0;
  }

  Future<void> read(int offset, {int bodyOffset = 0}) => run((ticket) async {
    var result = await session.read(
      offset,
      includeBody: true,
      preferredNodeId: preferredNodeId,
    );
    if (result.nodes.isEmpty && offset > 0) {
      result = await session.read(
        ((result.total - 1).clamp(0, result.total) ~/ 30) * 30,
        includeBody: true,
        preferredNodeId: selected?.id,
      );
    }
    if (!mounted || ticket != generation) return;
    final node = preferredNodeId == chapterPrefixNode.id || result.total == 0
        ? chapterPrefixNode
        : result.nodes.where((n) => n.id == preferredNodeId).firstOrNull ??
              result.nodes.where((n) => n.role == 'chapter').firstOrNull ??
              result.nodes.firstOrNull;
    if (node?.id != preferredNodeId) bodyOffset = 0;
    setState(() {
      page = result;
      selected = node;
      body = result.bodyNodeId == node?.id && bodyOffset == 0
          ? result.body
          : null;
    });
    if (node != null && body == null) {
      var content = await session.body(result, node.id, bodyOffset);
      if (bodyOffset > 0 && bodyOffset >= content.total) {
        content = await session.body(
          result,
          node.id,
          content.total == 0 ? 0 : ((content.total - 1) ~/ 30) * 30,
        );
      }
      if (mounted && ticket == generation) setState(() => body = content);
    }
    if (mounted && ticket == generation) {
      rememberView();
      refreshIssues();
    }
  });

  Future<void> select(ChapterNode node, {int bodyOffset = 0}) =>
      run((ticket) async {
        setState(() {
          selected = node;
          continuousOffset = null;
          continuousScroll = 0;
          body = null;
        });
        final content = await session.body(page!, node.id, bodyOffset);
        if (mounted && ticket == generation) {
          setState(() => body = content);
          rememberView();
          refreshChapterIssues();
        }
      });

  // ---------------------------------------------------------------- 问题位置（CH-234–240）
  // 后台读取，不置忙碌；书稿版本变化或有更新的请求时丢弃旧结果。读取失败只提示，不显示猜测数据。

  ChapterIssueMap? issueMap, chapterIssues;
  String issueStatus = '';
  int issueTicket = 0, chapterIssueTicket = 0, issuesEpoch = 0;

  Future<void> refreshIssues() async {
    final current = page;
    if (current == null || session is! ChapterIssueMapSession) return;
    final ticket = ++issueTicket;
    chapterIssueTicket++;
    setState(() => issueStatus = 'loading');
    try {
      final map = await (session as ChapterIssueMapSession).issueMap(
        current,
        entryId: selected?.id,
      );
      if (!mounted || ticket != issueTicket || page?.guard != map.guard) return;
      setState(() {
        issueMap = map;
        chapterIssues = map.chapterId == null ? null : map;
        issueStatus = '';
      });
    } catch (_) {
      if (mounted && ticket == issueTicket) {
        setState(() => issueStatus = 'error');
      }
    }
  }

  Future<void> refreshChapterIssues() async {
    final current = page;
    final node = selected;
    if (current == null ||
        node == null ||
        session is! ChapterIssueMapSession ||
        issueMap == null ||
        chapterIssues?.chapterId == node.id &&
            chapterIssues?.guard == current.guard) {
      return;
    }
    final ticket = ++chapterIssueTicket;
    try {
      final map = await (session as ChapterIssueMapSession).issueMap(
        current,
        summary: false,
        entryId: node.id,
      );
      if (!mounted ||
          ticket != chapterIssueTicket ||
          page?.guard != map.guard ||
          selected?.id != node.id) {
        return;
      }
      setState(() => chapterIssues = map);
    } catch (_) {
      // 本章批注读取失败不影响正文；目录汇总仍可在底栏重试。
    }
  }

  /// 批注“在问题中核对”（CH-238）：清除筛选，翻到该问题所在页并选中它。
  void reviewInIssues(ChapterIssue issue) {
    final index = chapterIssues?.reviewIndex[issue.id];
    view.issues
      ..category = null
      ..severity = null
      ..offset = index == null ? 0 : (index ~/ 50) * 50
      ..issueId = issue.id
      ..anchor = 0;
    issuesEpoch++;
    tab(1);
  }

  int? focusLine;
  Future<void> locateIssue(ChapterIssue issue) async {
    if (busy || issue.entryId == null) return;
    await run((ticket) async {
      final next = await session.read(issue.nodeOffset ?? 0);
      final node = issue.entryId == chapterPrefixNode.id
          ? chapterPrefixNode
          : next.nodes.where((n) => n.id == issue.entryId).firstOrNull;
      if (node == null) throw const FormatException('问题对应章节已变化，请重新检查。');
      final content = await session.body(next, node.id, issue.bodyOffset);
      if (!mounted || ticket != generation) return;
      setState(() {
        page = next;
        focusLine = issue.focusLine;
        continuousOffset = null;
        continuousScroll = 0;
        selected = node;
        body = content;
        showIssues = false;
        showHistory = false;
      });
      rememberView();
      refreshChapterIssues();
    });
  }

  /// 样式片段（V120，LAY-166）：跳到本节第 [line] 行（本节正文行号），上面留三行。
  Future<void> locateLine(int line) async {
    final node = selected, current = page;
    if (busy || node == null || current == null) return;
    await run((ticket) async {
      // 加样式、标注后书稿版本会变，先按当前页重读一次。
      final next = await session.read(current.offset);
      final fresh = node.id == chapterPrefixNode.id
          ? chapterPrefixNode
          : next.nodes.where((n) => n.id == node.id).firstOrNull;
      if (fresh == null) throw const FormatException('本章已变化，请重新打开本章。');
      final content = await session.body(
        next,
        fresh.id,
        line > 4 ? line - 4 : 0,
      );
      if (!mounted || ticket != generation) return;
      setState(() {
        page = next;
        selected = fresh;
        focusLine = fresh.line + line;
        continuousOffset = null;
        continuousScroll = 0;
        body = content;
      });
      rememberView();
    });
  }

  /// 全书章节列表（按书稿版本缓存）：样式片段侧栏的“全书”按它汇总，点一章按所在页打开。
  (String, List<(ChapterNode, int)>)? styleOutline;

  Future<List<(ChapterNode, int)>> outlineNodes() async {
    final guard = page!.guard;
    final cached = styleOutline;
    if (cached != null && cached.$1 == guard) return cached.$2;
    final nodes = <(ChapterNode, int)>[];
    var offset = 0;
    while (true) {
      final next = await session.read(offset);
      for (final n in next.nodes) {
        nodes.add((n, next.offset));
      }
      offset = next.offset + next.nodes.length;
      if (next.nodes.isEmpty || offset >= next.total) break;
    }
    styleOutline = (guard, nodes);
    return nodes;
  }

  Future<List<StyleSegmentChapter>> styleBook() async {
    final nodes = await outlineNodes();
    final layout = layoutView;
    final result = <StyleSegmentChapter>[];
    for (final (node, _) in nodes) {
      final lines = layout?.linesFor(node.id) ?? const <int, LayoutLine>{};
      final manual = marks?.linesFor(node.id) ?? const {};
      final segments = chapterStyleSegments(
        layoutLines: lines,
        roles: layout?.systemRoles(lines, manual, const {}) ?? const {},
        markLines: manual,
        styleLines: inlineStyles?.stylesFor(node.id) ?? const {},
        noteLines: noteMarks?.tagsFor(node.id) ?? const {},
        text: (_) => '',
      );
      final counts = <String, int>{};
      for (final s in segments) {
        counts[s.group] = (counts[s.group] ?? 0) + 1;
      }
      if (counts.isNotEmpty) {
        result.add((id: node.id, title: node.title, counts: counts));
      }
    }
    return result;
  }

  Future<void> openStyleChapter(String id) async {
    if (id == selected?.id) return;
    final found = styleOutline?.$2.where((e) => e.$1.id == id).firstOrNull;
    if (found == null || busy) return;
    await run((ticket) async {
      final next = await session.read(found.$2);
      final node = next.nodes.where((n) => n.id == id).firstOrNull;
      if (node == null) throw const FormatException('这一章已变化，请重新打开“全书”。');
      final content = await session.body(next, node.id, 0);
      if (!mounted || ticket != generation) return;
      setState(() {
        page = next;
        focusLine = null;
        continuousOffset = null;
        continuousScroll = 0;
        selected = node;
        body = content;
      });
      rememberView();
      refreshChapterIssues();
    });
  }

  /// 标题类弹窗的未完成输入写入工作区草稿；明确完成或取消后清除。
  Future<bool?> titleDialog(
    String action,
    Widget Function(String? title, ValueChanged<String> onChanged) builder,
  ) async {
    final service = widget.library;
    final autosave = service is WorkspaceAutosaveService
        ? service as WorkspaceAutosaveService
        : null;
    final key = 'chapter-input:${widget.bookId}:${selected!.id}:$action';
    final initial = autosave?.readDraft(key)?['title'] as String?;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => builder(
        initial,
        (value) => autosave?.writeDraft(key, {'title': value}),
      ),
    );
    autosave?.writeDraft(key, null);
    return result;
  }

  Future<void> rename() async {
    if (selected == null || busy) return;
    final changed = await titleDialog(
      'rename',
      (value, onChanged) => ChapterRenameDialog(
        session: session,
        page: page!,
        node: selected!,
        initialTitle: value,
        onTitleChanged: onChanged,
      ),
    );
    if (mounted && changed == true) await read(page!.offset);
  }

  Future<void> history(bool undo) async {
    var succeeded = false;
    await run((_) async {
      await session.history(page!, undo: undo);
      succeeded = true;
    });
    if (mounted && succeeded) await read(page!.offset);
  }

  Future<void> split({bool useExistingLine = false}) async {
    final changed = await titleDialog(
      'split',
      (value, onChanged) => ChapterSplitDialog(
        session: session,
        page: page!,
        node: selected!,
        useExistingLine: useExistingLine,
        initialTitle: value,
        onTitleChanged: onChanged,
      ),
    );
    if (mounted && changed == true) await read(page!.offset);
  }

  Future<void> deleteBody() async {
    if (busy || selected == null || page == null) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChapterBodyDeleteDialog(
        session: session,
        page: page!,
        node: selected!,
      ),
    );
    if (mounted && changed == true) await read(page!.offset);
  }

  Future<void> insertVolume() async {
    if (busy || selected == null) return;
    final changed = await titleDialog(
      'volume',
      (value, onChanged) => ChapterVolumeDialog(
        session: session,
        page: page!,
        node: selected!,
        initialTitle: value,
        onTitleChanged: onChanged,
      ),
    );
    if (mounted && changed == true) await read(page!.offset);
  }

  Future<void> removeDuplicate({bool demote = false}) async {
    if (busy || selected == null) return;
    final becomesPrefix =
        demote && page!.offset == 0 && page!.nodes.first.id == selected!.id;
    ChapterEditPreview? candidate;
    await run((_) async {
      candidate = await session.preview(
        page!,
        demote
            ? DemoteChapterHeading(selected!.id)
            : RemoveDuplicateChapterHeading(selected!.id),
      );
    });
    if (!mounted || candidate == null) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChapterCandidateDialog(
        session: session,
        preview: candidate!,
        originalPage: page!,
        title: demote ? '标题改为正文' : '移除重复标题 · 保留正文',
        explanation: demote
            ? '仅取消所选行的标题身份，标题文字与全部正文保留。下级标题保留，层级归属以预览为准；确认后可撤销。'
            : null,
        initialOffset: page!.offset,
        initialNodeId: becomesPrefix ? r'$prefix' : null,
        focusNodeId: selected!.id,
        focusLine: selected!.line,
      ),
    );
    if (mounted && changed == true) {
      if (becomesPrefix) selected = chapterPrefixNode;
      await read(page!.offset);
    }
  }

  Future<void> targetEdit({required bool merge}) async {
    final changed = await titleDialog(
      merge ? 'merge' : 'move',
      (value, onChanged) => ChapterTargetDialog(
        session: session,
        page: page!,
        node: selected!,
        merge: merge,
        initialTitle: value,
        onTitleChanged: onChanged,
      ),
    );
    if (mounted && changed == true) await read(page!.offset);
  }

  Future<void> properties({String? role, bool? inToc}) async {
    var succeeded = false;
    await run((_) async {
      await session.properties(page!, selected!, role: role, inToc: inToc);
      succeeded = true;
    });
    if (mounted && succeeded) await read(page!.offset);
  }

  Future<void> menuAction(ChapterNode node, String action) async {
    await select(node);
    if (!mounted) return;
    if (busy || selected?.id != node.id || message.isNotEmpty) return;
    switch (action) {
      case 'volume':
        await insertVolume();
      case 'boundary':
        await split(useExistingLine: true);
      case 'demote':
        await removeDuplicate(demote: true);
      case 'duplicate':
        await removeDuplicate();
      case 'compare':
        await showDialog<void>(
          context: context,
          builder: (_) => ChapterBodyCompareDialog(
            session: session,
            structure: page!,
            lines: [node.line],
          ),
        );
      case 'rename':
        await rename();
      case 'split':
        await split();
      case 'merge':
        await targetEdit(merge: true);
      case 'move':
        await targetEdit(merge: false);
    }
  }

  Future<void> checkpoint() async {
    final current = page;
    if (current == null || busy || session is! ChapterCheckpointSession) return;
    final applied = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ChapterCheckpointDialog(session: session, page: current),
    );
    if (mounted && applied == true) await read(current.offset);
  }

  /// 规则面板关闭后递增，目录标题行的规则摘要据此重新读取（CH-261）。
  int rulesRevision = 0;

  Future<void> openRules({String? appendNonHeading}) async {
    await showChapterRulesDialog(
      context,
      service: widget.library as ChapterRulesService,
      bookId: widget.bookId,
      appendNonHeading: appendNonHeading,
    );
    if (!mounted) return;
    setState(() => rulesRevision++);
    await read(page?.offset ?? 0);
  }

  /// 数字章节（V25，CH-263）：有识别规则服务时打开合并后的对话框，否则沿用原来的修复流程入口。
  VoidCallback? get numericAction {
    if (widget.library is! ChapterRulesService) return widget.onNumericHeadings;
    return () async {
      final applied = await showNumericChaptersDialog(
        context,
        service: widget.library as ChapterRulesService,
        bookId: widget.bookId,
      );
      if (!mounted || !applied) return;
      setState(() => rulesRevision++);
      await read(page?.offset ?? 0);
    };
  }

  void tab(int index) => setState(() {
    showIssues = index == 1;
    showHistory = index == 2;
    visitedIssues = visitedIssues || showIssues;
    visitedHistory = visitedHistory || showHistory;
    rememberView();
  });

  bool get hasSelectedHeading =>
      selected != null && selected!.id != chapterPrefixNode.id;

  void searchChapters() {
    if (showIssues || showHistory) tab(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      layoutKey.currentState?.showOutline();
      treeSearchFocus.requestFocus();
    });
  }

  /// [tools]：工具栏最窄档时，“识别规则”“数字章节”收进本菜单首组（CH-002/003 入口不丢）。
  Future<void> more(BuildContext anchor, {bool tools = false}) async {
    final checkpoints = session is ChapterCheckpointSession
        ? session as ChapterCheckpointSession
        : null;
    final value = await showDeskActionGroups(
      anchor,
      title: '章节操作',
      groups: [
        if (tools)
          DeskActionGroup('常用', [
            if (widget.library is ChapterRulesService)
              const DeskMenuAction('rules', '识别规则', Icons.tune_rounded),
            DeskMenuAction(
              'numeric',
              '数字章节',
              Icons.format_list_numbered_rounded,
              enabled: numericAction != null,
            ),
          ]),
        DeskActionGroup('章节结构', [
          for (final a in chapterRowActions.first.actions)
            DeskMenuAction(
              a.value,
              a.label,
              a.icon,
              enabled: hasSelectedHeading,
            ),
        ]),
        DeskActionGroup('正文与标题', [
          for (final a in chapterRowActions.last.actions)
            DeskMenuAction(
              a.value,
              a.label,
              a.icon,
              enabled: switch (a.value) {
                'boundary' => selected != null,
                'deleteBody' =>
                  selected != null && body != null && body!.total > 0,
                _ => hasSelectedHeading,
              },
            ),
        ]),
        DeskActionGroup('检查与修复', [
          DeskMenuAction(
            'autoRepair',
            '一键修复…',
            Icons.auto_fix_high_outlined,
            enabled: widget.onRepair != null,
          ),
          DeskMenuAction(
            'catalogRepair',
            '一键目录修复…',
            Icons.playlist_add_check_rounded,
            enabled: widget.onCatalogRepair != null,
          ),
          DeskMenuAction(
            'catalog',
            '参考目录修复',
            Icons.list_alt_rounded,
            enabled: widget.onCatalog != null,
          ),
          DeskMenuAction(
            'repair',
            '逐项处理问题',
            Icons.checklist_rounded,
            enabled: widget.onRepair != null,
          ),
        ]),
        DeskActionGroup('保存与刷新', [
          if (checkpoints != null)
            DeskMenuAction(
              'checkpoint',
              '保存编辑快照',
              Icons.inventory_2_outlined,
              enabled: checkpoints.pendingEditActions > 0,
            ),
          const DeskMenuAction('refresh', '重新读取章节', Icons.refresh_rounded),
        ]),
      ],
    );
    if (!mounted || value == null) return;
    switch (value) {
      case 'volume':
        insertVolume();
      case 'boundary':
        split(useExistingLine: true);
      case 'deleteBody':
        deleteBody();
      case 'catalog':
        widget.onCatalog?.call();
      case 'repair':
        widget.onRepair?.call(true);
      case 'autoRepair':
        widget.onRepair?.call(false);
      case 'catalogRepair':
        widget.onCatalogRepair?.call();
      case 'checkpoint':
        checkpoint();
      case 'refresh':
        read(page?.offset ?? 0);
      case 'rules':
        openRules();
      case 'numeric':
        numericAction?.call();
      default:
        if (selected != null) menuAction(selected!, value);
    }
  }

  // ---------------------------------------------------------------- 视图

  Widget outline() => page == null
      ? const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      : ChapterOutline(
          viewState: view.tree,
          searchFocus: treeSearchFocus,
          restoreNavigation: widget.initialNodeId == null,
          session: session,
          snapshot: page!,
          selectedId: selected?.id,
          enabled: !busy,
          issueMap: issueMap,
          issueStatus: issueStatus,
          onRetryIssues: refreshIssues,
          titleTrailing: widget.library is ChapterRulesService
              ? RulesSummaryChip(
                  service: widget.library as ChapterRulesService,
                  bookId: widget.bookId,
                  headings: page!.total,
                  revision: rulesRevision,
                  onOpen: busy ? null : openRules,
                )
              : null,
          leading: _PrefixEntry(
            selected: selected?.id == chapterPrefixNode.id,
            onTap: busy
                ? null
                : () async {
                    tab(0);
                    await select(chapterPrefixNode);
                  },
          ),
          onSelect: (owner, node) async {
            page = owner;
            await select(node);
          },
          onMenu: (owner, node, action) async {
            page = owner;
            if (action == 'deleteBody') {
              await select(node);
              if (mounted) await deleteBody();
            } else {
              await menuAction(node, action);
            }
          },
        );

  Widget manuscript() => selected == null || page == null || body == null
      ? const Center(child: CircularProgressIndicator())
      : ChapterManuscript(
          // 切换原文与排版视图时整块重建（选字区域随之增减），阅读位置照常记住。
          key: ValueKey((
            'chapter-reader',
            selected!.id,
            page!.guard,
            body!.offset,
            layoutView != null,
          )),
          session: session,
          marks: marks,
          noteMarks: noteMarks,
          inlineStyles: inlineStyles,
          layout: layoutView,
          onLayoutMode: widget.library is RuleCatalogLibrary
              ? setLayoutMode
              : null,
          onLocateLine: locateLine,
          styleBook: styleBook,
          onOpenChapter: openStyleChapter,
          page: page!,
          node: selected!,
          initialBody: body,
          initialOffset: body!.offset,
          initialScroll: continuousScroll,
          focusLine: focusLine ?? widget.initialFocusLine,
          onPosition: (offset, pixels) {
            continuousOffset = offset;
            continuousScroll = pixels;
            rememberView();
          },
          issues:
              chapterIssues != null &&
                  chapterIssues!.chapterId == selected!.id &&
                  chapterIssues!.guard == page!.guard
              ? chapterIssues!.chapterIssues
              : const [],
          issuesTruncated:
              chapterIssues?.chapterId == selected!.id &&
              chapterIssues!.chapterTotal > chapterIssues!.chapterIssues.length,
          showNotes: view.showIssueNotes,
          onToggleNotes: (show) => setState(() => view.showIssueNotes = show),
          onReviewIssue: reviewInIssues,
          onRepairIssue: widget.onRepairIssue,
        );

  Widget inspector() {
    final d = context.desk;
    final node = selected;
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: ui(11, w: 600, c: d.ink3)),
    );
    Widget kv(String k, String v) => Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(k, style: ui(12, c: d.ink3)),
          ),
          Expanded(
            child: Text(v, style: ui(12, c: d.ink2)),
          ),
        ],
      ),
    );
    Widget section(List<Widget> children, {bool last = false}) => Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
    final lines = body == null ? null : '共 ${body!.total} 行';
    final List<Widget> content;
    if (node == null) {
      content = [
        section(last: true, [
          Text('未选择', style: ui(13, w: 600, c: d.ink2)),
          const SizedBox(height: 6),
          Text('在目录中选择章节后显示属性与编辑动作。', style: ui(12, c: d.ink3, h: 1.5)),
        ]),
      ];
    } else if (node.id == chapterPrefixNode.id) {
      content = [
        section(last: true, [
          Text('卷前正文', style: serif(15, w: 650, c: d.ink)),
          const SizedBox(height: 6),
          Text('首个标题之前的正文；没有标题时显示全书正文。', style: ui(12, c: d.ink2, h: 1.55)),
          if (lines != null) kv('行数', lines),
          const SizedBox(height: 14),
          DeskButton(
            '正文行设为标题',
            icon: Icons.title_rounded,
            disabledReason: '卷前正文为空',
            onPressed: busy || body == null || body!.total == 0
                ? null
                : () => split(useExistingLine: true),
          ),
        ]),
      ];
    } else {
      content = [
        section([
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  node.title,
                  style: serif(15, w: 650, c: d.ink, h: 1.4),
                ),
              ),
              IconButton(
                tooltip: '改名（F2）',
                visualDensity: VisualDensity.compact,
                onPressed: busy ? null : rename,
                icon: Icon(Icons.edit_outlined, size: 17, color: d.ink2),
              ),
            ],
          ),
          const SizedBox(height: 12),
          label('类型'),
          KeyedSubtree(
            key: ValueKey('chapter-role-${node.id}-${node.role}'),
            child: DeskSegmented<String>(
              value: node.role,
              options: const {
                'volume': '卷',
                'chapter': '章',
                'section': '节',
                'front': '前置',
              },
              onChanged: busy
                  ? null
                  : (v) {
                      if (v != node.role) properties(role: v);
                    },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('收入目录', style: ui(12.5, c: d.ink)),
              ),
              Switch(
                key: const ValueKey('chapter-toc'),
                value: node.inToc,
                onChanged: busy ? null : (v) => properties(inToc: v),
              ),
            ],
          ),
          kv('起始行', '第 ${node.line} 行'),
          if (lines != null) kv('行数', lines),
        ]),
        section(last: true, [
          label('编辑动作'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              DeskButton('改名', onPressed: busy ? null : rename),
              DeskButton('切分', onPressed: busy ? null : split),
              DeskButton(
                '合并',
                onPressed: busy ? null : () => targetEdit(merge: true),
              ),
              DeskButton(
                '移动',
                onPressed: busy ? null : () => targetEdit(merge: false),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('结构修改先预览，确认后写入，可撤销。', style: ui(11.5, c: d.ink3)),
        ]),
      ];
    }
    return Material(
      color: d.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: d.line)),
            ),
            child: Text('章节设置', style: ui(13, w: 650, c: d.ink)),
          ),
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: content),
          ),
        ],
      ),
    );
  }

  /// 工具栏按实际可用宽度分三档：文字按钮 / 图标按钮 / 再把“识别规则”“数字章节”收进“更多”。
  /// 所需宽度按文字长度与文字缩放估算（留 8% 余量），大字号或窄窗口时不溢出。
  Widget toolbar() => LayoutBuilder(
    builder: (context, c) {
      final d = context.desk;
      final aux = !showIssues && !showHistory;
      final outlineDocked =
          workspaceWidth >= DeskChapterLayout.outlineBreakpoint;
      final inspectorDocked =
          workspaceWidth >= DeskChapterLayout.inspectorBreakpoint;
      final rules = widget.library is ChapterRulesService;
      final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
      // 排版视图不显示章节设置，也就没有它的开关。
      final inspectorToggle = aux && layoutView == null && !inspectorDocked;
      final toggles =
          (aux && !outlineDocked ? 1 : 0) + (inspectorToggle ? 1 : 0);
      double tabs(List<String> labels) =>
          4 + labels.fold(0.0, (sum, l) => sum + 20 + l.length * 12.5 * scale);
      double action(String label) => 51 + label.length * 14 * scale;
      final fixed = 24 + toggles * 40.0 + 80 + 12;
      final full = tabs(const ['正文', '问题', '变更记录']);
      // “一键修复…”先于其他按钮缩成图标，不挤掉“识别规则”“数字章节”“更多”的文字。
      final repairIcon = widget.onRepair != null ? 46.0 : 0.0;
      final repairText = widget.onRepair != null ? action('一键修复…') + 6 : 0.0;
      final wideNeed =
          fixed +
          full +
          repairIcon +
          (rules ? action('识别规则') + 6 : 0) +
          action('数字章节') +
          6 +
          action('更多');
      final iconNeed = fixed + full + repairIcon + (rules ? 46 : 0) + 46 + 40;
      final narrow = c.maxWidth < wideNeed * 1.08;
      final repairNarrow =
          narrow || c.maxWidth < (wideNeed - repairIcon + repairText) * 1.08;
      final tight = c.maxWidth < iconNeed * 1.08;
      Widget button(
        String label,
        IconData icon,
        VoidCallback? onPressed, {
        String? tooltip,
      }) => narrow
          ? IconButton(
              tooltip: tooltip ?? label,
              onPressed: onPressed,
              icon: Icon(icon, size: 18, color: d.ink2),
            )
          : Tooltip(
              message: tooltip ?? label,
              child: DeskButton(label, icon: icon, onPressed: onPressed),
            );
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: d.line)),
        ),
        child: Row(
          children: [
            if (aux && !outlineDocked)
              IconButton(
                tooltip: '章节列表',
                onPressed: () => layoutKey.currentState?.toggleOutline(),
                icon: Icon(
                  Icons.account_tree_outlined,
                  size: 18,
                  color: d.ink2,
                ),
              ),
            KeyedSubtree(
              key: const ValueKey('chapter-content-tabs'),
              child: DeskSegmented<int>(
                value: showHistory
                    ? 2
                    : showIssues
                    ? 1
                    : 0,
                options: {0: '正文', 1: '问题', 2: tight ? '记录' : '变更记录'},
                // R3-03（CH-001）：问题页签带全书未处理的问题数；读取失败写“!”，
                // 不把失败当成没有问题。
                badges: {
                  if (issueStatus == 'error')
                    1: '!'
                  else if ((issueMap?.open ?? 0) > 0)
                    1: '${issueMap!.open}',
                },
                onChanged: tab,
              ),
            ),
            const Spacer(),
            IconButton(
              key: const ValueKey('chapter-undo'),
              tooltip: '撤销',
              onPressed: busy || !session.canUndo ? null : () => history(true),
              icon: const Icon(Icons.undo_rounded, size: 18),
            ),
            IconButton(
              key: const ValueKey('chapter-redo'),
              tooltip: '重做',
              onPressed: busy || !session.canRedo ? null : () => history(false),
              icon: const Icon(Icons.redo_rounded, size: 18),
            ),
            const SizedBox(width: 6),
            // 一键修复（CH-244）：全书自动方案，核对差异、确认后才应用并复查。
            if (widget.onRepair != null) ...[
              repairNarrow
                  ? IconButton(
                      key: const ValueKey('chapter-auto-repair'),
                      tooltip: '一键修复…',
                      onPressed: busy ? null : () => widget.onRepair!(false),
                      icon: Icon(
                        Icons.auto_fix_high_outlined,
                        size: 18,
                        color: d.ink,
                      ),
                    )
                  : DeskButton(
                      '一键修复…',
                      key: const ValueKey('chapter-auto-repair'),
                      icon: Icons.auto_fix_high_outlined,
                      primary: true,
                      tooltip: '生成全书自动修复方案；核对差异并确认后才应用，应用后自动复查',
                      onPressed: busy ? null : () => widget.onRepair!(false),
                    ),
              const SizedBox(width: 6),
            ],
            if (!tight) ...[
              if (rules) ...[
                button('识别规则', Icons.tune_rounded, busy ? null : openRules),
                const SizedBox(width: 6),
              ],
              button(
                '数字章节',
                Icons.format_list_numbered_rounded,
                busy ? null : numericAction,
              ),
              const SizedBox(width: 6),
            ],
            Builder(
              builder: (anchor) => Tooltip(
                message: '更多章节操作',
                child: narrow
                    ? IconButton(
                        onPressed: busy
                            ? null
                            : () => more(anchor, tools: tight),
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          size: 18,
                          color: d.ink2,
                        ),
                      )
                    : DeskButton(
                        '更多',
                        icon: Icons.more_horiz_rounded,
                        quiet: true,
                        onPressed: busy ? null : () => more(anchor),
                      ),
              ),
            ),
            if (inspectorToggle)
              IconButton(
                tooltip: '章节设置',
                onPressed: () => layoutKey.currentState?.toggleInspector(),
                icon: Icon(
                  Icons.view_sidebar_outlined,
                  size: 18,
                  color: d.ink2,
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget reader() {
    final d = context.desk;
    final checkpoints = session is ChapterCheckpointSession
        ? session as ChapterCheckpointSession
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar(),
        SizedBox(
          height: 2,
          child: busy ? const LinearProgressIndicator(minHeight: 2) : null,
        ),
        if (checkpoints != null &&
            (checkpoints.pendingEditActions >= 80 ||
                page?.editBudget?.nearLimit == true))
          _Notice(
            tone: Tone.warn,
            icon: Icons.inventory_2_outlined,
            text: '编辑记录较多，保存编辑快照后可继续编辑。',
            action: TextButton(
              onPressed: busy ? null : checkpoint,
              child: const Text('保存编辑快照'),
            ),
          ),
        if (message.isNotEmpty)
          _Notice(
            tone: Tone.pen,
            icon: Icons.info_outline_rounded,
            title: '操作提示',
            text: message,
          ),
        Expanded(
          child: IndexedStack(
            index: showHistory
                ? 2
                : showIssues
                ? 1
                : 0,
            children: [
              Material(color: d.canvas, child: manuscript()),
              visitedIssues && page != null
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: ChapterIssuesPanel(
                        key: ValueKey(('chapter-issues', issuesEpoch)),
                        viewState: view.issues,
                        onChanged: () => read(page?.offset ?? 0),
                        session: session,
                        structure: page!,
                        enabled: !busy,
                        onChapter: locateIssue,
                        onRepair: widget.onRepair,
                        onRepairIssue: widget.onRepairIssue,
                        onAddNonHeading: widget.library is ChapterRulesService
                            ? (phrase) => openRules(appendNonHeading: phrase)
                            : null,
                        onBody: () => tab(0),
                      ),
                    )
                  : const SizedBox(),
              visitedHistory
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: ChangeHistoryPage(
                        library: widget.library,
                        history: widget.library.openChangeHistory(),
                        bookId: widget.bookId,
                        compact: true,
                        onChanged: () => read(page?.offset ?? 0),
                        openEditor: (_, _) => tab(0),
                      ),
                    )
                  : const SizedBox(),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskSearchScope(
      focusNode: treeSearchFocus,
      onSearch: searchChapters,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              layoutKey.currentState?.closePanels(),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              searchChapters,
          const SingleActivator(LogicalKeyboardKey.f2): () {
            if (!busy && hasSelectedHeading) rename();
          },
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
            if (!busy && session.canUndo) history(true);
          },
          const SingleActivator(LogicalKeyboardKey.keyY, control: true): () {
            if (!busy && session.canRedo) history(false);
          },
          const SingleActivator(
            LogicalKeyboardKey.keyZ,
            control: true,
            shift: true,
          ): () {
            if (!busy && session.canRedo) history(false);
          },
        },
        child: LayoutBuilder(
          builder: (context, c) {
            workspaceWidth = c.maxWidth - 2;
            // 用 Material 作工作区底面：列表项的选中底色与点按反馈画在这一层上，不被遮挡。
            return Material(
              color: d.canvas,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: d.line),
              ),
              clipBehavior: Clip.antiAlias,
              child: DeskChapterLayout(
                key: layoutKey,
                showAuxiliary: !showIssues && !showHistory,
                showInspector: layoutView == null,
                outline: outline(),
                reader: reader(),
                inspector: inspector(),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PrefixEntry extends StatelessWidget {
  const _PrefixEntry({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const ValueKey('chapter-prefix'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Ink(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? d.accentSoft : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(Icons.notes_rounded, size: 15, color: d.ink3),
              const SizedBox(width: 8),
              Text(
                '卷前正文',
                style: ui(12.5, w: selected ? 600 : 480, c: d.ink2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.tone,
    required this.icon,
    required this.text,
    this.title,
    this.action,
  });
  final Tone tone;
  final IconData icon;
  final String text;
  final String? title;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final (fg, bg) = d.tone(tone);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      constraints: const BoxConstraints(minHeight: 40),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 8),
          if (title != null) ...[
            Text(title!, style: ui(12.5, w: 620, c: fg)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(text, style: ui(12.5, c: d.ink)),
          ),
          ?action,
        ],
      ),
    );
  }
}
