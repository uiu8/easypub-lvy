part of 'library_page.dart';

// R2-10：从 library_page.dart 拆出，行为不变。标题行：书库名、本数、自动入库角标、提示或导入进度（R2-01）、导入按钮。
extension _LibraryHeader on _LibraryPageState {
  Widget header(
    bool importing, {
    required bool wide,
    List<BookSummary> books = const [],
  }) {
    final d = context.desk;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: d.line)),
      ),
      child: Row(
        children: [
          // 左栏开关（V94）：放在标题最左，像常见的侧边栏按钮；点一下整栏滑出或收起。
          if (railAvailable) ...[
            IconButton(
              key: const ValueKey('library-rail-toggle'),
              tooltip: !railCanExpand
                  ? '窗口较窄，收藏夹栏只显示图标'
                  : railHidden
                  ? '展开收藏夹栏'
                  : '收起收藏夹栏',
              visualDensity: VisualDensity.compact,
              isSelected: !railHidden,
              onPressed: railCanExpand
                  ? () => setRail(collapsed: !railCollapsed)
                  : null,
              icon: Transform.flip(
                flipX: true,
                child: Icon(
                  Icons.view_sidebar_outlined,
                  size: 20,
                  color: d.ink2,
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text('书库', style: ui(16, w: 650, c: d.ink)),
          if (books.isNotEmpty) ...[
            const SizedBox(width: 8),
            Builder(
              builder: (context) {
                final shown = filtered(books).length;
                return Text(
                  shown == books.length
                      ? '${books.length} 本'
                      : '$shown / ${books.length} 本',
                  key: const ValueKey('library-count'),
                  style: ui(13, w: 600, c: d.ink2),
                );
              },
            ),
          ],
          // 文件夹自动入库（V26，FOLD-081/082）：新增与原稿缺失的小角标，没有时不占位置。
          if (widget.library case final FolderAutoImportService auto)
            ValueListenableBuilder<AutoImportState>(
              valueListenable: auto.autoImportState,
              builder: (_, state, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state.added.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _AutoImportBadge(
                      key: const ValueKey('library-auto-import-added'),
                      icon: Icons.sync_rounded,
                      text: '新增 ${state.added.length}',
                      tooltip: [
                        '自动入库导入了：',
                        ...state.added.take(10),
                        if (state.added.length > 10)
                          '…共 ${state.added.length} 本',
                        '点击收起',
                      ].join('\n'),
                      onTap: auto.acknowledgeAutoImport,
                    ),
                  ],
                  if (state.missing.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _AutoImportBadge(
                      key: const ValueKey('library-auto-import-missing'),
                      icon: Icons.report_gmailerrorred_rounded,
                      text: '原稿缺失 ${state.missing.length}',
                      warn: true,
                      tooltip: [
                        '自动入库文件夹里找不到这些书的原稿（书仍在书库）：',
                        ...books
                            .where((b) => state.missing.contains(b.id))
                            .take(10)
                            .map((b) => b.title),
                      ].join('\n'),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(width: 12),
          if (fileImporting && importTotal > 0)
            Expanded(child: importProgress(books.length))
          else
            Expanded(
              child: Text(
                selected.isEmpty
                    ? '点击书名查看 · 勾选后批量操作'
                    : '在勾选列拖动可连选，拖动行可框选；Ctrl / Shift 点击多选',
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: d.ink3),
              ),
            ),
          // 已有右侧详情栏时不再重复这个入口（LIB-108）。
          if (!widget.showConversionActions && currentId != null && !wide)
            DeskButton(
              '当前书详情',
              icon: Icons.info_outline_rounded,
              quiet: true,
              onPressed: currentId == null ? null : showCurrentDetails,
            ),
          if ((removals?.removedBatchCount.value ?? 0) > 0)
            DeskButton(
              '撤销移除',
              icon: Icons.restore_rounded,
              quiet: true,
              onPressed: restoreBooks,
            ),
          DeskCommandMenu<String>(
            tooltip: '更多导入方式',
            enabled: !importing && !picking,
            onSelected: (kind) {
              if (kind == 'files') {
                importBooks();
              } else {
                importFolder(favorite: kind == 'favorites');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(height: 36, value: 'files', child: Text('导入文件')),
              PopupMenuItem(height: 36, value: 'folder', child: Text('导入文件夹')),
              PopupMenuItem(
                height: 36,
                value: 'favorites',
                child: Text('从收藏文件夹导入'),
              ),
            ],
            icon: Icon(Icons.expand_more_rounded, color: d.ink2),
          ),
          const SizedBox(width: 4),
          DeskButton(
            importing ? '取消导入' : '导入',
            icon: importing ? Icons.close_rounded : Icons.file_open_outlined,
            primary: true,
            onPressed: importing
                ? cancelImport
                : picking
                ? null
                : importBooks,
          ),
        ],
      ),
    );
  }

  /// 导入进度（R2-01）：按新加入书库的本数计；已在书库或失败的文件不计入。
  Widget importProgress(int count) {
    final d = context.desk;
    final added = (count - importBase).clamp(0, importTotal);
    return Row(
      key: const ValueKey('library-import-progress'),
      children: [
        Flexible(
          child: Text(
            importCancelled ? '正在停止导入…' : '正在导入 · 已加入 $added / $importTotal',
            overflow: TextOverflow.ellipsis,
            style: ui(12, w: 600, c: d.ink2),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 120,
          height: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: d.sunken)),
                FractionallySizedBox(
                  widthFactor: importTotal == 0 ? 0 : added / importTotal,
                  heightFactor: 1,
                  child: ColoredBox(color: d.accent),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
