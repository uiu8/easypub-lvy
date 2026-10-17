import 'package:flutter/material.dart';

import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

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
  String query = '';
  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: DeskText('选择书稿', size: 20, bold: true)),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索书名、作者或文件名',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) =>
                  setState(() => query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ValueListenableBuilder<List<BookSummary>>(
                valueListenable: widget.library.books,
                builder: (context, books, _) {
                  final visible = books
                      .where(
                        (b) => '${b.title} ${b.author} ${b.path}'
                            .toLowerCase()
                            .contains(query),
                      )
                      .toList();
                  if (visible.isEmpty) {
                    return Center(
                      child: DeskText(
                        books.isEmpty ? '书库还是空的，请先导入书稿。' : '没有找到这本书。',
                        color: context.desk.ink2,
                      ),
                    );
                  }
                  return DeskScrollArea(
                    builder: (controller) => ListView.builder(
                      controller: controller,
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final book = visible[index];
                        return ListTile(
                          selected:
                              book.id == widget.library.selection.value.current,
                          leading: const Icon(Icons.menu_book_outlined),
                          title: Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            book.author.isEmpty ? '未填作者' : book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.pop(context, book.id),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
