// 迁入 desk（library，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
// V14：生成封面重新设计（LIB-102），当前书详情精简（LIB-103）。V16：生成封面画法移到 generated_cover.dart，与转出的封面共用。
// V18：“最近输出”（LIB-113）。
import 'package:flutter/material.dart';

import '../../application/chapter_rules_service.dart';
import '../../application/library_service.dart';
import '../../application/output_history_service.dart';
import '../errors.dart';
import '../controls/controls.dart';
import '../metadata/cover_preview.dart';
import '../rules/rules_sheet.dart' show showChapterRulesDialog;
import 'book_structure_counts.dart';
import 'generated_cover.dart';

import '../tokens.dart';
import '../widgets.dart' show Dot;

export 'generated_cover.dart' show coverInkFor;

class LibraryCover extends StatelessWidget {
  const LibraryCover(this.book, {super.key, this.width = 110});
  final BookSummary book;
  final double width;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: width * 4 / 3,
    child: book.coverPath?.isNotEmpty == true
        ? CoverPreview(
            path: book.coverPath!,
            decodeWidth: (width * 2).round(),
            crop: book.coverCrop,
            revision: book.coverDesign?['image_sha256'] as String? ?? '',
            fit: switch (book.coverFit) {
              'cover' => BoxFit.cover,
              'fill' => BoxFit.fill,
              _ => BoxFit.contain,
            },
          )
        : _GeneratedCover(book: book, width: width),
  );
}

/// 没有封面时的生成封面（LIB-102）：与转出的书里的生成封面用同一画法（OUT-070）。
class _GeneratedCover extends StatelessWidget {
  const _GeneratedCover({required this.book, required this.width});
  final BookSummary book;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('generated-cover'),
    size: Size(width, width * 4 / 3),
    painter: GeneratedCoverPainter.desk(
      context.desk,
      title: book.title,
      author: book.author,
    ),
  );
}

bool bookNeedsReview(BookSummary book) =>
    book.status.contains('待') ||
    book.status.contains('失败') ||
    book.status.contains('异常');

/// 书库里“待核对”的数量只算章节问题（LIB-106）；清理建议与书籍信息在详情中分列。
int chapterIssueCount(BookSummary book) => book.pending?.chapters ?? 0;

/// 书库需要提醒的书：有章节问题，或检查没有完成、已过期、失败。
/// 已检查且只剩清理建议或待补充的书籍信息时不提醒。
bool bookNeedsAttention(BookSummary book) {
  if (chapterIssueCount(book) > 0) return true;
  if (book.pending == null) return bookNeedsReview(book);
  return const ['未完成', '过期', '失败', '异常'].any(book.status.contains);
}

/// 书的状态短词，书库列表与转换页共用（LIB-106、OUT-071）：只有章节问题写“待核对 N”；
/// 已检查且只剩清理建议或书籍信息时写“已检查 · 有建议”。[attention] 为 true 时加提醒圆点，
/// [active] 为 true 时（检查中）用较深的字色。
({String text, bool attention, bool active}) bookStatusLabel(BookSummary b) {
  final pending = b.pending;
  if (b.status == '检查中…') {
    return (text: b.status, attention: false, active: true);
  }
  if (chapterIssueCount(b) > 0) {
    return (
      text: '待核对 ${chapterIssueCount(b)}',
      attention: true,
      active: false,
    );
  }
  if (b.status == '检查通过' || (pending != null && !bookNeedsAttention(b))) {
    return (
      text: pending != null && pending.total > 0 ? '已检查 · 有建议' : '已检查',
      attention: false,
      active: false,
    );
  }
  if (bookNeedsAttention(b)) {
    return (
      text: b.status.replaceFirst('检查完成 · ', ''),
      attention: true,
      active: false,
    );
  }
  return (text: b.status, attention: false, active: false);
}

/// 状态的悬停提示：完整状态、分项与检查时间。
String bookStatusTip(BookSummary b) {
  final pending = b.pending;
  final when = pending?.checkedAt;
  String two(int v) => v.toString().padLeft(2, '0');
  String time(DateTime t) {
    final now = DateTime.now();
    final hm = '${two(t.hour)}:${two(t.minute)}';
    return t.year == now.year && t.month == now.month && t.day == now.day
        ? '今天 $hm'
        : '${t.month} 月 ${t.day} 日 $hm';
  }

  return [
    b.status,
    if (pending != null && pending.total > 0) pending.breakdown,
    if (when != null) '检查于 ${time(when)}',
  ].join('\n');
}

/// 作者为空时以浅灰色“未填作者”显示，不把占位文字当成作者（LIB-107）。
class BookAuthorText extends StatelessWidget {
  const BookAuthorText(
    this.author, {
    super.key,
    this.size = 12.5,
    this.textAlign,
  });
  final String author;
  final double size;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final empty = author.trim().isEmpty;
    return Text(
      empty ? '未填作者' : author,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: ui(size, c: empty ? d.ink3 : d.ink2),
    );
  }
}

/// 当前书详情（LIB-103、LIB-105）：大封面、书名与信息一行；检查状态与分项；
/// 主按钮“编辑章节”与四个入口；底部为来源文件与最近检查时间。
class BookSummaryPanel extends StatelessWidget {
  const BookSummaryPanel({
    super.key,
    required this.book,
    required this.open,
    required this.library,
    this.onReveal,
    this.headingHeight,
    this.headingGap = 12,
    this.outputs,
    this.onRevealOutput,
    this.onOutputHistory,
  });

  /// 转换历史；为 null 时不显示“最近输出”。
  final OutputHistoryService? outputs;

  /// 打开成品所在文件夹（成品不在时打开输出文件夹）；为 null 时不显示文件夹按钮。
  final Future<void> Function(OutputRecord)? onRevealOutput;

  /// 进入转换历史；为 null 时不显示“全部记录 →”。
  final VoidCallback? onOutputHistory;
  final BookSummary book;

  /// 书库详情栏顶部“当前书”一行的高度（与书库筛选行同高）；为 null 时不显示这一行，
  /// 打开文件夹的图标留在信息行里（例如窄窗口下的详情弹窗）。
  final double? headingHeight;

  /// “当前书”一行与封面之间的距离，使封面顶端与书架封面对齐。
  final double headingGap;
  final LibraryService library;
  final void Function(String) open;

  /// 在资源管理器中定位原文件；为 null 时不显示文件夹图标。
  final Future<void> Function(String)? onReveal;

  static String _bytes(int? bytes) => bytes == null
      ? ''
      : bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';

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

  /// 检查状态：一行章节问题数量与“查看问题 →”，下面分行列出清理建议、
  /// 待补充的书籍信息和最近检查时间（只列出有的项）。只有圆点用语义色。
  Widget _status(BuildContext context) {
    final d = context.desk;
    final pending = book.pending;
    final chapters = chapterIssueCount(book);
    final attention = bookNeedsAttention(book);
    final passed =
        pending != null &&
        chapters == 0 &&
        (book.status == '检查通过' || !attention);
    final text = chapters > 0
        ? '章节问题 $chapters 项'
        : pending == null
        ? book.status
        : passed
        ? '章节检查通过'
        : book.status.replaceFirst('检查完成 · ', '');
    final when = pending?.checkedAt;
    final rows = [
      if (pending != null && pending.cleanup > 0)
        ('清理建议', '${pending.cleanup} 处'),
      if (pending != null && pending.metadata > 0)
        ('书籍信息', '${pending.metadata} 项待补充'),
      if (when != null) ('最近检查', _time(when)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Tooltip(
          message: [
            book.status,
            if (pending != null && pending.total > 0) pending.breakdown,
          ].join('\n'),
          child: Row(
            key: const ValueKey('book-summary-status'),
            children: [
              Dot(
                attention
                    ? d.warn
                    : passed
                    ? d.accent
                    : d.ink3,
                size: 7,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(13, w: 600, c: d.ink),
                ),
              ),
              TextButton(
                key: const ValueKey('book-summary-open-checks'),
                style: TextButton.styleFrom(
                  foregroundColor: d.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => open('checks'),
                child: Text(attention || rows.length > 1 ? '查看问题 →' : '检查 →'),
              ),
            ],
          ),
        ),
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(left: 15, top: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(label, style: ui(12, c: d.ink3)),
                ),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12, c: d.ink2),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _tile(BuildContext context, String page, String label, IconData icon) {
    final d = context.desk;
    return OutlinedButton(
      key: ValueKey('book-summary-open-$page'),
      style: OutlinedButton.styleFrom(
        foregroundColor: d.ink,
        backgroundColor: d.paper,
        side: BorderSide(color: d.line),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        alignment: Alignment.centerLeft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: () => open(page),
      child: Row(
        children: [
          Icon(icon, size: 16, color: d.ink2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12.5, c: d.ink),
            ),
          ),
        ],
      ),
    );
  }

  /// 最近输出（LIB-113）：这本书最近 3 次输出的格式、时间与状态。
  Widget _recentOutputs(BuildContext context) {
    final d = context.desk;
    final history = outputs!;
    return ListenableBuilder(
      listenable: history.changes,
      builder: (context, _) {
        final rows = history.recentForBook(book.id);
        return Column(
          key: const ValueKey('book-summary-outputs'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('最近输出', style: ui(12.5, w: 620, c: d.ink)),
                ),
                if (onOutputHistory != null)
                  InkWell(
                    key: const ValueKey('book-summary-output-history'),
                    onTap: onOutputHistory,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 2,
                      ),
                      child: Text(
                        '全部记录 →',
                        style: ui(12, c: d.ink2).copyWith(
                          decoration: TextDecoration.underline,
                          decorationColor: d.ink3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('还没有输出过。', style: ui(12, c: d.ink3)),
              ),
            for (final row in rows) _outputRow(context, row),
          ],
        );
      },
    );
  }

  Widget _outputRow(BuildContext context, OutputRecord row) {
    final d = context.desk;
    final failed = row.status.contains('失败');
    final status = [
      row.status,
      if (row.bookMatch == OutputBookMatch.olderSource) '旧版原稿',
    ].join(' · ');
    return SizedBox(
      key: ValueKey('book-summary-output-${row.id}'),
      height: 30,
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 40),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: d.lineStrong),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              row.format,
              textAlign: TextAlign.center,
              style: mono(10.5, c: d.ink2),
            ),
          ),
          const SizedBox(width: 8),
          Text(_time(row.startedAt), style: mono(11, c: d.ink3)),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: row.bookMatch == OutputBookMatch.olderSource
                  ? '这次成品用的是旧版原稿；原稿后来重新导入，内容已不同。'
                  : row.detail,
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: failed ? d.pen : d.ink2),
              ),
            ),
          ),
          if (onRevealOutput != null)
            IconButton(
              key: ValueKey('book-summary-output-reveal-${row.id}'),
              tooltip: '打开文件夹',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              iconSize: 15,
              icon: Icon(Icons.folder_open_outlined, color: d.ink3),
              onPressed: () async {
                try {
                  await onRevealOutput!(row);
                } catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(deskErrorText(error, '未能打开输出文件夹：$error')),
                    ),
                  );
                }
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final metaStyle = ui(12, c: d.ink3);
    final meta = [
      book.format,
      _bytes(book.bytes),
    ].where((v) => v.isNotEmpty).join(' · ');
    final source = book.path.replaceAll('\\', '/').split('/').last;
    const entries = [
      ('layout', '排版', Icons.text_fields_rounded),
      ('cleanup', '文本清理', Icons.cleaning_services_outlined),
      ('information', '书籍信息', Icons.info_outline_rounded),
      ('overview', '书稿概览', Icons.space_dashboard_outlined),
    ];
    final reveal = onReveal == null
        ? null
        : IconButton(
            tooltip: '打开文件夹',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            iconSize: 15,
            icon: Icon(Icons.folder_open_outlined, color: d.ink3),
            onPressed: () => onReveal!(book.path),
          );
    // 本书识别规则（V23，CH-262）：只加图标，放在打开文件夹的左边。
    final rules = library is! ChapterRulesService
        ? null
        : IconButton(
            key: const ValueKey('book-summary-rules'),
            tooltip: '本书识别规则',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            iconSize: 15,
            icon: Icon(Icons.tune_rounded, color: d.ink3),
            onPressed: () => showChapterRulesDialog(
              context,
              service: library as ChapterRulesService,
              bookId: book.id,
            ),
          );
    return DeskScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (headingHeight != null) ...[
            SizedBox(
              height: headingHeight,
              child: Row(
                key: const ValueKey('book-summary-heading'),
                children: [
                  Expanded(
                    child: Text('当前书', style: ui(13, w: 650, c: d.ink2)),
                  ),
                  ?rules,
                  ?reveal,
                ],
              ),
            ),
            SizedBox(height: headingGap),
          ],
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                boxShadow: d.shadow2,
              ),
              child: LibraryCover(book, width: 150),
            ),
          ),
          const SizedBox(height: 16),
          Tooltip(
            message: book.title,
            child: Text(
              book.title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: serif(18, w: 650, c: d.ink, h: 1.35),
            ),
          ),
          const SizedBox(height: 4),
          BookAuthorText(book.author, textAlign: TextAlign.center),
          const SizedBox(height: 4),
          // 格式、大小与卷章用同一字体排成一行，文件夹图标与文字居中对齐。
          SizedBox(
            height: 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (meta.isNotEmpty)
                  Flexible(
                    child: Text(
                      '$meta · ',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metaStyle,
                    ),
                  ),
                Flexible(
                  child: BookStructureCounts(
                    library: library,
                    book: book,
                    compact: true,
                    style: metaStyle,
                  ),
                ),
                if (headingHeight == null) ?rules,
                if (headingHeight == null) ?reveal,
              ],
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: d.line),
          const SizedBox(height: 10),
          _status(context),
          const SizedBox(height: 14),
          SizedBox(
            height: 40,
            child: DeskButton(
              '编辑章节',
              key: const ValueKey('book-summary-open-chapters'),
              primary: true,
              icon: Icons.account_tree_outlined,
              onPressed: () => open('chapters'),
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, bounds) {
              final width = (bounds.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (page, label, icon) in entries)
                    SizedBox(
                      width: width,
                      child: _tile(context, page, label, icon),
                    ),
                ],
              );
            },
          ),
          if (outputs != null) ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: d.line),
            const SizedBox(height: 10),
            _recentOutputs(context),
          ],
          const SizedBox(height: 16),
          Divider(height: 1, color: d.line),
          const SizedBox(height: 10),
          Tooltip(
            message: book.path,
            child: Row(
              key: const ValueKey('book-summary-source'),
              children: [
                SizedBox(width: 64, child: Text('来源', style: metaStyle)),
                Expanded(
                  child: Text(
                    source,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12, c: d.ink2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
