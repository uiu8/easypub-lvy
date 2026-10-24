part of 'library_page.dart';

// R2-10：从 library_page.dart 拆出，行为不变。书架（封面格子）、列表行、表头、状态列与空书库引导。
extension _LibraryShelf on _LibraryPageState {
  /// 拖动已勾选的书（V84，LIB-121）：按在已勾选的书上拖动时带上全部勾选的书。
  Widget bookDrag(BookSummary b, bool checked, Widget child) {
    if (collectionService == null) return child;
    final d = context.desk;
    final ids = checked ? selected.toList() : [b.id];
    return Draggable<LibraryBookDrag>(
      data: LibraryBookDrag(ids),
      maxSimultaneousDrags: checked ? 1 : 0,
      onDragStarted: () => update(() => bookDragging = true),
      onDragEnd: (_) => update(() => bookDragging = false),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: d.surface,
        elevation: 0,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: d.lineStrong),
            boxShadow: d.shadow2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bookmark_add_outlined, size: 16, color: d.ink2),
              const SizedBox(width: 8),
              Text(
                ids.length == 1 ? b.title : '${ids.length} 本书',
                style: ui(12.5, w: 600, c: d.ink),
              ),
              const SizedBox(width: 8),
              Text(
                folderMode ? '拖到收藏夹上' : '拖到左侧收藏夹',
                style: ui(11.5, c: d.ink3),
              ),
            ],
          ),
        ),
      ),
      child: child,
    );
  }

  /// 浅色表头：与行内各列对齐。
  Widget columnHeader() {
    final d = context.desk;
    final style = ui(11.5, w: 600, c: d.ink3);
    return Padding(
      key: const ValueKey('library-column-header'),
      padding: const EdgeInsets.fromLTRB(16 + 10, 2, 14 + 10, 4),
      child: LayoutBuilder(
        builder: (context, bounds) => Row(
          children: [
            const SizedBox(width: _checkWidth + 6),
            const SizedBox(width: 48 + 12),
            Expanded(child: Text('书名', style: style)),
            if (_wide(bounds.maxWidth)) ...[
              SizedBox(
                width: _formatWidth,
                child: Text('格式', style: style),
              ),
              SizedBox(
                width: _sizeWidth,
                child: Text('大小', style: style),
              ),
            ],
            SizedBox(
              width: _statusWidth,
              child: Text('状态', style: style),
            ),
            const SizedBox(width: _menuWidth),
          ],
        ),
      ),
    );
  }

  /// 状态列（LIB-099）：需要处理时小圆点 + 短词，处理完浅灰；数量取自检查报告。
  Widget statusCell(BookSummary b) {
    final d = context.desk;
    // 只算章节问题（LIB-106）；清理建议与书籍信息写在悬停提示里。转换页共用同一说法。
    final label = bookStatusLabel(b);
    final text = label.text;
    final Color? dot = label.attention ? d.warn : null;
    final color = label.attention
        ? d.ink
        : label.active
        ? d.ink2
        : d.ink3;
    return Tooltip(
      message: bookStatusTip(b),
      child: Row(
        key: ValueKey('library-status-${b.id}'),
        children: [
          if (dot != null) ...[Dot(dot, size: 6), const SizedBox(width: 6)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(12, c: color),
            ),
          ),
        ],
      ),
    );
  }

  /// 书架视图（LIB-101，默认）：按宽度排成固定列，几何信息同时用于拖动框选。
  Widget shelf(List<BookSummary> visible, BookSummary current) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1);
      const pad = 20.0, gap = 18.0, minTile = 150.0, inner = 6.0;
      final columns = ((box.maxWidth - 2 * pad + gap) / (minTile + gap))
          .floor()
          .clamp(1, 12);
      final tile = (box.maxWidth - 2 * pad - gap * (columns - 1)) / columns;
      final tileHeight = (tile - 2 * inner) * 4 / 3 + 2 * inner + 60 * scale;
      _columns = columns;
      _extent = tileHeight + gap;
      Rect rectOf(int i) => Rect.fromLTWH(
        pad + (i % columns) * (tile + gap),
        8 + (i ~/ columns) * (tileHeight + gap),
        tile,
        tileHeight,
      );
      return DragSelectRegion(
        key: const ValueKey('library-drag-select'),
        scroll: scroll,
        itemExtent: _extent,
        ids: [for (final b in visible) b.id],
        isChecked: selected.contains,
        hitTiles: (rect) => {
          for (var i = 0; i < visible.length; i++)
            if (rectOf(i).overlaps(rect)) i,
        },
        passThrough: collectionService == null
            ? null
            : (at, _) {
                for (var i = 0; i < visible.length; i++) {
                  if (rectOf(i).contains(at)) {
                    return selected.contains(visible[i].id);
                  }
                }
                return false;
              },
        apply: (check, uncheck) {
          if (check.isNotEmpty) checkMany(check, true);
          if (uncheck.isNotEmpty) checkMany(uncheck, false);
        },
        onSelectAll: () => checkMany(visible.map((b) => b.id), true),
        onClear: () => checkMany(selected, false),
        child: GridView.builder(
          key: const ValueKey('library-shelf'),
          controller: scroll,
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
            mainAxisExtent: tileHeight,
          ),
          itemCount: visible.length,
          itemBuilder: (context, i) =>
              bookTile(visible, visible[i], current, tile - 2 * inner),
        ),
      );
    },
  );

  /// 书架上的一本书：大封面，书名与作者 · 章数；待处理数量为封面角标，
  /// 勾选框在悬停、已勾选或正在多选时浮在封面左上角。
  Widget bookTile(
    List<BookSummary> visible,
    BookSummary b,
    BookSummary current,
    double coverWidth,
  ) {
    final d = context.desk;
    final on = b.id == current.id;
    final checked = selected.contains(b.id);
    final pending = chapterIssueCount(b);
    return Material(
      key: ValueKey('library-row-${b.id}'),
      type: MaterialType.transparency,
      child: _Hover(
        builder: (hovering) => bookDrag(
          b,
          checked,
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              final keys = HardwareKeyboard.instance;
              if (keys.isControlPressed) {
                checkRow(visible, b.id, !checked);
              } else if (keys.isShiftPressed && rangeAnchor != null) {
                checkRow(visible, b.id, true);
              } else {
                widget.library.selectBook(b.id);
              }
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: checked
                    ? d.accentSoft
                    : on
                    ? d.surface
                    : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          boxShadow: hovering || on ? d.shadow2 : d.shadow1,
                          border: on
                              ? Border.all(color: d.accent, width: 2)
                              : null,
                        ),
                        child: LibraryCover(b, width: coverWidth),
                      ),
                      if (bookNeedsAttention(b))
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Tooltip(
                            message: [
                              b.status,
                              if (b.pending != null && b.pending!.total > 0)
                                b.pending!.breakdown,
                            ].join('\n'),
                            child: Container(
                              key: ValueKey('library-badge-${b.id}'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: d.surface,
                                borderRadius: BorderRadius.circular(99),
                                border: Border.all(color: d.line),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Dot(d.warn, size: 6),
                                  // R2-08：数字后写“待核”，不用悬停也知道是什么。
                                  if (pending > 0) ...[
                                    const SizedBox(width: 4),
                                    Text('$pending', style: mono(11, c: d.ink)),
                                    const SizedBox(width: 2),
                                    Text('待核', style: ui(10.5, c: d.ink2)),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (hovering || checked || selected.isNotEmpty)
                        Positioned(
                          top: 2,
                          left: 2,
                          child: Container(
                            decoration: BoxDecoration(
                              color: d.surface.withValues(alpha: .92),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Checkbox(
                              key: ValueKey('library-check-${b.id}'),
                              value: checked,
                              visualDensity: VisualDensity.compact,
                              onChanged: (v) =>
                                  checkRow(visible, b.id, v == true),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: b.title,
                          child: Text(
                            b.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(13, w: on ? 650 : 600, c: d.ink),
                          ),
                        ),
                      ),
                      // “…”与列表行同一菜单；悬停、选中或勾选时显示。
                      SizedBox(
                        width: 30,
                        height: 28,
                        child: AnimatedOpacity(
                          duration: DeskMotion.of(context, DeskMotion.fast),
                          curve: DeskMotion.easeOut,
                          opacity: hovering || on || checked ? 1 : 0,
                          child: FittedBox(child: bookMenu(b)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // R2-08：卡片第二行写作者、格式与章数，不用看右栏就知道是什么书。
                  BookStructureCounts(
                    library: widget.library,
                    book: b,
                    compact: true,
                    prefix:
                        '${[if (b.author.isNotEmpty) b.author, b.format].join(' · ')} · ',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget bookRow(
    List<BookSummary> visible,
    BookSummary b,
    BookSummary current,
  ) {
    final d = context.desk;
    final on = b.id == current.id;
    final checked = selected.contains(b.id);
    return Material(
      key: ValueKey('library-row-${b.id}'),
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: _Hover(
          builder: (hovering) => InkWell(
            borderRadius: BorderRadius.circular(8),
            // Ctrl+点击：单独加选或取消；Shift+点击：从上次勾选处连续勾选（LIB-096）。
            onTap: () {
              final keys = HardwareKeyboard.instance;
              if (keys.isControlPressed) {
                checkRow(visible, b.id, !checked);
              } else if (keys.isShiftPressed && rangeAnchor != null) {
                checkRow(visible, b.id, true);
              } else {
                widget.library.selectBook(b.id);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: on
                    ? d.surface
                    : checked
                    ? d.accentSoft
                    : null,
                borderRadius: BorderRadius.circular(8),
                boxShadow: on ? d.shadow1 : null,
                border: Border(
                  left: BorderSide(
                    width: 2.5,
                    color: on ? d.accent : Colors.transparent,
                  ),
                ),
              ),
              child: LayoutBuilder(
                builder: (context, bounds) => Row(
                  children: [
                    SizedBox(
                      width: _checkWidth,
                      child: Checkbox(
                        value: checked,
                        key: ValueKey('library-check-${b.id}'),
                        onChanged: (v) => checkRow(visible, b.id, v == true),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: bookDrag(
                        b,
                        checked,
                        Row(
                          children: [
                            LibraryCover(b, width: 48),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Tooltip(
                                          message: b.title,
                                          child: Text(
                                            b.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: ui(13.5, w: 600, c: d.ink),
                                          ),
                                        ),
                                      ),
                                      if (on) ...[
                                        const SizedBox(width: 6),
                                        const DeskTag('当前', Tone.accent),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  BookStructureCounts(
                                    library: widget.library,
                                    book: b,
                                    compact: true,
                                    prefix: b.author.isEmpty
                                        ? ''
                                        : '${b.author} · ',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 宽行显示格式与原文件大小列（大小来自原文件属性，读不到显示“—”）。
                    if (_wide(bounds.maxWidth)) ...[
                      SizedBox(
                        width: _formatWidth,
                        child: Text(b.format, style: ui(12, c: d.ink2)),
                      ),
                      SizedBox(
                        width: _sizeWidth,
                        child: Text(
                          _formatBytes(b.bytes),
                          style: mono(11, c: d.ink3),
                        ),
                      ),
                    ],
                    SizedBox(width: _statusWidth, child: statusCell(b)),
                    // “…”只在悬停、选中或勾选时出现；隐藏时仍可用键盘与读屏访问。
                    SizedBox(
                      width: _menuWidth,
                      child: AnimatedOpacity(
                        duration: DeskMotion.of(context, DeskMotion.fast),
                        curve: DeskMotion.easeOut,
                        opacity: hovering || on || checked ? 1 : 0,
                        child: bookMenu(b),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget emptyLibrary(bool importing) {
    final d = context.desk;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_stories_outlined, size: 48, color: d.ink3),
          const SizedBox(height: 18),
          Text('把第一本书放进书库', style: serif(22, w: 650, c: d.ink)),
          const SizedBox(height: 8),
          Text('选择 TXT、EPUB，或导入一个文件夹。原文件始终保留。', style: ui(13, c: d.ink2)),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            children: [
              DeskButton(
                '选择文件',
                primary: true,
                onPressed: importing || picking ? null : importBooks,
              ),
              DeskButton(
                '导入文件夹',
                onPressed: importing || picking ? null : () => importFolder(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
