// 书稿概览（LIB-041–060）：迁入 desk（V6a）。读取、检查、保存项目的逻辑沿用 V6 前的 BookOverviewPage；
// 卡片、统计、进度行与页头按 design_review_v37/d4_library.dart（D4-C）换样式，布局沿用。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as paths;

import '../../application/library_service.dart';
import '../../application/book_check_service.dart';
import '../../application/workspace_leave_service.dart';
import '../controls/controls.dart';
import '../shell/page_menu.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'book_summary_panel.dart';
import 'library_page.dart' show formatCheckTime;

class BookOverviewPage extends StatefulWidget {
  const BookOverviewPage({
    super.key,
    required this.library,
    required this.bookId,
    this.picker,
    this.onRevealSource,
  });
  final LibraryService library;
  final String bookId;
  final BookFilePicker? picker;
  final Future<void> Function(String)? onRevealSource;
  @override
  State<BookOverviewPage> createState() => _BookOverviewState();
}

class _BookOverviewState extends State<BookOverviewPage> {
  late final checks = widget.library.openChecks(widget.bookId);
  late final information = widget.library.openBookInformation(widget.bookId);
  late final history = widget.library.openChangeHistory();
  BookCheckReport? report;
  bool busy = false, saving = false;
  String error = '', metricsError = '';
  Map<String, dynamic> metrics = {};
  int metricsTicket = 0;
  Future<void> loadMetrics() async {
    final service = widget.library;
    if (service is! BookOverviewService) return;
    final ticket = ++metricsTicket;
    try {
      final value = await (service as BookOverviewService).overview(
        widget.bookId,
      );
      if (mounted && ticket == metricsTicket) {
        setState(() {
          metrics = value;
          metricsError = '';
        });
      }
    } catch (_) {
      if (mounted && ticket == metricsTicket) {
        setState(() {
          metrics = {};
          metricsError = '统计读取失败';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    loadMetrics();
    widget.library.books.addListener(loadMetrics);
    widget.library.projectBusy.addListener(loadMetrics);
  }

  @override
  void dispose() {
    widget.library.books.removeListener(loadMetrics);
    widget.library.projectBusy.removeListener(loadMetrics);
    metricsTicket++;
    checks.dispose();
    information.dispose();
    super.dispose();
  }

  void open(String page) => context.go(
    bookPageLocation(
      widget.bookId,
      page,
      origin: GoRouterState.of(context).uri,
    ),
  );
  void convert() => context.go(
    Uri(
      path: '/conversion',
      queryParameters: {
        'books': [widget.bookId],
      },
    ).toString(),
  );
  void records() {
    widget.library.selectBook(widget.bookId);
    context.go('/history');
  }

  Future<void> check() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await checks.inspect();
      if (mounted) setState(() => report = result);
    } catch (_) {
      if (mounted) setState(() => error = '检查未完成，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (saving || widget.library.projectBusy.value) return;
    setState(() {
      saving = true;
      error = '';
    });
    try {
      final existing = metrics['project_path'] as String? ?? '';
      final path = existing.isNotEmpty
          ? existing
          : await widget.picker?.chooseProjectDestination();
      if (path == null || !mounted) return;
      final result = await widget.library.saveProject(path);
      if (mounted) {
        if (!result.succeeded) setState(() => error = result.message);
        await loadMetrics();
      }
    } catch (_) {
      if (mounted) setState(() => error = '保存未完成，请重试。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> reveal(String path) async {
    try {
      await widget.onRevealSource?.call(path);
    } catch (_) {
      if (mounted) setState(() => error = '无法定位原文件，请检查来源路径。');
    }
  }

  Widget card(String title, Widget child, {List<Widget> actions = const []}) {
    final d = context.desk;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: d.shadow1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(title, style: ui(13.5, w: 650, c: d.ink)),
              if (actions.isNotEmpty)
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  /// 卡片标题右侧的文字链接，例如“编辑书籍信息 →”（LIB-112）。
  Widget link(String text, VoidCallback onTap, {Key? key}) => TextButton(
    key: key,
    style: TextButton.styleFrom(
      foregroundColor: context.desk.accent,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      visualDensity: VisualDensity.compact,
    ),
    onPressed: onTap,
    child: Text(text),
  );

  /// 状态文字的语义色（与检查页一致）：失败朱、待处理赭、通过苔，其余中性。
  Tone toneOf(String text) {
    if (text.contains('失败') || text.contains('未完成')) return Tone.pen;
    if (text.contains('待') ||
        text.contains('问题') ||
        text.contains('建议') ||
        text.contains('候选')) {
      return Tone.warn;
    }
    if (text.contains('通过') ||
        text.contains('无问题') ||
        text.contains('未发现') ||
        text.startsWith('已导入')) {
      return Tone.ok;
    }
    return Tone.neutral;
  }

  Widget row(
    String label,
    String detail,
    VoidCallback onTap, {
    IconData? icon,
  }) {
    final d = context.desk;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 38),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: d.line)),
        ),
        child: Row(
          children: [
            Dot(d.tone(toneOf(detail)).$1),
            const SizedBox(width: 10),
            if (icon != null) ...[
              Icon(icon, size: 16, color: d.ink3),
              const SizedBox(width: 8),
            ],
            Expanded(
              flex: 2,
              child: Text(label, style: ui(12.5, c: d.ink)),
            ),
            // 状态靠右，紧挨着箭头（原来从中间开始排）。
            Expanded(
              flex: 3,
              child: Text(
                detail,
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: d.ink2),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, size: 16, color: d.ink3),
          ],
        ),
      ),
    );
  }

  Widget stack(List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: 16),
        children[i],
      ],
    ],
  );

  /// 卷、章、字数并成书籍信息里的一行（R2-06），不再各占一大格把制作进度挤到下面。
  Widget statistic(String field, String label) {
    final d = context.desk;
    return Text.rich(
      key: ValueKey('overview-stat-$field'),
      TextSpan(
        children: [
          TextSpan(
            text: '${metrics[field] ?? '…'}',
            style: mono(15, w: 650, c: d.ink),
          ),
          TextSpan(
            text: ' $label',
            style: ui(12.5, c: d.ink2),
          ),
        ],
      ),
    );
  }

  /// 书籍信息里的小标签（R2-05）：只有能点的才有下划线与指针，不再像按钮。
  Widget tag(String text, {VoidCallback? onTap, String? tooltip, Key? key}) {
    final d = context.desk;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: onTap == null ? d.sunken : d.accentSoft,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: ui(
          12,
          w: onTap == null ? 500 : 600,
          c: onTap == null ? d.ink2 : d.accent,
        ),
      ),
    );
    final child = onTap == null
        ? body
        : MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: onTap, child: body),
          );
    return Tooltip(key: key, message: tooltip ?? '', child: child);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.library.books,
      widget.library.projectBusy,
      checks.changes,
      information.changes,
      history.changes,
    ]),
    builder: (_, _) {
      final book = widget.library.books.value
          .where((b) => b.id == widget.bookId)
          .firstOrNull;
      if (book == null) return const Center(child: Text('书稿不可用，请返回书库。'));
      final shared = checks is CachedBookCheckSession
          ? (checks as CachedBookCheckSession).latest
          : report;
      final latest = shared != null && checks.isCurrent(shared) ? shared : null;
      final saved = information.saved;
      final language = (saved['language'] as String? ?? '').trim();
      final changes = history.records(widget.bookId);
      final life = widget.library is WorkspaceLeaveService
          ? widget.library as WorkspaceLeaveService
          : null;
      final dirty = life?.hasUnsavedChanges ?? true;
      String status(String id) =>
          latest?.domains.where((d) => d.id == id).firstOrNull?.status ??
          '尚未检查当前版本';
      Widget step(
        String label,
        String detail,
        String destination,
        IconData icon,
      ) => row(
        label,
        detail,
        () => destination == 'conversion' ? convert() : open(destination),
        icon: icon,
      );
      final metadata = card(
        '书籍信息',
        LayoutBuilder(
          builder: (context, bounds) {
            final details = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DeskText(book.title, size: 25, bold: true),
                const SizedBox(height: 6),
                BookAuthorText(book.author, size: 14),
                const SizedBox(height: 10),
                Tooltip(
                  message: '正文字数是有效稿去除标题、空白后的字符数，包含标点',
                  child: Wrap(
                    spacing: 10,
                    children: [
                      statistic('volumes', '卷 ·'),
                      statistic('chapters', '章 ·'),
                      statistic('characters', '字'),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    tag(
                      language.isEmpty ? '语言未设置' : language,
                      key: const ValueKey('overview-language'),
                      tooltip: language.isEmpty
                          ? '到书籍信息里设置语言（影响 Kindle 字体与断行）'
                          : '书籍语言',
                      onTap: language.isEmpty
                          ? () => open('information')
                          : null,
                    ),
                    tag(book.format, tooltip: '原稿格式'),
                    tag('当前草稿', tooltip: '概览显示的是当前草稿，原稿不会被修改'),
                    link(
                      '编辑书籍信息 →',
                      () => open('information'),
                      key: const ValueKey('overview-edit-information'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '${saved['description'] ?? ''}',
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            );
            if (bounds.maxWidth < 420) {
              return stack([
                Center(child: LibraryCover(book, width: 110)),
                details,
              ]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LibraryCover(book, width: 115),
                const SizedBox(width: 20),
                Expanded(child: details),
              ],
            );
          },
        ),
      );
      final checkedAt = latest?.checkedAt;
      final progress = card(
        '制作进度',
        actions: [
          Text(
            latest == null
                ? '尚未检查当前版本'
                : checkedAt == null
                ? '已检查当前版本'
                : '检查于 ${formatCheckTime(checkedAt)}',
            key: const ValueKey('overview-checked-at'),
            style: ui(11.5, c: context.desk.ink3),
          ),
          DeskButton('检查本书', quiet: true, onPressed: busy ? null : check),
          DeskButton('查看全部问题', primary: true, onPressed: () => open('checks')),
        ],
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (busy) const LinearProgressIndicator(minHeight: 2),
            step(
              '导入与识别',
              '已导入 · ${book.format}',
              'chapters',
              Icons.check_circle_outline,
            ),
            step(
              '章节检查',
              status('chapters'),
              'chapters',
              Icons.account_tree_outlined,
            ),
            step(
              '文本清理',
              '${metrics['cleanup'] ?? '正在读取…'} · ${status('cleanup')}',
              'cleanup',
              Icons.cleaning_services_outlined,
            ),
            step(
              '书籍信息与封面',
              status('metadata'),
              'information',
              Icons.menu_book_outlined,
            ),
            step(
              '排版',
              '${metrics['layout'] ?? '正在读取…'}',
              'layout',
              Icons.format_size,
            ),
            step(
              '图片与资源',
              status('resources'),
              'resources',
              Icons.image_outlined,
            ),
            step('生成成品', '使用当前草稿与转换设置', 'conversion', Icons.output),
          ],
        ),
      );
      // 项目文件状态（LIB-110）：草稿一直自动保存在本机；项目文件是用户另存的文件，
      // 两者分开说明，避免把“已自动保存”和“项目有未保存更改”混在一起。
      final projectPath = metrics['project_path'] as String? ?? '';
      final projectKnown = metrics.containsKey('project_path');
      final projectHead = !projectKnown
          ? '正在读取项目状态…'
          : projectPath.isEmpty
          ? '尚未另存为项目文件'
          : dirty
          ? '项目文件不是最新'
          : '项目文件已是最新';
      final projectNote = projectPath.isEmpty
          ? '草稿已自动保存在本机，关闭后再打开可以继续。另存为项目文件后，可以把书稿和修改记录带到别处。'
          : dirty
          ? '草稿已自动保存在本机；项目文件还是上次保存时的内容。'
          : '';
      // 原“检查摘要”与“制作进度”逐项重复，已并入制作进度（LIB-111）。
      final source = card(
        '项目与来源',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              projectHead,
              key: const ValueKey('overview-project-state'),
              style: ui(13.5, w: 600, c: context.desk.ink),
            ),
            if (projectPath.isNotEmpty) ...[
              const SizedBox(height: 4),
              SelectableText(
                paths.normalize(projectPath),
                style: ui(12, c: context.desk.ink2),
              ),
            ],
            if (projectNote.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(projectNote, style: ui(12, c: context.desk.ink3)),
            ],
            if (projectKnown) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: DeskButton(
                  saving
                      ? '正在保存…'
                      : projectPath.isEmpty
                      ? '另存为项目…'
                      : '更新项目文件',
                  key: const ValueKey('overview-save-project'),
                  onPressed:
                      !dirty ||
                          saving ||
                          busy ||
                          widget.library.projectBusy.value ||
                          (life?.hasPendingWork ?? false) ||
                          (widget.picker == null && projectPath.isEmpty)
                      ? null
                      : save,
                ),
              ),
            ],
            const SizedBox(height: 14),
            Text('来源', style: TextStyle(color: context.desk.ink2)),
            SelectableText(paths.normalize(book.path)),
            if (widget.onRevealSource != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: DeskButton(
                  '打开原文件位置',
                  onPressed: () => reveal(book.path),
                ),
              ),
            ],
          ],
        ),
      );
      final recent = card(
        '最近操作',
        actions: [link('全部记录 →', records)],
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (changes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('还没有修改记录', style: ui(12.5, c: context.desk.ink3)),
              ),
            for (final entry in changes.take(3))
              row(
                entry.title,
                entry.applied ? (entry.canUndo ? '已应用 · 可撤销' : '已应用') : '已撤销',
                () => open(entry.destination),
              ),
          ],
        ),
      );
      return LayoutBuilder(
        builder: (context, bounds) {
          final left = stack([
            metadata,
            if (metricsError.isNotEmpty)
              DeskButton('统计读取失败，重试', onPressed: loadMetrics),
            progress,
          ]);
          final right = stack([source, recent]);
          return DeskScrollView(
            child: stack([
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '书稿概览',
                      style: ui(16, w: 650, c: context.desk.ink),
                    ),
                  ),
                  // 转换统一用底部的“转换当前书”，这里不再重复（LIB-109）。
                  DeskButton(
                    '返回书库',
                    quiet: true,
                    icon: Icons.arrow_back_rounded,
                    onPressed: () => context.go('/'),
                  ),
                ],
              ),
              if (error.isNotEmpty)
                Text(error, style: TextStyle(color: context.desk.pen)),
              if (bounds.maxWidth <
                  950 * MediaQuery.textScalerOf(context).scale(1)) ...[
                left,
                right,
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 7, child: left),
                    const SizedBox(width: 18),
                    Expanded(flex: 4, child: right),
                  ],
                ),
            ]),
          );
        },
      );
    },
  );
}
