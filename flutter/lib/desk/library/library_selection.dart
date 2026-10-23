part of 'library_page.dart';

// R2-10：从 library_page.dart 拆出，行为不变。勾选工具条与批量检查进度。
extension _LibrarySelection on _LibraryPageState {
  /// 勾选工具条：全选 / 清空 / 检查所选 / 应用到多本书 / 移除所选；有勾选时浅灰墨底。
  /// 有勾选，或有批量检查的进度与结果时显示批量操作条。
  bool get selectionBarShown {
    final checks = batchChecks;
    return selected.isNotEmpty ||
        (checks != null &&
            (checks.checkBatch.running || checks.checkBatch.total > 0));
  }

  Widget selectionBar(
    List<BookSummary> visible,
    BookSummary current,
    bool importing,
  ) {
    final d = context.desk;
    final checks = batchChecks;
    // 没有勾选、也没有批量检查记录时不显示。
    if (!selectionBarShown) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('library-selection-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          selected.isEmpty ? Colors.transparent : d.accentSoft,
          d.paper,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
        boxShadow: d.shadow2,
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (selected.isNotEmpty)
            Text(
              '已勾选 ${selected.length} 本 · 筛选外 ${selected.difference(visible.map((b) => b.id).toSet()).length} 本',
              style: ui(12, w: 600, c: d.ink),
            ),
          if (selected.isNotEmpty)
            DeskButton(
              '清空勾选',
              quiet: true,
              onPressed: selected.isEmpty
                  ? null
                  : () => checkMany(selected, false),
            ),
          if (checks != null) ...[
            if (selected.isNotEmpty)
              DeskButton(
                '检查所选',
                icon: Icons.fact_check_outlined,
                quiet: true,
                onPressed:
                    selected.isEmpty || importing || checks.checkBatch.running
                    ? null
                    : inspectSelected,
              ),
            if (checks.checkBatch.running)
              DeskButton(
                checks.checkBatch.stopping ? '正在停止' : '当前书完成后停止',
                quiet: true,
                onPressed: checks.checkBatch.stopping
                    ? null
                    : checks.checkBatch.stop,
              ),
            if (checks.checkBatch.total > 0)
              DeskButton(
                '${checks.checkBatch.running
                    ? '检查中 '
                    : checks.checkBatch.cancelled
                    ? '已停止 '
                    : '检查完成 '}${checks.checkBatch.results.length}/${checks.checkBatch.total}',
                quiet: true,
                onPressed: showCheckResults,
              ),
          ],
          if (selected.isNotEmpty)
            DeskButton(
              '应用到多本书',
              icon: Icons.library_add_check_outlined,
              quiet: true,
              onPressed: selected.isEmpty || importing || picking
                  ? null
                  : () => showDialog<bool>(
                      context: context,
                      builder: (_) => BookBatchDialog(
                        library: widget.library,
                        bookId: current.id,
                      ),
                    ),
            ),
          if (collectionService != null && selected.isNotEmpty) ...[
            DeskButton(
              '加入收藏夹…',
              key: const ValueKey('library-collect-selected'),
              icon: Icons.bookmark_add_outlined,
              quiet: true,
              tooltip: '也可以把勾选的书直接拖到左侧收藏夹',
              onPressed: importing ? null : () => collect(selected.toList()),
            ),
            DeskButton(
              '设类别…',
              key: const ValueKey('library-set-category'),
              icon: Icons.label_outline_rounded,
              quiet: true,
              onPressed: importing
                  ? null
                  : () => setCategory(
                      context,
                      collectionService!,
                      selected.toList(),
                    ),
            ),
            if (currentCollection != null)
              DeskButton(
                '移出此收藏夹',
                key: const ValueKey('library-uncollect-selected'),
                icon: Icons.bookmark_remove_outlined,
                quiet: true,
                onPressed: () {
                  try {
                    collectionService!.removeFromCollection(
                      currentCollection!,
                      selected,
                    );
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(deskErrorText(e, '未能移出。'))),
                    );
                  }
                },
              ),
          ],
          if (removals != null && selected.isNotEmpty)
            DeskButton(
              '移除所选',
              icon: Icons.remove_circle_outline_rounded,
              quiet: true,
              onPressed: selected.isEmpty
                  ? null
                  : () => remove(Set.of(selected)),
            ),
        ],
      ),
    );
  }
}
