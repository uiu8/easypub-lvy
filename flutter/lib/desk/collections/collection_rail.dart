// 书库左栏（V84，LIB-118–125）：全部书稿 / 收藏夹 / 类别。点选只改书库显示范围；
// 收藏夹行接受从书架拖来的已勾选书，也接受从资源管理器拖入的文件（由书库页按位置判断）。
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import '../../application/book_collection_service.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../tokens.dart';
import 'collection_dialogs.dart';
import 'collection_flow.dart';

/// 书架上拖动的书（已勾选的一组）。
class LibraryBookDrag {
  const LibraryBookDrag(this.ids);
  final List<String> ids;
}

/// 书库显示范围：空串为全部；`c:<id>` 为收藏夹；`k:<类别>` 为类别（`k:` 为未分类）。
String collectionScope(String id) => 'c:$id';
String categoryScope(String category) => 'k:$category';

/// 按显示范围筛书。
bool inLibraryScope(
  BookSummary book,
  String scope,
  List<BookCollection> collections,
) {
  if (scope.startsWith('c:')) {
    final c = collections.where((c) => 'c:${c.id}' == scope).firstOrNull;
    return c?.books.contains(book.id) ?? true;
  }
  if (scope.startsWith('k:')) return book.category == scope.substring(2);
  return true;
}

/// 显示范围的名称（窄窗口下拉与标题用）。
String scopeLabel(String scope, List<BookCollection> collections) {
  if (scope.startsWith('c:')) {
    final c = collections.where((c) => 'c:${c.id}' == scope).firstOrNull;
    return c == null ? '全部书稿' : '收藏夹 · ${c.name}';
  }
  if (scope.startsWith('k:')) {
    return scope.length == 2 ? '未分类' : '类别 · ${scope.substring(2)}';
  }
  return '全部书稿';
}

/// 当前存在的类别及书数（按书数从多到少）；有书已分类时附“未分类”。
List<(String, int)> libraryCategories(List<BookSummary> books) {
  final counts = <String, int>{};
  for (final b in books) {
    counts[b.category] = (counts[b.category] ?? 0) + 1;
  }
  final named = [
    for (final e in counts.entries)
      if (e.key.isNotEmpty) (e.key, e.value),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  return [
    ...named,
    if (named.isNotEmpty && (counts[''] ?? 0) > 0) ('', counts['']!),
  ];
}

class CollectionRail extends StatelessWidget {
  const CollectionRail({
    super.key,
    required this.service,
    required this.books,
    required this.scope,
    required this.onScope,
    required this.rowKeys,
    this.fileHover,
    this.collapsed = false,
  });

  /// 收成图标条（V84b）：只有全部书稿、各收藏夹与新建；收藏夹仍可点选、可拖书进来。
  final bool collapsed;
  final BookCollectionService service;
  final List<BookSummary> books;
  final String scope;
  final ValueChanged<String> onScope;

  /// 每个收藏夹行的位置，书库页用它判断外部文件拖到了哪一行。
  final Map<String, GlobalKey> rowKeys;

  /// 外部文件正悬停在其上的收藏夹 id。
  final String? fileHover;

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final ids = {for (final b in books) b.id};
    return ValueListenableBuilder<List<BookCollection>>(
      valueListenable: service.collections,
      builder: (context, collections, _) {
        rowKeys.removeWhere((id, _) => !collections.any((c) => c.id == id));
        if (collapsed) return strip(context, collections, ids);
        final categories = libraryCategories(books);
        return SingleChildScrollView(
          key: const ValueKey('library-collection-rail'),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Row(
                key: const ValueKey('library-scope-all'),
                icon: Icons.auto_stories_outlined,
                label: '全部书稿',
                count: books.length,
                selected: scope.isEmpty,
                onTap: () => onScope(''),
              ),
              const SizedBox(height: 10),
              _Heading(
                '收藏夹',
                trailing: IconButton(
                  key: const ValueKey('library-collection-new'),
                  tooltip: '新建收藏夹',
                  visualDensity: VisualDensity.compact,
                  iconSize: 17,
                  icon: Icon(Icons.add_rounded, color: d.ink2),
                  onPressed: () async {
                    final created = await showCollectionEditor(
                      context,
                      service,
                    );
                    if (created != null) onScope(collectionScope(created.id));
                  },
                ),
              ),
              if (collections.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                  child: Text(
                    '点 + 新建。把勾选的书拖到收藏夹上即可加入；预设信息会在加入时自动补全。',
                    style: ui(11.5, c: d.ink3, h: 1.5),
                  ),
                ),
              for (final c in collections)
                _CollectionRow(
                  key: rowKeys.putIfAbsent(c.id, GlobalKey.new),
                  service: service,
                  collection: c,
                  count: c.books.where(ids.contains).length,
                  selected: scope == collectionScope(c.id),
                  fileHover: fileHover == c.id,
                  onTap: () => onScope(collectionScope(c.id)),
                  onDeleted: () {
                    if (scope == collectionScope(c.id)) onScope('');
                  },
                ),
              if (categories.isNotEmpty) ...[
                const SizedBox(height: 10),
                const _Heading('类别'),
                for (final (name, count) in categories)
                  _Row(
                    key: ValueKey('library-scope-category-$name'),
                    icon: name.isEmpty
                        ? Icons.label_off_outlined
                        : Icons.label_outline_rounded,
                    label: name.isEmpty ? '未分类' : name,
                    count: count,
                    selected: scope == categoryScope(name),
                    onTap: () => onScope(categoryScope(name)),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

extension on CollectionRail {
  Widget strip(
    BuildContext context,
    List<BookCollection> collections,
    Set<String> ids,
  ) {
    final d = context.desk;
    return SingleChildScrollView(
      key: const ValueKey('library-collection-strip'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          _StripButton(
            key: const ValueKey('library-scope-all'),
            tooltip: '全部书稿（${books.length}）',
            selected: scope.isEmpty,
            onTap: () => onScope(''),
            child: Icon(Icons.auto_stories_outlined, size: 18, color: d.ink2),
          ),
          Container(
            width: 20,
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: d.line,
          ),
          for (final c in collections)
            DragTarget<LibraryBookDrag>(
              key: rowKeys.putIfAbsent(c.id, GlobalKey.new),
              onAcceptWithDetails: (details) =>
                  joinCollection(context, service, c.id, details.data.ids),
              builder: (context, candidates, _) => _StripButton(
                key: ValueKey('library-collection-${c.id}'),
                tooltip:
                    '收藏夹 · ${c.name}（${c.books.where(ids.contains).length}）\n把勾选的书拖到这里加入',
                selected: scope == collectionScope(c.id),
                highlight: candidates.isNotEmpty || fileHover == c.id,
                onTap: () => onScope(collectionScope(c.id)),
                child: Text(
                  c.name.characters.first,
                  style: ui(13, w: 650, c: d.ink),
                ),
              ),
            ),
          _StripButton(
            key: const ValueKey('library-collection-new'),
            tooltip: '新建收藏夹',
            selected: false,
            onTap: () async {
              final created = await showCollectionEditor(context, service);
              if (created != null) onScope(collectionScope(created.id));
            },
            child: Icon(Icons.add_rounded, size: 18, color: d.ink2),
          ),
        ],
      ),
    );
  }
}

class _StripButton extends StatelessWidget {
  const _StripButton({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    required this.child,
    this.highlight = false,
  });
  final String tooltip;
  final bool selected, highlight;
  final VoidCallback onTap;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: highlight
              ? d.accentSoft
              : selected
              ? d.surface
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
            side: highlight || selected
                ? BorderSide(color: highlight ? d.accent : d.line)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(width: 34, height: 34, child: Center(child: child)),
          ),
        ),
      ),
    );
  }
}

/// 可伸缩的左栏（V84b）：拖右边缘调宽度（150–320），拖到 110 以下收成 48 宽的图标条，
/// 从图标条往右拖即展开；双击边缘收起或展开。拖动中只改本栏宽度，松手后交给书库保存。
class ResizableRail extends StatefulWidget {
  const ResizableRail({
    super.key,
    required this.width,
    required this.collapsed,
    required this.maxWidth,
    required this.onCommit,
    required this.builder,
  });
  final double width, maxWidth;
  final bool collapsed;
  final void Function(double width, bool collapsed) onCommit;
  final Widget Function(bool collapsed) builder;

  static const stripWidth = 48.0, minWidth = 150.0, collapseBelow = 110.0;
  static const maxRailWidth = 320.0, handleWidth = 7.0;

  @override
  State<ResizableRail> createState() => _ResizableRailState();
}

class _ResizableRailState extends State<ResizableRail> {
  double? live;
  bool? liveCollapsed;
  double startWidth = 0, origin = 0;
  bool hovering = false;

  double get maxWidth =>
      widget.maxWidth.clamp(ResizableRail.minWidth, ResizableRail.maxRailWidth);
  bool get collapsed => liveCollapsed ?? widget.collapsed;
  double get width => collapsed
      ? ResizableRail.stripWidth
      : (live ?? widget.width).clamp(ResizableRail.minWidth, maxWidth);

  void commit() {
    // 拖到收起时保留拖之前的宽度，展开时回到它。
    final next = (collapsed ? widget.width : live ?? widget.width, collapsed);
    setState(() {
      live = null;
      liveCollapsed = null;
    });
    widget.onCommit(next.$1, next.$2);
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: width, child: widget.builder(collapsed)),
        Tooltip(
          message: '拖动调整宽度，拖到最窄收成图标条；双击收起或展开',
          waitDuration: const Duration(milliseconds: 800),
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            onEnter: (_) => setState(() => hovering = true),
            onExit: (_) => setState(() => hovering = false),
            // 按下时就记下起点与起始宽度：识别为拖动要先越过阈值，从那时算会少走一截。
            child: Listener(
              onPointerDown: (e) {
                startWidth = width;
                origin = e.position.dx;
              },
              child: GestureDetector(
                key: const ValueKey('library-rail-handle'),
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onHorizontalDragUpdate: (e) {
                  final raw = startWidth + e.globalPosition.dx - origin;
                  setState(() {
                    liveCollapsed = raw < ResizableRail.collapseBelow;
                    if (!liveCollapsed!) {
                      live = raw.clamp(ResizableRail.minWidth, maxWidth);
                    }
                  });
                },
                onHorizontalDragEnd: (_) => commit(),
                onHorizontalDragCancel: commit,
                onDoubleTap: () => widget.onCommit(widget.width, !collapsed),
                child: SizedBox(
                  width: ResizableRail.handleWidth,
                  child: Center(
                    child: Container(
                      width: hovering ? 2 : 1,
                      color: hovering ? d.lineStrong : d.line,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: ui(11.5, w: 650, c: d.ink3)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.highlight = false,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final int count;
  final bool selected, highlight;
  final VoidCallback onTap;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: highlight
            ? d.accentSoft
            : selected
            ? d.surface
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: highlight
              ? BorderSide(color: d.accent, width: 1.4)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 34,
            padding: const EdgeInsets.only(left: 8, right: 2),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  width: 2.5,
                  color: selected ? d.accent : Colors.transparent,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: selected ? d.ink : d.ink2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12.5, w: selected ? 650 : 520, c: d.ink),
                  ),
                ),
                Text('$count', style: mono(11, c: d.ink3)),
                if (trailing != null) trailing! else const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    super.key,
    required this.service,
    required this.collection,
    required this.count,
    required this.selected,
    required this.fileHover,
    required this.onTap,
    required this.onDeleted,
  });
  final BookCollectionService service;
  final BookCollection collection;
  final int count;
  final bool selected, fileHover;
  final VoidCallback onTap, onDeleted;

  Future<void> delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => DeskAlert(
        title: Text('删除收藏夹“${collection.name}”？'),
        content: const Text('只删除这个分组和它的预设信息；书仍在书库，书籍信息不变。'),
        actions: [
          DeskButton(
            '取消',
            quiet: true,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          DeskButton(
            '删除收藏夹',
            key: const ValueKey('collection-delete-confirm'),
            dangerous: true,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );
    if (ok != true) return;
    service.deleteCollection(collection.id);
    onDeleted();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DragTarget<LibraryBookDrag>(
      onAcceptWithDetails: (details) =>
          joinCollection(context, service, collection.id, details.data.ids),
      builder: (context, candidates, _) => Tooltip(
        message: collection.hasTemplate
            ? '预设：${[for (final e in collection.template.entries)
                    if (e.value['op'] != 'keep') '${collectionTemplateFields[e.key]}${e.value['op'] == 'clear' ? '清空' : '=${e.value['value']}'}'].join('，')}'
                  '${collection.autoApply ? '\n加入后直接套用' : '\n加入时先预览'}'
            : '把勾选的书拖到这里加入',
        waitDuration: const Duration(milliseconds: 600),
        child: _Row(
          key: ValueKey('library-collection-${collection.id}'),
          icon: collection.hasTemplate
              ? Icons.bookmarks_outlined
              : Icons.bookmark_border_rounded,
          label: collection.name,
          count: count,
          selected: selected,
          highlight: candidates.isNotEmpty || fileHover,
          onTap: onTap,
          trailing: DeskCommandMenu<String>(
            tooltip: '收藏夹操作：${collection.name}',
            icon: Icon(Icons.more_horiz, size: 17, color: d.ink3),
            onSelected: (action) async {
              switch (action) {
                case 'edit':
                  await showCollectionEditor(
                    context,
                    service,
                    existing: collection,
                  );
                case 'apply':
                  final books = collection.books;
                  await applyCollectionTemplate(
                    context,
                    service,
                    collection,
                    books,
                    auto: false,
                  );
                case 'delete':
                  await delete(context);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                height: 36,
                value: 'edit',
                child: Text('重命名与预设信息…'),
              ),
              PopupMenuItem(
                height: 36,
                value: 'apply',
                enabled: collection.hasTemplate && count > 0,
                child: const Text('按预设信息更新全部成员…'),
              ),
              const PopupMenuItem(
                height: 36,
                value: 'delete',
                child: Text('删除收藏夹'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选择一个收藏夹（或新建）；返回收藏夹 id。
Future<String?> pickCollection(
  BuildContext context,
  BookCollectionService service, {
  required int count,
}) => showDialog<String>(
  context: context,
  builder: (dialogContext) {
    final d = dialogContext.desk;
    final collections = service.collections.value;
    return DeskDialog(
      title: '加入收藏夹',
      subtitle: '把所选 $count 本书加入一个收藏夹；书已在其中的不重复加入。',
      closeTooltip: '取消',
      width: 420,
      actions: [
        DeskButton(
          '新建收藏夹…',
          key: const ValueKey('collection-pick-new'),
          icon: Icons.add_rounded,
          quiet: true,
          onPressed: () async {
            final created = await showCollectionEditor(dialogContext, service);
            if (created != null && dialogContext.mounted) {
              Navigator.pop(dialogContext, created.id);
            }
          },
        ),
      ],
      child: collections.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text('还没有收藏夹，先新建一个。', style: ui(12.5, c: d.ink3)),
            )
          : DeskListBox(
              child: Column(
                children: [
                  for (final c in collections)
                    InkWell(
                      key: ValueKey('collection-pick-${c.id}'),
                      onTap: () => Navigator.pop(dialogContext, c.id),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: d.line)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              c.hasTemplate
                                  ? Icons.bookmarks_outlined
                                  : Icons.bookmark_border_rounded,
                              size: 16,
                              color: d.ink2,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(c.name, style: ui(13, c: d.ink)),
                            ),
                            if (c.hasTemplate)
                              Text(
                                c.autoApply ? '加入后套用预设' : '加入时预览预设',
                                style: ui(11.5, c: d.ink3),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  },
);
