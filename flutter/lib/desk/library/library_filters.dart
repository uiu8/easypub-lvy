part of 'library_page.dart';

// R2-10：从 library_page.dart 拆出，行为不变。搜索、格式与状态筛选、排序、显示范围；窄时收成“筛选”菜单。
extension _LibraryFilters on _LibraryPageState {
  /// 当前搜索与筛选下可见的书。
  List<BookSummary> filtered(List<BookSummary> books) => sortBooks(
    books
        .where(
          (b) => inLibraryScope(
            b,
            scope,
            collectionService?.collections.value ?? const [],
          ),
        )
        .where((b) => format == '全部格式' || b.format == format)
        .where(
          (b) => switch (filter) {
            '待处理' => b.status != '检查通过',
            '检查通过' => b.status == '检查通过',
            _ => true,
          },
        )
        .where((b) => !onlySelected || selected.contains(b.id))
        .where(
          (b) =>
              query.isEmpty ||
              '${b.title}\n${b.author}\n${b.path}\n${b.category}\n${b.series}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList(),
  );

  /// 排序方式（V84，LIB-127）；“默认顺序”为导入顺序（新导入的在前）。
  static const sortLabels = <String, String>{
    'default': '默认顺序（最近导入在前）',
    'title': '书名',
    'author': '作者',
    'category': '类别',
    'series': '系列',
    'format': '格式',
    'size': '大小',
    'status': '待处理多少',
  };

  List<BookSummary> sortBooks(List<BookSummary> books) {
    if (sort == 'default') return descending ? books.reversed.toList() : books;
    int text(String a, String b) {
      // 空值排在最后，不论升降序。
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    }

    final order = {for (var i = 0; i < books.length; i++) books[i].id: i};
    int compare(BookSummary a, BookSummary b) => switch (sort) {
      'title' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      'author' => a.author.toLowerCase().compareTo(b.author.toLowerCase()),
      'category' => a.category.toLowerCase().compareTo(
        b.category.toLowerCase(),
      ),
      'series' => a.series.toLowerCase().compareTo(b.series.toLowerCase()),
      'format' => a.format.compareTo(b.format),
      'size' => (a.bytes ?? -1).compareTo(b.bytes ?? -1),
      'status' => chapterIssueCount(a).compareTo(chapterIssueCount(b)),
      _ => 0,
    };
    final emptyLast = switch (sort) {
      'author' || 'category' || 'series' => true,
      _ => false,
    };
    String field(BookSummary b) => switch (sort) {
      'author' => b.author,
      'category' => b.category,
      _ => b.series,
    };
    return List.of(books)..sort((a, b) {
      if (emptyLast) {
        final blank = text(field(a), field(b));
        if (field(a).isEmpty != field(b).isEmpty) return blank;
      }
      final value = descending ? compare(b, a) : compare(a, b);
      return value != 0 ? value : order[a.id]!.compareTo(order[b.id]!);
    });
  }

  void changeSort(String value) {
    update(() {
      if (value == sort) {
        descending = !descending;
      } else {
        sort = value;
        descending = value == 'size' || value == 'status';
      }
    });
    rememberView();
  }

  /// 筛选行高度：与详情栏顶部“当前书”一行相同，两栏封面顶端因此对齐（LIB-105）。
  double filterRowHeight(BuildContext context) =>
      40 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);

  Widget filters([List<BookSummary> visible = const []]) => LayoutBuilder(
    builder: (context, bounds) => _filters(bounds.maxWidth, visible),
  );

  Widget _filters(double width, List<BookSummary> visible) {
    final d = context.desk;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.4);
    final allVisible =
        visible.isNotEmpty && visible.every((b) => selected.contains(b.id));
    // 搜索框在放得下时为 300 宽；放不下时先缩短搜索框，让控件留在同一行（LIB-105 两栏封面对齐）。
    // 完整一行约需：搜索 200 + 格式、状态、仅看已勾选 + 全选、排序、视图。
    // 再窄时（V84b）格式、状态、仅看已勾选与显示范围收进一个“筛选”菜单。
    // 左栏开关 V94 移到标题行最左，筛选行不再给它留位置。
    const railToggle = 0;
    final full =
        464 +
        railToggle +
        (scopeChoice ? 150 : 0) +
        (collectionService != null ? 40 : 0);
    final compactFilters = width - 46 < (200 + full) * scale;
    filtersCompact = compactFilters;
    final search = SizedBox(
      width:
          (width - 40 - 6 - (compactFilters ? 184 + railToggle : full) * scale)
              .clamp(compactFilters ? 140.0 : 200.0, 300.0),
      height: filterRowHeight(context),
      child: TextField(
        controller: searchInput,
        focusNode: searchFocus,
        style: ui(13, c: d.ink),
        decoration: deskInput(context, hint: '搜索书名、作者或文件名').copyWith(
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: d.ink3),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
        ),
        onChanged: (v) => changeFilter(search: v),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          search,
          if (compactFilters) filterMenu(),
          if (!compactFilters)
            Tooltip(
              message: '筛选文件格式',
              child: DeskFilter<String>(
                value: format,
                onChanged: (value) => changeFilter(sourceFormat: value),
                onClear: format == '全部格式'
                    ? null
                    : () => changeFilter(sourceFormat: '全部格式'),
                items: [
                  for (final value in ['全部格式', 'TXT', 'EPUB'])
                    DropdownMenuItem(value: value, child: Text(value)),
                ],
              ),
            ),
          if (!compactFilters)
            Tooltip(
              message: '筛选书稿',
              child: DeskFilter<String>(
                value: filter,
                onChanged: (value) => changeFilter(category: value),
                onClear: filter == '全部书稿'
                    ? null
                    : () => changeFilter(category: '全部书稿'),
                items: [
                  // 值沿用“全部书稿”（视图状态里存的是它），显示为“全部状态”，与左栏的“全部书稿”区分。
                  for (final value in ['全部书稿', '待处理', '检查通过'])
                    DropdownMenuItem(
                      value: value,
                      child: Text(value == '全部书稿' ? '全部状态' : value),
                    ),
                ],
              ),
            ),
          if (!compactFilters)
            FilterChip(
              label: const Text('仅看已勾选'),
              selected: onlySelected,
              onSelected: (value) => changeFilter(checkedOnly: value),
            ),
          // 全选当前筛选结果（原在书架上方单独一行，移到这里后两栏封面顶端对齐）。
          IconButton(
            key: const ValueKey('library-select-visible'),
            tooltip: allVisible ? '取消筛选结果勾选' : '全选筛选结果',
            onPressed: visible.isEmpty
                ? null
                : () => checkMany(visible.map((b) => b.id), !allVisible),
            icon: Icon(
              allVisible ? Icons.deselect_rounded : Icons.select_all_rounded,
              color: d.ink2,
            ),
          ),
          if (scopeChoice && !compactFilters)
            Tooltip(
              message: '显示范围：全部、收藏夹或类别',
              child: DeskFilter<String>(
                key: const ValueKey('library-scope-filter'),
                value: scope,
                onChanged: (value) => changeFilter(libraryScope: value ?? ''),
                onClear: scope.isEmpty
                    ? null
                    : () => changeFilter(libraryScope: ''),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部书稿')),
                  for (final c in collectionService!.collections.value)
                    DropdownMenuItem(
                      value: collectionScope(c.id),
                      child: Text('收藏夹 · ${c.name}'),
                    ),
                  for (final (name, _) in libraryCategories(
                    widget.library.books.value,
                  ))
                    DropdownMenuItem(
                      value: categoryScope(name),
                      child: Text(name.isEmpty ? '未分类' : '类别 · $name'),
                    ),
                ],
              ),
            ),
          DeskCommandMenu<String>(
            key: const ValueKey('library-sort'),
            tooltip:
                '排序：${sortLabels[sort]}${sort == 'default' && !descending
                    ? ''
                    : descending
                    ? '，降序'
                    : '，升序'}',
            onSelected: changeSort,
            itemBuilder: (_) => [
              for (final e in sortLabels.entries)
                PopupMenuItem(
                  height: 36,
                  value: e.key,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        child: e.key == sort
                            ? Icon(
                                descending
                                    ? Icons.arrow_downward_rounded
                                    : Icons.arrow_upward_rounded,
                                size: 15,
                              )
                            : null,
                      ),
                      Text(e.value),
                    ],
                  ),
                ),
            ],
            icon: Icon(
              Icons.sort_rounded,
              color: sort == 'default' && !descending ? d.ink2 : d.ink,
            ),
          ),
          if (collectionService != null)
            IconButton(
              key: const ValueKey('library-folder-toggle'),
              tooltip: folderMode ? '切换到平铺模式' : '切换到收藏夹模式',
              isSelected: folderMode,
              onPressed: toggleFolders,
              icon: Icon(
                folderMode ? Icons.folder_rounded : Icons.folder_outlined,
                color: folderMode ? d.ink : d.ink2,
              ),
            ),
          IconButton(
            key: const ValueKey('library-view-toggle'),
            tooltip: compact ? '切换书架视图' : '切换列表视图',
            onPressed: changeView,
            icon: Icon(
              compact ? Icons.grid_view_rounded : Icons.view_list_outlined,
              color: d.ink2,
            ),
          ),
        ],
      ),
    );
  }

  /// 窄时的“筛选”菜单（V84b）：格式、状态、仅看已勾选；没有左栏时还有显示范围。
  Widget filterMenu() {
    final d = context.desk;
    final active = [
      if (format != '全部格式') format,
      if (filter != '全部书稿') filter,
      if (onlySelected) '仅看已勾选',
      if (scope.isNotEmpty && !railListsScope)
        scopeLabel(scope, collectionService?.collections.value ?? const []),
    ];
    PopupMenuEntry<String> heading(String text) => PopupMenuItem<String>(
      enabled: false,
      height: 28,
      child: Text(text, style: ui(11.5, w: 650, c: d.ink3)),
    );
    PopupMenuEntry<String> option(String value, String label, bool on) =>
        CheckedPopupMenuItem<String>(
          height: 36,
          value: value,
          checked: on,
          child: Text(label),
        );
    return DeskCommandMenu<String>(
      key: const ValueKey('library-filter-menu'),
      tooltip: active.isEmpty ? '筛选' : '筛选：${active.join('、')}',
      onSelected: (value) {
        final (kind, rest) = (
          value.substring(0, value.indexOf(':')),
          value.substring(value.indexOf(':') + 1),
        );
        switch (kind) {
          case 'format':
            changeFilter(sourceFormat: rest);
          case 'status':
            changeFilter(category: rest);
          case 'checked':
            changeFilter(checkedOnly: !onlySelected);
          case 'scope':
            changeFilter(libraryScope: rest);
        }
      },
      itemBuilder: (_) => [
        heading('格式'),
        for (final v in ['全部格式', 'TXT', 'EPUB'])
          option('format:$v', v, format == v),
        const PopupMenuDivider(),
        heading('状态'),
        for (final v in ['全部书稿', '待处理', '检查通过'])
          option('status:$v', v == '全部书稿' ? '全部状态' : v, filter == v),
        const PopupMenuDivider(),
        option('checked:', '仅看已勾选', onlySelected),
        if (collectionService != null && !railListsScope && !folderMode) ...[
          const PopupMenuDivider(),
          heading('显示范围'),
          option('scope:', '全部书稿', scope.isEmpty),
          for (final c in collectionService!.collections.value)
            option(
              'scope:${collectionScope(c.id)}',
              '收藏夹 · ${c.name}',
              scope == collectionScope(c.id),
            ),
          for (final (name, _) in libraryCategories(widget.library.books.value))
            option(
              'scope:${categoryScope(name)}',
              name.isEmpty ? '未分类' : '类别 · $name',
              scope == categoryScope(name),
            ),
        ],
      ],
      icon: Badge(
        isLabelVisible: active.isNotEmpty,
        smallSize: 7,
        backgroundColor: d.ink,
        child: Icon(
          Icons.filter_list_rounded,
          color: active.isEmpty ? d.ink2 : d.ink,
        ),
      ),
    );
  }
}
