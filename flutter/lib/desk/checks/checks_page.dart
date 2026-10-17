// 检查页（CHK-001–011）：顶栏为领域分段、状态、一键修复/一键目录修复（CH-243/245）、
// 依据目录核对与检查本书/取消检查；
// 章节领域显示问题浏览器，其余领域显示发现项与跳转处理入口。检查只读，不改正文。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../../application/book_check_service.dart';
import '../../application/chapter_rules_service.dart';
import '../../application/chapter_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart';
import 'check_view_state.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../rules/rules_sheet.dart';
import 'cleanup_findings.dart';
import 'issue_browser.dart';

class BookChecksPage extends StatefulWidget {
  const BookChecksPage({
    super.key,
    required this.library,
    required this.bookId,
    required this.onRepair,
    this.onRepairIssue,
    required this.onCatalog,
    this.onCatalogRepair,
    this.onCleanupLine,
    required this.onChapter,
    required this.onCleanup,
    this.onOpenDomain,
    this.viewState,
    this.onRules,
  });
  final LibraryService library;
  final CheckViewState? viewState;
  final String bookId;
  final void Function(bool guided) onRepair;
  final void Function(ChapterIssue)? onRepairIssue;
  final VoidCallback onCatalog;

  /// 一键目录修复：打开参考目录页的一键流程（CH-245/246）。
  final VoidCallback? onCatalogRepair;

  /// 在清理页打开检测详情并定位到某一行（CHK-055）。
  final void Function(int line)? onCleanupLine;
  final VoidCallback onCleanup;
  final void Function(String)? onOpenDomain;
  final void Function(ChapterIssue? issue) onChapter;

  /// 打开识别与检查规则页（V64，CH-279）；ruleId 不为空时定位到这条规则。
  final void Function(String? ruleId)? onRules;
  @override
  State<BookChecksPage> createState() => _BookChecksPageState();
}

/// 格式版本低于当前要求的检查结果：需要重新检查才能用新的显示方式（CHK-058/060）。
bool isLegacyCheckReport(BookCheckReport report) => report.outdated;

class _BookChecksPageState extends State<BookChecksPage> {
  late final session = widget.library.openChecks(widget.bookId);
  late final chapters = widget.library.openChapters(widget.bookId);
  BookCheckReport? report;
  List<String> evidenceLines = const [];
  bool busy = false;
  late final view = widget.viewState ?? CheckViewState();
  String error = '';
  String get selected => view.domain;
  set selected(String value) => view.domain = value;
  int generation = 0;

  /// 正在把旧格式的检查结果更新为新的显示方式。
  bool upgrading = false;

  static const domains = [
    CheckDomain('chapters', '章节结构', '未检查', '当前有效草稿的标题、编号与结构', []),
    CheckDomain('cleanup', '文本清理', '未检测', '规则候选独立审阅，不混入章节问题', []),
    CheckDomain('metadata', '书籍信息', '未检查', '书名、作者、语言与封面设置', []),
    CheckDomain('resources', '图片资源', '未检查', '资源可读性与正文插图位置', []),
    CheckDomain('output', '目标格式', '转换时检查', '选定格式与输出位置后检查批次', []),
  ];

  @override
  void initState() {
    super.initState();
    if (session is CachedBookCheckSession) {
      report = (session as CachedBookCheckSession).latest;
      evidenceLines =
          report?.evidence.split('\n').where((v) => v.isNotEmpty).toList() ??
          [];
      if (report == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) check();
        });
      } else if (isLegacyCheckReport(report!)) {
        // V12 前保存的结果没有结构化清理数据、数量和时间：后台重新检查一次（CHK-058）。
        upgrading = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) check();
        });
      }
    }
  }

  Future<void> check() async {
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      report = null;
      evidenceLines = const [];
    });
    try {
      final next = await session.inspect();
      if (mounted && ticket == generation) {
        setState(() {
          report = next;
          evidenceLines = next.evidence
              .split('\n')
              .where((line) => line.isNotEmpty)
              .toList(growable: false);
        });
      }
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() => error = deskErrorText(e, '检查未完成，请重试。'));
      }
    } finally {
      if (mounted && ticket == generation) {
        setState(() {
          busy = false;
          upgrading = false;
        });
      }
    }
  }

  void cancel() {
    session.cancel();
    setState(() => error = '正在停止检查，等待当前阶段结束…');
  }

  @override
  void dispose() {
    generation++;
    session.dispose();
    super.dispose();
  }

  /// 状态文字的语义色：失败朱、待处理赭、通过苔，其余中性。
  Tone statusTone(CheckDomain domain) {
    final text = domain.status;
    if (domain.failed) return Tone.pen;
    if (text.contains('待') || text.contains('建议') || text.contains('候选')) {
      return Tone.warn;
    }
    if (text.contains('通过') || text.contains('无问题') || text.contains('未发现')) {
      return Tone.ok;
    }
    return Tone.neutral;
  }

  Widget badge(CheckDomain domain) {
    final d = context.desk;
    final (fg, bg) = d.tone(statusTone(domain));
    return Tooltip(
      message: domain.detail,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Dot(fg, size: 6),
            const SizedBox(width: 6),
            Text(domain.status, style: ui(12, w: 560, c: fg)),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime when) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(when.hour)}:${two(when.minute)}';
    return when.year == now.year &&
            when.month == now.month &&
            when.day == now.day
        ? '今天 $time'
        : '${when.month} 月 ${when.day} 日 $time';
  }

  /// 分类页签（CHK-057）：标题后带数量，有待处理项时前面一个小圆点，替代单独的状态标签。
  Widget tab(Desk d, CheckDomain domain) {
    final on = domain.id == selected;
    final (fg, _) = d.tone(statusTone(domain));
    final attention = domain.failed || statusTone(domain) == Tone.warn;
    final count = domain.count;
    return Tooltip(
      message: '${domain.status}\n${domain.detail}',
      child: Material(
        key: ValueKey('checks-tab-${domain.id}'),
        color: on ? d.sunken : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: busy ? null : () => setState(() => selected = domain.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (attention) ...[Dot(fg, size: 6), const SizedBox(width: 6)],
                Text(
                  domain.title,
                  style: ui(13, w: on ? 620 : 450, c: on ? d.ink : d.ink2),
                ),
                if (count != null && count > 0) ...[
                  const SizedBox(width: 6),
                  Text('$count', style: mono(11, c: on ? d.ink2 : d.ink3)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 合并后的“一键修复 ▾”：主按钮为全书自动方案，下拉为目录修复与目录核对。
  Widget repairButton(BookSummary? book) {
    final off = busy || book == null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 一键修复（CH-243）：进入全书自动方案，仍需核对差异、确认后才应用并复查。
        DeskButton(
          '一键修复…',
          key: const ValueKey('checks-auto-repair'),
          icon: Icons.auto_fix_high_outlined,
          primary: true,
          tooltip: '生成全书自动修复方案；核对差异并确认后才应用，应用后自动复查',
          onPressed: off ? null : () => widget.onRepair(false),
        ),
        const SizedBox(width: 2),
        DeskCommandMenu<String>(
          key: const ValueKey('checks-repair-menu'),
          tooltip: '更多修复方式',
          enabled: !off,
          icon: const Icon(Icons.expand_more_rounded),
          onSelected: (value) {
            if (value == 'catalog-repair') {
              widget.onCatalogRepair?.call();
            } else {
              widget.onCatalog();
            }
          },
          itemBuilder: (_) => [
            if (widget.onCatalogRepair != null)
              const PopupMenuItem(
                key: ValueKey('checks-catalog-repair'),
                height: 36,
                value: 'catalog-repair',
                child: Text('按参考目录修复…'),
              ),
            const PopupMenuItem(
              key: ValueKey('checks-catalog-check'),
              height: 36,
              value: 'catalog',
              child: Text('依据目录核对…'),
            ),
          ],
        ),
      ],
    );
  }

  Widget header(
    Desk d,
    List<CheckDomain> values,
    CheckDomain active,
    BookSummary? book,
  ) {
    final when = report?.checkedAt;
    final phase = busy && session is BookCheckProgressSession
        ? (session as BookCheckProgressSession).checkPhase
        : '';
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final domain in values) ...[
                    tab(d, domain),
                    const SizedBox(width: 2),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (phase.isNotEmpty || upgrading)
            Flexible(
              child: Text(
                upgrading ? '正在更新为新的显示方式…' : phase,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: d.ink2),
              ),
            )
          else if (when != null)
            Text(
              '检查于 ${_time(when)}',
              key: const ValueKey('checks-checked-at'),
              style: ui(12, c: d.ink3),
            ),
          const SizedBox(width: 10),
          if (widget.onRules case final open?) ...[
            DeskButton(
              '规则',
              key: const ValueKey('checks-rules'),
              quiet: true,
              icon: Icons.tune_rounded,
              tooltip: '识别与检查规则：查看每条规则在本书的命中',
              onPressed: () => open(null),
            ),
            const SizedBox(width: 6),
          ],
          busy
              ? DeskButton('取消检查', icon: Icons.stop_rounded, onPressed: cancel)
              : DeskButton(
                  '检查本书',
                  icon: Icons.refresh_rounded,
                  onPressed: book == null ? null : check,
                ),
          const SizedBox(width: 8),
          repairButton(book),
        ],
      ),
    );
  }

  /// 没有检查结果时（取消或失败后）：说明会检查什么，并给出“检查本书”。
  Widget emptyState(Desk d, BookSummary? book) => Center(
    key: const ValueKey('checks-empty'),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fact_check_outlined, size: 40, color: d.ink3),
          const SizedBox(height: 14),
          Text('这本书还没有检查结果', style: serif(19, w: 650, c: d.ink)),
          const SizedBox(height: 8),
          Text(
            '检查会核对章节结构、文本清理建议、书籍信息、图片资源与目标格式。检查不会修改书稿。',
            textAlign: TextAlign.center,
            style: ui(12.5, c: d.ink2, h: 1.6),
          ),
          const SizedBox(height: 18),
          DeskButton(
            '检查本书',
            primary: true,
            icon: Icons.fact_check_outlined,
            onPressed: book == null ? null : check,
          ),
        ],
      ),
    ),
  );

  Widget findings(Desk d, CheckDomain active, BookSummary? book, bool current) {
    final target = switch (selected) {
      'cleanup' => '定位清理问题',
      'metadata' => '编辑书籍信息',
      'resources' => '管理图片资源',
      _ => '打开转换设置',
    };
    return Material(
      color: d.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              children: [
                Row(
                  children: [
                    Text(active.title, style: ui(15, w: 650, c: d.ink)),
                    const SizedBox(width: 10),
                    badge(active),
                  ],
                ),
                const SizedBox(height: 6),
                Text(active.detail, style: ui(12.5, c: d.ink2, h: 1.5)),
                const SizedBox(height: 14),
                for (final finding in active.findings)
                  Container(
                    key: ValueKey('finding-${finding.id}'),
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
                    decoration: BoxDecoration(
                      color: d.surface,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: d.shadow1,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(finding.title, style: ui(13.5, w: 620, c: d.ink)),
                        const SizedBox(height: 6),
                        SelectableText(
                          finding.detail,
                          style: ui(12.5, c: d.ink2, h: 1.55),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: DeskButton(
                            switch (finding.target) {
                              'cover' => '设置封面',
                              'metadata' => '补充信息',
                              _ => '处理资源',
                            },
                            onPressed:
                                busy ||
                                    book == null ||
                                    !current ||
                                    widget.onOpenDomain == null
                                ? null
                                : () => widget.onOpenDomain!(finding.target),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (active.id == 'cleanup' && active.cleanup.isNotEmpty)
                  CleanupFindingsView(
                    key: const ValueKey('cleanup-findings'),
                    items: active.cleanup,
                    onLocate: busy || book == null || !current
                        ? null
                        : widget.onCleanupLine,
                  )
                else if (active.id == 'cleanup' && active.items.isNotEmpty)
                  DeskNote(
                    '这份结果是旧版本保存的，没有按规则分组的数据。点“检查本书”即可更新为新的显示方式。',
                    title: '需要更新',
                    tone: Tone.warn,
                  )
                else if (active.findings.isEmpty)
                  for (final item in active.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SelectableText(
                        item,
                        style: ui(12.5, c: d.ink2, h: 1.55),
                      ),
                    ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              color: d.surface,
              border: Border(top: BorderSide(color: d.line)),
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: DeskButton(
                target,
                primary: true,
                onPressed: busy || book == null
                    ? null
                    : selected == 'cleanup'
                    ? widget.onCleanup
                    : widget.onOpenDomain == null
                    ? null
                    : () => widget.onOpenDomain!(selected),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session.changes,
    builder: (context, _) => ValueListenableBuilder<List<BookSummary>>(
      valueListenable: widget.library.books,
      builder: (context, books, _) {
        final d = context.desk;
        final book = books.where((b) => b.id == widget.bookId).firstOrNull;
        final current = report != null && session.isCurrent(report!);
        final values = report?.domains ?? domains;
        final active = values.firstWhere((d) => d.id == selected);
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
              header(d, values, active, book),
              SizedBox(
                height: 2,
                child: busy
                    ? const LinearProgressIndicator(minHeight: 2)
                    : null,
              ),
              if (error.isNotEmpty || (report != null && !current))
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: DeskNote(
                    error.isNotEmpty ? error : '书稿已变化，请更新检查结果。',
                    title: '需要重新检查',
                    tone: Tone.warn,
                  ),
                ),
              Expanded(
                child: report == null && !busy
                    ? emptyState(d, book)
                    : selected == 'chapters'
                    ? CheckIssueBrowser(
                        viewState: view.issues,
                        onChanged: check,
                        key: ValueKey(widget.bookId),
                        session: chapters,
                        revision: report,
                        enabled: current && !busy && !active.failed,
                        onChapter: widget.onChapter,
                        onRepair: widget.onRepair,
                        onRepairIssue: widget.onRepairIssue,
                        onRule: widget.onRules,
                        onAddNonHeading: widget.library is ChapterRulesService
                            ? (phrase) async {
                                await showChapterRulesDialog(
                                  context,
                                  service:
                                      widget.library as ChapterRulesService,
                                  bookId: widget.bookId,
                                  appendNonHeading: phrase,
                                );
                                if (mounted) await check();
                              }
                            : null,
                      )
                    : findings(d, active, book, current),
              ),
            ],
          ),
        );
      },
    ),
  );
}
