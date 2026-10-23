// 文件夹与收藏（D4-D，V8 按设计重写视图）：扫描、勾选、导入与收藏逻辑沿用原实现。
// V84（FOLD-083–087）：全选 / 取消全选 / 反选按钮、拖动连选与框选、点列名排序与类型筛选、
// 修改时间列；可选“导入后加入收藏夹”。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../application/folder_auto_import.dart';
import '../../application/library_service.dart';
import '../../application/book_collection_service.dart';
import '../collections/collection_flow.dart';
import '../controls/drag_select.dart';
import '../dialogs.dart';
import '../page_parts.dart';
import '../controls/controls.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'folder_controller.dart';
import 'favorites_dialog.dart';
import 'folder_book_tools.dart';
import 'folder_scan_failures.dart';

class FoldersPage extends StatefulWidget {
  const FoldersPage({
    super.key,
    required this.library,
    required this.picker,
    this.initialFolder,
  });
  final String? initialFolder;
  final LibraryService library;
  final BookFilePicker picker;
  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  late final FolderController model = FolderController(widget.library);
  String favoriteError = '';
  bool favoriteBusy = false;
  final range = RangeSelection();
  final view = FolderListView();
  final scroll = ScrollController();
  String? collection;
  BookCollectionService? get collections =>
      widget.library is BookCollectionService
      ? widget.library as BookCollectionService
      : null;

  /// 导入所选，成功后按需加入收藏夹（V84，FOLD-087）。
  Future<void> importSelected() async {
    await model.importSelected();
    final target = collection, service = collections;
    if (target == null || service == null || !mounted) return;
    final ids = [
      for (final r in model.outcomes)
        if (r.succeeded) ?service.bookIdForPath(r.path),
    ];
    if (ids.isNotEmpty) await joinCollection(context, service, target, ids);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      loadFavorites();
      if (widget.initialFolder != null) model.scan(widget.initialFolder!);
    });
  }

  Future<void> loadFavorites() async {
    final ok = await widget.library.loadFavorites();
    if (mounted && !ok) {
      setState(() => favoriteError = '收藏夹列表没有读出来：设置文件可能损坏或被占用。重新打开这一页再试。');
    }
  }

  @override
  void didUpdateWidget(covariant FoldersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialFolder != null &&
        widget.initialFolder != oldWidget.initialFolder) {
      model.scan(widget.initialFolder!);
    }
  }

  @override
  void dispose() {
    model.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> browse({bool favorite = false}) async {
    final path = await widget.picker.chooseFolder();
    if (path == null || !mounted) return;
    if (favorite) await setFavorite(path, true);
    if (mounted) await model.scan(path);
  }

  Future<void> setFavorite(String path, bool value) async {
    if (favoriteBusy) return;
    setState(() => favoriteBusy = true);
    try {
      final ok = await widget.library.setFavorite(path, value);
      if (mounted) {
        setState(() => favoriteError = ok ? '' : '收藏保存失败，原设置保留。请检查目录和权限。');
      }
    } catch (error) {
      if (mounted) setState(() => favoriteError = '收藏保存失败：$error');
    } finally {
      if (mounted) setState(() => favoriteBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([model, widget.library.favoriteNames]),
    builder: (context, _) => DeskPageFrame(
      header: DeskPageHeader(
        title: '文件夹与收藏',
        subtitle: '扫描只找书，导入要再确认；收藏只是快捷入口',
        actions: [
          DeskButton(
            '元数据映射',
            icon: Icons.account_tree_outlined,
            quiet: true,
            onPressed: model.busy ? null : () => context.go('/folders/mapping'),
          ),
          DeskButton(
            '返回书库',
            icon: Icons.arrow_back_rounded,
            quiet: true,
            onPressed: () => context.go('/'),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
        child: DeskSplitView(
          leadingLabel: '收藏文件夹',
          trailingLabel: '导入文件夹',
          leadingWidth: 262,
          initialIndex: 1,
          leading: favoritesColumn(context),
          trailing: importColumn(context),
        ),
      ),
    ),
  );

  Widget favoritesColumn(BuildContext context) {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 34,
          child: Row(
            children: [
              const SizedBox(width: 4),
              Text('收藏文件夹', style: ui(13, w: 650, c: d.ink)),
              const Spacer(),
              IconButton(
                tooltip: '管理收藏',
                icon: Icon(Icons.star_border_rounded, size: 18, color: d.ink2),
                visualDensity: VisualDensity.compact,
                onPressed: model.busy
                    ? null
                    : () async {
                        final path = await showDialog<String>(
                          context: context,
                          builder: (_) => FavoritesDialog(
                            library: widget.library,
                            picker: widget.picker,
                          ),
                        );
                        if (path != null && mounted) await model.scan(path);
                      },
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ValueListenableBuilder<List<String>>(
            valueListenable: widget.library.favoriteFolders,
            builder: (_, folders, _) => folders.isEmpty
                ? Center(
                    child: Text('还没有收藏文件夹', style: ui(12.5, c: d.ink3)),
                  )
                : ListView.builder(
                    itemCount: folders.length,
                    itemBuilder: (_, i) => favoriteRow(context, folders[i]),
                  ),
          ),
        ),
        // 自动入库的最近一次结果（V26）：只在有内容时占一行。
        if (widget.library case final FolderAutoImportService auto)
          ValueListenableBuilder<AutoImportState>(
            valueListenable: auto.autoImportState,
            builder: (_, state, _) => state.message.isEmpty && !state.running
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Row(
                      children: [
                        Icon(Icons.sync_rounded, size: 14, color: d.ink3),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            state.message,
                            key: const ValueKey('auto-import-status'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: ui(11.5, c: d.ink3),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        if (favoriteError.isNotEmpty) ...[
          const SizedBox(height: 8),
          DeskNote(favoriteError, tone: Tone.pen),
        ],
        const SizedBox(height: 8),
        DeskButton(
          '添加收藏',
          icon: Icons.add_rounded,
          onPressed: favoriteBusy || model.busy
              ? null
              : () => browse(favorite: true),
        ),
      ],
    );
  }

  Widget favoriteRow(BuildContext context, String path) {
    final d = context.desk;
    final current = model.path == path;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: current ? d.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: model.importing ? null : () => model.scan(path),
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            padding: const EdgeInsets.only(left: 10, right: 2),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 17, color: d.ink2),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.library.favoriteName(path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ui(12.5, w: current ? 650 : 560, c: d.ink),
                      ),
                      Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(10.5, c: d.ink3),
                      ),
                    ],
                  ),
                ),
                // 自动入库开关（V26，FOLD-080）：只有图标，悬停说明。
                if (widget.library case final FolderAutoImportService auto)
                  ValueListenableBuilder<List<String>>(
                    valueListenable: auto.autoImportFolders,
                    builder: (_, folders, _) {
                      final on = folders.any(
                        (f) => f.toLowerCase() == path.toLowerCase(),
                      );
                      return IconButton(
                        key: ValueKey('favorite-auto-import-$path'),
                        tooltip: on
                            ? '自动入库：开\n这个文件夹里新出现的书会自动导入书库；点击关闭'
                            : '自动入库：关\n点击开启后，这个文件夹里新出现的书会自动导入书库',
                        isSelected: on,
                        icon: Icon(
                          on ? Icons.sync_rounded : Icons.sync_disabled_rounded,
                          size: 17,
                          color: on ? d.ink : d.ink3,
                        ),
                        visualDensity: VisualDensity.compact,
                        onPressed: favoriteBusy
                            ? null
                            : () => auto.setAutoImport(path, !on),
                      );
                    },
                  ),
                IconButton(
                  tooltip: '取消收藏',
                  icon: Icon(Icons.star_rounded, size: 17, color: d.ink2),
                  visualDensity: VisualDensity.compact,
                  onPressed: favoriteBusy
                      ? null
                      : () => setFavorite(path, false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget importColumn(BuildContext context) {
    final d = context.desk;
    final books = model.listing?.books ?? const <FolderBook>[];
    final shown = view.apply(books);
    final found = books.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 560),
              child: Container(
                height: 36,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: d.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: d.lineStrong),
                ),
                child: Tooltip(
                  message: '文件夹位置',
                  child: Text(
                    model.path.isEmpty ? '请选择文件夹' : model.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ui(12.5, c: model.path.isEmpty ? d.ink3 : d.ink),
                  ),
                ),
              ),
            ),
            DeskButton(
              '浏览…',
              icon: Icons.folder_open_outlined,
              onPressed: model.busy ? null : browse,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: model.recursive,
                  onChanged: model.busy
                      ? null
                      : (v) {
                          if (model.path.isNotEmpty) {
                            model.scan(model.path, includeSubfolders: v);
                          } else {
                            setState(() => model.recursive = v);
                          }
                        },
                ),
                const SizedBox(width: 4),
                Text('包含子文件夹', style: ui(12.5, c: d.ink)),
              ],
            ),
            DeskButton(
              '收藏此文件夹',
              icon: Icons.star_border_rounded,
              quiet: true,
              onPressed: model.path.isEmpty || favoriteBusy
                  ? null
                  : () => setFavorite(model.path, true),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (model.scanning)
          DeskInfoBar(
            '正在扫描 · 已找到 $found 本',
            action: model.listing?.failures.isNotEmpty == true
                ? FolderScanFailures(paths: model.listing!.failures)
                : null,
          )
        else if (model.listing?.resume != null)
          DeskInfoBar(
            '扫描已停止 · 已找到 $found 本',
            tone: Tone.warn,
            action: DeskButton(
              '继续扫描 / 重试失败项',
              quiet: true,
              onPressed: model.busy ? null : model.resumeScan,
            ),
          )
        else if (model.listing?.failures.isNotEmpty == true)
          DeskInfoBar(
            '扫描完成 · 找到 $found 本 · 有路径读取失败',
            tone: Tone.warn,
            action: FolderScanFailures(paths: model.listing!.failures),
          )
        else if (model.path.isNotEmpty)
          DeskInfoBar('找到 $found 本书稿'),
        if (model.scanning) ...[
          const SizedBox(height: 4),
          const LinearProgressIndicator(minHeight: 2),
        ],
        const SizedBox(height: 8),
        if (books.isNotEmpty) ...[
          FolderListToolbar(
            books: books,
            shown: shown,
            selected: model.selected,
            view: view,
            enabled: !model.busy,
            onViewChanged: () => setState(range.reset),
            onSet: model.setMany,
          ),
          const SizedBox(height: 6),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SelectAllHeader(
            selected: model.selected.length,
            total: books.where((b) => !b.alreadyImported).length,
            padding: EdgeInsets.zero,
            onChanged: model.busy || books.isEmpty
                ? null
                : (v) => model.setMany(shown.map((b) => b.path), v),
            body: Row(
              children: [
                const SizedBox(width: 4),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FolderSortHeader(
                      '选择 / 文件名',
                      FolderSort.name,
                      view: view,
                      onViewChanged: () => setState(range.reset),
                    ),
                  ),
                ),
                for (final (label, sort, width) in const [
                  ('格式', FolderSort.type, 64.0),
                  ('大小', FolderSort.size, 84.0),
                  ('修改时间', FolderSort.modified, 128.0),
                ])
                  SizedBox(
                    width: width,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FolderSortHeader(
                        label,
                        sort,
                        view: view,
                        onViewChanged: () => setState(range.reset),
                      ),
                    ),
                  ),
                const SizedBox(width: 96, child: DeskColumnLabel('导入状态')),
              ],
            ),
          ),
        ),
        Expanded(
          child: SelectionKeys(
            hasSelection: model.selected.isNotEmpty,
            onSelectAll: () => model.setMany(shown.map((b) => b.path), true),
            onClear: () => model.setMany(shown.map((b) => b.path), false),
            child: DeskCard(
              child: books.isEmpty && !model.scanning
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.folder_open_outlined,
                            size: 34,
                            color: d.lineStrong,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            model.path.isEmpty
                                ? '选择文件夹，或点选左侧收藏'
                                : '此文件夹没有可导入的 TXT 或 EPUB',
                            style: ui(13, c: d.ink2),
                          ),
                          const SizedBox(height: 12),
                          DeskButton(
                            '选择文件夹',
                            icon: Icons.folder_open_outlined,
                            onPressed: model.busy ? null : browse,
                          ),
                        ],
                      ),
                    )
                  : DragSelectRegion(
                      key: const ValueKey('folder-drag-select'),
                      scroll: scroll,
                      itemExtent: 44,
                      checkColumnWidth: 52,
                      ids: [for (final b in shown) b.path],
                      isChecked: model.selected.contains,
                      apply: (check, uncheck) {
                        if (check.isNotEmpty) model.setMany(check, true);
                        if (uncheck.isNotEmpty) model.setMany(uncheck, false);
                      },
                      child: ListView.builder(
                        controller: scroll,
                        itemExtent: 44,
                        itemCount: shown.length,
                        itemBuilder: (_, i) => bookRow(context, shown, i),
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                model.message.isNotEmpty
                    ? model.message
                    : '已选 ${model.selected.length} 本 · 书库已有的保留现有草稿',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ui(12, c: d.ink3),
              ),
            ),
            if (model.busy) ...[
              DeskButton('取消操作', quiet: true, onPressed: model.cancel),
              const SizedBox(width: 6),
            ],
            if (collections != null &&
                collections!.collections.value.isNotEmpty) ...[
              Tooltip(
                message: '导入成功的书（以及书库已有的书）加入这个收藏夹',
                child: DeskFilter<String>(
                  key: const ValueKey('folder-import-collection'),
                  value: collection ?? '',
                  label: '加入收藏夹',
                  onChanged: model.busy
                      ? null
                      : (v) => setState(
                          () => collection = v == null || v.isEmpty ? null : v,
                        ),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('不加入收藏夹')),
                    for (final c in collections!.collections.value)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text('加入“${c.name}”'),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
            ],
            DeskButton(
              '导入所选 ${model.selected.length} 本',
              primary: true,
              icon: Icons.file_download_outlined,
              busy: model.importing,
              disabledReason: model.selected.isEmpty ? '先勾选要导入的书籍' : '等待当前操作完成',
              onPressed: model.canImport ? importSelected : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget bookRow(BuildContext context, List<FolderBook> books, int index) {
    final d = context.desk;
    final book = books[index];
    // Shift+点击：把上次点击到本行之间的书统一设成同一状态（G-067）。
    void toggle(bool value) => model.setMany([
      for (final i in range.span(index)) books[i].path,
    ], value);
    final result = model.outcomes.where((r) => r.path == book.path).firstOrNull;
    final (state, tone) = result != null
        ? result.succeeded
              ? result.skipped
                    ? ('已跳过', Tone.neutral)
                    : ('已导入', Tone.ok)
              : ('导入失败', Tone.pen)
        : book.alreadyImported
        ? ('书库已有', Tone.ok)
        : ('可以导入', Tone.neutral);
    final enabled = !model.busy && !book.alreadyImported;
    final checked = model.selected.contains(book.path);
    return InkWell(
      onTap: enabled ? () => toggle(!checked) : null,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: d.line)),
        ),
        child: Row(
          children: [
            Opacity(
              opacity: book.alreadyImported ? .4 : 1,
              child: Checkbox(
                value: checked,
                visualDensity: VisualDensity.compact,
                onChanged: enabled ? (v) => toggle(v ?? false) : null,
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                book.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ui(12.5, c: d.ink),
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(book.type, style: ui(12, c: d.ink2)),
            ),
            SizedBox(
              width: 84,
              child: Text(
                folderBookSize(book.bytes),
                style: mono(11, c: d.ink3),
              ),
            ),
            SizedBox(
              width: 128,
              child: Text(
                folderBookTime(book.modified),
                style: mono(11, c: d.ink3),
              ),
            ),
            SizedBox(
              width: 96,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: result?.message ?? '',
                  child: DeskTag(state, tone),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
