// 选择输出位置（D4-F，V8 按设计重写视图）：收藏、统计、重命名、取消收藏与选择逻辑沿用原实现。
import '../dialogs.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../../application/folder_count_service.dart';

import 'package:flutter/material.dart';

import '../../application/library_service.dart';
import '../controls/controls.dart';

/// Favorites are persisted immediately; choosing an output path requires confirmation.
class OutputFolderDialog extends StatefulWidget {
  const OutputFolderDialog({
    super.key,
    required this.library,
    required this.picker,
    required this.initialPath,
  });
  final LibraryService library;
  final BookFilePicker picker;
  final String initialPath;
  @override
  State<OutputFolderDialog> createState() => _OutputFolderDialogState();
}

class _OutputFolderDialogState extends State<OutputFolderDialog> {
  late String selected = widget.initialPath;
  final search = TextEditingController();
  late final visited = <String>{if (selected.isNotEmpty) selected};
  String query = '', error = '';
  bool busy = false;
  final counts = <String, Future<FolderCount>>{};
  @override
  void initState() {
    super.initState();
    widget.library.favoriteFolders.addListener(refresh);
    widget.library.favoriteNames.addListener(refresh);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      run(() async {
        if (!await widget.library.loadFavorites()) throw StateError('读取收藏失败');
      });
    });
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.library.favoriteFolders.removeListener(refresh);
    widget.library.favoriteNames.removeListener(refresh);
    search.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => error = '操作未完成，请检查文件夹或稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> browse(bool favorite) => run(() async {
    final path = await widget.picker.chooseFolder();
    if (path == null || !mounted) return;
    if (favorite && !await widget.library.setFavorite(path, true)) {
      throw StateError('收藏失败');
    }
    if (mounted) {
      search.clear();
      setState(() {
        selected = path;
        visited.add(path);
        query = '';
      });
    }
  });
  Future<void> rename() async {
    final path = selected;
    var editedName = widget.library.favoriteName(path);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => DeskAlert(
        title: const Text('重命名收藏'),
        content: TextFormField(
          initialValue: editedName,
          onChanged: (value) => editedName = value,
          autofocus: true,
          decoration: const InputDecoration(labelText: '收藏名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (editedName.trim().isNotEmpty) {
                Navigator.pop(context, editedName.trim());
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && mounted) {
      await run(() async {
        if (!await widget.library.renameFavorite(path, name)) {
          throw StateError('重命名失败');
        }
      });
    }
  }

  Widget countBadge(String path) => FutureBuilder<FolderCount>(
    future: counts.putIfAbsent(
      path,
      () => (widget.library as FolderCountService).countFolder(
        path,
        cancelled: () => !mounted,
      ),
    ),
    builder: (context, snapshot) {
      final result = snapshot.data;
      final label = snapshot.hasError
          ? '未统计'
          : result == null
          ? '统计中'
          : result.complete
          ? '${result.count} 本'
          : result.count > 0
          ? '≥${result.count} 本'
          : '未统计';
      return Tooltip(
        message:
            result?.detail ?? (snapshot.hasError ? '文件夹统计失败' : '正在统计本层电子书文件'),
        child: DeskTag(label, Tone.neutral),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    final favorites = widget.library.favoriteFolders.value;
    final paths = {...favorites, ...visited}
        .where(
          (path) => '${widget.library.favoriteName(path)} $path'
              .toLowerCase()
              .contains(query.trim().toLowerCase()),
        )
        .toList();
    final isFavorite = favorites.contains(selected);
    return DeskDialog(
      title: '选择输出位置',
      subtitle: '从收藏文件夹中选择，或浏览其他文件夹',
      closeTooltip: '关闭',
      width: 680,
      height: 520,
      busy: busy,
      footerLeft: Text(
        error.isEmpty ? '取消收藏只移除快捷入口，不删除磁盘中的文件。' : error,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: ui(12, c: error.isEmpty ? d.ink3 : d.pen),
      ),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        DeskButton(
          '使用此文件夹',
          primary: true,
          onPressed: busy || selected.isEmpty
              ? null
              : () => Navigator.pop(context, selected),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  style: ui(13, c: d.ink),
                  onChanged: (value) => setState(() => query = value),
                  decoration: const InputDecoration(
                    hintText: '搜索收藏名称或路径',
                    prefixIconConstraints: BoxConstraints(minWidth: 36),
                    prefixIcon: Icon(Icons.search_rounded, size: 16),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DeskButton(
                '添加收藏',
                icon: Icons.add_rounded,
                onPressed: busy ? null : () => browse(true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: d.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: d.line),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: paths.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的收藏，可浏览其他文件夹。',
                          style: ui(12.5, c: d.ink3),
                        ),
                      )
                    : ListView.builder(
                        itemCount: paths.length,
                        itemBuilder: (context, index) =>
                            folderRow(context, paths[index]),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              DeskButton(
                '浏览其他文件夹',
                icon: Icons.folder_open_outlined,
                onPressed: busy ? null : () => browse(false),
              ),
              DeskButton(
                '重命名',
                quiet: true,
                onPressed: busy || !isFavorite ? null : rename,
              ),
              DeskButton(
                '取消收藏',
                quiet: true,
                onPressed: busy || !isFavorite
                    ? null
                    : () => run(() async {
                        if (!await widget.library.setFavorite(
                          selected,
                          false,
                        )) {
                          throw StateError('取消失败');
                        }
                      }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget folderRow(BuildContext context, String path) {
    final d = context.desk;
    final current = selected == path;
    return Semantics(
      selected: current,
      button: true,
      child: Tooltip(
        message: path,
        child: Material(
          color: current ? d.accentSoft : Colors.transparent,
          child: InkWell(
            onTap: busy ? null : () => setState(() => selected = path),
            child: Container(
              constraints: BoxConstraints(
                minHeight: MediaQuery.textScalerOf(context).scale(54),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: d.line)),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 18, color: d.ink2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.library.favoriteName(path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ui(12.5, w: 600, c: d.ink),
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
                  if (!current && widget.library is FolderCountService)
                    countBadge(path),
                  if (current) const DeskTag('输出位置', Tone.neutral),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
