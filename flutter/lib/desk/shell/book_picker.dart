import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../library/book_structure_counts.dart';
import '../library/book_summary_panel.dart';
import '../tokens.dart';
import '../widgets.dart';

// 选书弹窗（G-018–021；R1 改用编辑台弹窗）：每行显示封面、书名、作者 · 格式 · 章数与检查状态，
// 当前书标“当前”；搜索框保持焦点，↑↓ 移动选中行，回车打开。

Future<String?> chooseWorkspaceBook(
  BuildContext context,
  LibraryService library,
) => showDialog<String>(
  context: context,
  builder: (_) => _BookPicker(library: library),
);

class _BookPicker extends StatefulWidget {
  const _BookPicker({required this.library});
  final LibraryService library;
  @override
  State<_BookPicker> createState() => _BookPickerState();
}

class _BookPickerState extends State<_BookPicker> {
  static const rowHeight = 56.0;
  final scroll = ScrollController();
  String query = '';

  /// 键盘选中的行；-1 表示还没有用键盘选过（回车打开第一行）。
  int highlight = -1;
  bool done = false;

  /// 打开选中的书（回车键与输入框“提交”都会走到这里，只生效一次）。
  void openSelected(List<BookSummary> shown) {
    if (done || shown.isEmpty) return;
    done = true;
    Navigator.pop(context, shown[highlight < 0 ? 0 : highlight].id);
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  List<BookSummary> visible(List<BookSummary> books) => books
      .where(
        (b) => '${b.title} ${b.author} ${b.path}'.toLowerCase().contains(query),
      )
      .toList();

  void move(int delta, int count) {
    if (count == 0) return;
    setState(() => highlight = (highlight + delta).clamp(0, count - 1));
    // 选中行保持在可见范围内。
    if (!scroll.hasClients) return;
    final top = highlight * rowHeight;
    final view = scroll.position.viewportDimension;
    if (top < scroll.offset) {
      scroll.jumpTo(top);
    } else if (top + rowHeight > scroll.offset + view) {
      scroll.jumpTo(top + rowHeight - view);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final current = widget.library.selection.value.current;
    return ValueListenableBuilder<List<BookSummary>>(
      valueListenable: widget.library.books,
      builder: (context, books, _) {
        final shown = visible(books);
        return DeskDialog(
          title: '选择书稿',
          subtitle: books.isEmpty ? null : '共 ${books.length} 本 · ↑↓ 选择，回车打开',
          closeTooltip: '关闭',
          width: 560,
          height: 560,
          scrollBody: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      move(1, shown.length),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      move(-1, shown.length),
                  const SingleActivator(LogicalKeyboardKey.enter): () =>
                      openSelected(shown),
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
                      openSelected(shown),
                },
                child: TextField(
                  key: const ValueKey('book-picker-search'),
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '搜索书名、作者或文件名',
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onChanged: (value) => setState(() {
                    query = value.trim().toLowerCase();
                    highlight = -1;
                  }),
                  onSubmitted: (_) => openSelected(shown),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: DeskText(
                          books.isEmpty ? '书库还是空的，请先导入书稿。' : '没有找到这本书。',
                          color: d.ink2,
                        ),
                      )
                    : DeskScrollArea(
                        controller: scroll,
                        builder: (controller) => ListView.builder(
                          controller: controller,
                          itemExtent: rowHeight,
                          itemCount: shown.length,
                          itemBuilder: (_, index) => _BookRow(
                            library: widget.library,
                            book: shown[index],
                            current: shown[index].id == current,
                            highlighted: index == highlight,
                            onTap: () =>
                                Navigator.pop(context, shown[index].id),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.library,
    required this.book,
    required this.current,
    required this.highlighted,
    required this.onTap,
  });
  final LibraryService library;
  final BookSummary book;
  final bool current, highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final status = bookStatusLabel(book);
    // 卷数与章数按书的实际结构统计（与书库相同），不用识别到的标题数（卷标题也算在内）。
    final meta =
        '${book.author.isEmpty ? '未填作者' : book.author} · ${book.format.toUpperCase()}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        key: ValueKey('book-picker-row-${book.id}'),
        color: highlighted
            ? d.sunken
            : current
            ? d.accentSoft
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: d.sunken,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LibraryCover(book, width: 30),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(13.5, w: 600, c: d.ink),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ui(12, c: d.ink2),
                            ),
                          ),
                          BookStructureCounts(
                            library: library,
                            book: book,
                            prefix: ' · ',
                            style: ui(12, c: d.ink2),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (status.attention) ...[
                  Dot(d.warn, size: 6),
                  const SizedBox(width: 5),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    status.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12, c: status.attention ? d.ink : d.ink3),
                  ),
                ),
                if (current) ...[
                  const SizedBox(width: 8),
                  const DeskTag('当前', Tone.accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
