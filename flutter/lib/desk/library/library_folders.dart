part of 'library_page.dart';

// 收藏夹模式（V104，LIB-283–285）：书库顶层是收藏夹文件夹，点进去看书；不在任何收藏夹里的书
// 归入“未分类”，固定在最后。一本书在几个收藏夹里，就在几个文件夹里出现，书本身只有一份。
extension _LibraryFolders on _LibraryPageState {
  bool get folderMode => folders && collectionService != null;

  /// 正在看收藏夹顶层（有搜索词时改为在全部书里搜，直接列书）。
  bool get folderTop => folderMode && scope.isEmpty && query.isEmpty;

  static const folderOrders = <String, String>{
    'custom': '创建顺序',
    'name': '名称',
    'count': '书数（多的在前）',
  };

  void toggleFolders() {
    update(() {
      folders = !folders;
      // 类别范围只属于平铺模式的左栏；“未分类”只属于收藏夹模式。
      if (folders ? scope.startsWith('k:') : scope == unfiledScope) scope = '';
      rangeAnchor = null;
      _restore = false;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    rememberView();
  }

  /// 收藏夹及其中（当前筛选下）可见的书，按所选顺序；“未分类”不在其中。
  List<(BookCollection, List<BookSummary>)> folderEntries(
    List<BookSummary> books,
  ) {
    final entries = [
      for (final c in collectionService!.collections.value)
        (
          c,
          [
            for (final b in books)
              if (c.books.contains(b.id)) b,
          ],
        ),
    ];
    switch (folderOrder) {
      case 'name':
        entries.sort(
          (a, b) => a.$1.name.toLowerCase().compareTo(b.$1.name.toLowerCase()),
        );
      case 'count':
        // 稳定排序：书数相同时保持创建顺序。
        final order = {
          for (var i = 0; i < entries.length; i++) entries[i].$1.id: i,
        };
        entries.sort((a, b) {
          final value = b.$2.length.compareTo(a.$2.length);
          return value != 0
              ? value
              : order[a.$1.id]!.compareTo(order[b.$1.id]!);
        });
    }
    return entries;
  }

  /// 收藏夹顶层：上方一行是数量、排列顺序与新建，下面是文件夹格子。
  Widget folderGrid(List<BookSummary> books) {
    final d = context.desk;
    final service = collectionService!;
    final collections = service.collections.value;
    final entries = folderEntries(books);
    final unfiled = [
      for (final b in books)
        if (unfiledBook(b, collections)) b,
    ];
    folderKeys.removeWhere((id, _) => !collections.any((c) => c.id == id));
    return Column(
      key: const ValueKey('library-folders'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 14, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${entries.length} 个收藏夹 · 未分类 ${unfiled.length} 本',
                  style: ui(12, c: d.ink3),
                ),
              ),
              DeskCommandMenu<String>(
                key: const ValueKey('library-folder-order'),
                tooltip: '收藏夹顺序：${folderOrders[folderOrder]}',
                onSelected: (value) {
                  update(() => folderOrder = value);
                  rememberView();
                },
                itemBuilder: (_) => [
                  for (final e in folderOrders.entries)
                    CheckedPopupMenuItem(
                      height: 36,
                      value: e.key,
                      checked: e.key == folderOrder,
                      child: Text(e.value),
                    ),
                ],
                icon: Icon(Icons.swap_vert_rounded, color: d.ink2),
              ),
              DeskButton(
                '新建收藏夹',
                key: const ValueKey('library-folder-new'),
                icon: Icons.add_rounded,
                quiet: true,
                onPressed: () => createCollection(context, service),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(1);
              const pad = 20.0, gap = 18.0, minTile = 150.0;
              final columns = ((box.maxWidth - 2 * pad + gap) / (minTile + gap))
                  .floor()
                  .clamp(1, 12);
              final tile =
                  (box.maxWidth - 2 * pad - gap * (columns - 1)) / columns;
              return GridView(
                key: const ValueKey('library-folder-grid'),
                padding: EdgeInsets.fromLTRB(
                  pad,
                  8,
                  pad,
                  selectionBarShown ? 76 : 20,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: gap,
                  mainAxisSpacing: gap,
                  mainAxisExtent: tile * .78 + 66 * scale,
                ),
                children: [
                  for (final (c, members) in entries)
                    folderTile(
                      key: folderKeys.putIfAbsent(c.id, GlobalKey.new),
                      id: c.id,
                      collection: c,
                      name: c.name,
                      members: members,
                      width: tile,
                    ),
                  folderTile(
                    key: const ValueKey('library-folder-unfiled'),
                    id: unfiledScope,
                    name: '未分类',
                    members: unfiled,
                    width: tile,
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// 一个收藏夹文件夹：前三本书的封面叠在一起，下面是名称与书数。
  /// 已勾选的书可以拖进来；外部文件拖到这里松开，导入后加入它（由 [collectionAt] 判断）。
  Widget folderTile({
    required Key key,
    required String id,
    BookCollection? collection,
    required String name,
    required List<BookSummary> members,
    required double width,
  }) {
    final d = context.desk;
    final service = collectionService!;
    final shown = members.take(3).toList();
    Widget body(bool highlight) => _Hover(
      builder: (hovering) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => changeFilter(
          libraryScope: collection == null ? unfiledScope : collectionScope(id),
        ),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: highlight
                ? d.accentSoft
                : hovering
                ? d.surface
                : null,
            borderRadius: BorderRadius.circular(10),
            border: highlight ? Border.all(color: d.accent, width: 2) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面区占名称与书数以外的全部高度，字号或高亮边框变化时不会溢出。
              Expanded(
                child: shown.isEmpty
                    ? Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: d.sunken,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: d.line),
                        ),
                        child: Icon(
                          collection == null
                              ? Icons.inbox_outlined
                              : Icons.folder_open_outlined,
                          size: 28,
                          color: d.ink3,
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, box) {
                          // 封面高度正好填满封面区（封面宽高比 3:4）。
                          final coverWidth = (box.maxHeight * .75).clamp(
                            0.0,
                            box.maxWidth,
                          );
                          final step = shown.length < 2
                              ? 0.0
                              : ((box.maxWidth - coverWidth) /
                                        (shown.length - 1))
                                    .clamp(0.0, 26.0);
                          return Stack(
                            children: [
                              for (var i = shown.length - 1; i >= 0; i--)
                                Positioned(
                                  left: step * i,
                                  bottom: 0,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(5),
                                      boxShadow: d.shadow1,
                                    ),
                                    child: LibraryCover(
                                      shown[i],
                                      width: coverWidth,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    collection == null
                        ? Icons.inbox_outlined
                        : collection.hasTemplate
                        ? Icons.bookmarks_outlined
                        : Icons.bookmark_border_rounded,
                    size: 15,
                    color: d.ink2,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(13, w: 600, c: d.ink),
                    ),
                  ),
                  // “未分类”没有菜单，也留出同样的高度，名称行与其他文件夹对齐。
                  SizedBox(
                    width: 30,
                    height: 28,
                    child: collection == null
                        ? null
                        : AnimatedOpacity(
                            duration: DeskMotion.of(context, DeskMotion.fast),
                            curve: DeskMotion.easeOut,
                            opacity: hovering ? 1 : 0,
                            child: FittedBox(
                              child: collectionMenu(
                                context,
                                service,
                                collection,
                                count: members.length,
                                onDeleted: () {},
                              ),
                            ),
                          ),
                  ),
                ],
              ),
              Text(
                collection == null
                    ? '${members.length} 本 · 不在任何收藏夹'
                    : '${members.length} 本',
                style: ui(11.5, c: d.ink3),
              ),
            ],
          ),
        ),
      ),
    );
    return Material(
      key: key,
      type: MaterialType.transparency,
      child: Tooltip(
        message: collection == null ? '不在任何收藏夹里的书' : '点开查看；把勾选的书拖到这里加入',
        waitDuration: const Duration(milliseconds: 600),
        child: collection == null
            ? body(false)
            : DragTarget<LibraryBookDrag>(
                onAcceptWithDetails: (details) =>
                    joinCollection(context, service, id, details.data.ids),
                builder: (context, candidates, _) =>
                    body(candidates.isNotEmpty || fileHoverCollection == id),
              ),
      ),
    );
  }

  /// 收藏夹里的路径行：返回顶层、当前收藏夹名与书数。
  Widget folderCrumb(int count) {
    final d = context.desk;
    final collections = collectionService!.collections.value;
    final name = scope == unfiledScope
        ? '未分类'
        : collections
                  .where((c) => collectionScope(c.id) == scope)
                  .firstOrNull
                  ?.name ??
              '全部书稿';
    return Padding(
      key: const ValueKey('library-folder-crumb'),
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('library-folder-back'),
            tooltip: '返回全部收藏夹',
            visualDensity: VisualDensity.compact,
            onPressed: () => changeFilter(libraryScope: ''),
            icon: Icon(Icons.arrow_back_rounded, size: 18, color: d.ink2),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => changeFilter(libraryScope: ''),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text('书库', style: ui(12.5, c: d.ink2)),
            ),
          ),
          Text(' / ', style: ui(12.5, c: d.ink3)),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12.5, w: 600, c: d.ink),
            ),
          ),
          const SizedBox(width: 8),
          Text('$count 本', style: ui(12, c: d.ink3)),
          // 收藏夹里看不到别的文件夹：拖动勾选的书时，在这里列出其他收藏夹供放入。
          if (bookDragging) ...[
            const SizedBox(width: 16),
            Text('拖到：', style: ui(12, c: d.ink2)),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final c in collections)
                      if (collectionScope(c.id) != scope)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: DragTarget<LibraryBookDrag>(
                            key: ValueKey('library-folder-drop-${c.id}'),
                            onAcceptWithDetails: (details) => joinCollection(
                              context,
                              collectionService!,
                              c.id,
                              details.data.ids,
                            ),
                            builder: (context, candidates, _) => Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: candidates.isNotEmpty
                                    ? d.accentSoft
                                    : d.surface,
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(
                                  color: candidates.isNotEmpty
                                      ? d.accent
                                      : d.lineStrong,
                                ),
                              ),
                              child: Text(c.name, style: ui(12, c: d.ink)),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
