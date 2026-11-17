part of 'library_page.dart';

// 从 library_page.dart 拆出，行为不变。勾选工具条与批量检查进度。
extension _LibrarySelection on _LibraryPageState {
  /// 纸面批量操作条：常用操作直达，其余操作收进统一命令菜单。
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
    final hiddenCount = selected
        .difference(visible.map((b) => b.id).toSet())
        .length;
    // 没有勾选、也没有批量检查记录时不显示。
    if (!selectionBarShown) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('library-selection-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: d.paper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
        boxShadow: d.shadow1,
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (selected.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: d.sunken,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '已勾选 ${selected.length} 本${hiddenCount > 0 ? ' · 筛选外 $hiddenCount 本' : ''}',
                style: ui(12, w: 600, c: d.ink2),
              ),
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
          ],
          if (selected.isNotEmpty &&
              (collectionService != null || removals != null))
            DeskCommandMenu<String>(
              key: const ValueKey('library-selection-more'),
              tooltip: '更多批量操作',
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('更多', style: ui(14, c: d.ink2)),
                    const SizedBox(width: 4),
                    Icon(Icons.expand_more_rounded, size: 17, color: d.ink2),
                  ],
                ),
              ),
              onSelected: (action) {
                switch (action) {
                  case 'category':
                    setCategory(context, collectionService!, selected.toList());
                  case 'uncollect':
                    try {
                      collectionService!.removeFromCollection(
                        currentCollection!,
                        selected,
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        deskSnackBar(content: Text(deskErrorText(e, '未能移出。'))),
                      );
                    }
                  case 'remove':
                    remove(Set.of(selected));
                  case 'delete':
                    deletePermanently(Set.of(selected));
                }
              },
              itemBuilder: (_) => [
                if (collectionService != null)
                  PopupMenuItem(
                    key: const ValueKey('library-set-category'),
                    value: 'category',
                    enabled: !importing,
                    child: const Text('设类别…'),
                  ),
                if (collectionService != null && currentCollection != null)
                  const PopupMenuItem(
                    key: ValueKey('library-uncollect-selected'),
                    value: 'uncollect',
                    child: Text('移出此收藏夹'),
                  ),
                if (collectionService != null && removals != null)
                  const PopupMenuDivider(),
                if (removals != null) ...[
                  const PopupMenuItem(value: 'remove', child: Text('移除所选')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('彻底删除…', style: ui(13, c: d.pen)),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}
