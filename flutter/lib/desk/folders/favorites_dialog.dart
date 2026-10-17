// 收藏文件夹管理（D4-D，V8 按设计重写视图）：添加、重命名、取消收藏、重新定位逻辑沿用原实现。
import 'package:flutter/material.dart';

import '../dialogs.dart';
import '../tokens.dart';
import '../../application/library_service.dart';
import '../controls/controls.dart';

/// Returns a directory to scan; never moves or imports files itself.
class FavoritesDialog extends StatefulWidget {
  const FavoritesDialog({
    super.key,
    required this.library,
    required this.picker,
    this.selectionLabel = '打开文件夹',
  });
  final String selectionLabel;
  final LibraryService library;
  final BookFilePicker picker;
  @override
  State<FavoritesDialog> createState() => _FavoritesDialogState();
}

class _FavoritesDialogState extends State<FavoritesDialog> {
  String query = '', message = '';
  String? selected;
  bool busy = false;
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() => operation(() async => widget.library.loadFavorites());
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> operation(Future<bool> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final ok = await action();
      if (mounted && !ok) {
        setState(() => message = '未能保存，请检查目录、名称或设置文件权限；原设置保留。');
      }
    } catch (e) {
      if (mounted) setState(() => message = '操作失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose({bool add = false, bool relocate = false}) =>
      operation(() async {
        final path = await widget.picker.chooseFolder();
        if (path == null || !mounted) return true;
        if (add) {
          final ok = await widget.library.setFavorite(path, true);
          if (ok) selected = path;
          return ok;
        }
        if (relocate && selected != null) {
          final ok = await widget.library.relocateFavorite(selected!, path);
          if (ok) selected = path;
          return ok;
        }
        Navigator.pop(context, path);
        return true;
      });
  Future<void> rename() async {
    final path = selected;
    if (path == null || busy) return;
    var value = widget.library.favoriteName(path);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => DeskDialog(
        title: '重命名收藏',
        subtitle: '只改快捷入口的名称，不改磁盘上的文件夹',
        closeTooltip: '取消',
        width: 400,
        actions: [
          DeskButton(
            '取消',
            quiet: true,
            onPressed: () => Navigator.pop(context),
          ),
          DeskButton(
            '保存名称',
            primary: true,
            onPressed: () => Navigator.pop(context, value),
          ),
        ],
        child: TextFormField(
          key: const ValueKey('favorite-name-input'),
          initialValue: value,
          onChanged: (text) => value = text,
          autofocus: true,
          decoration: const InputDecoration(labelText: '收藏名称'),
          onFieldSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
    );
    if (name != null && mounted) {
      await operation(() => widget.library.renameFavorite(path, name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      title: '收藏文件夹',
      subtitle: '收藏只是快捷入口；取消收藏不删除磁盘文件',
      closeTooltip: '关闭收藏',
      width: 680,
      height: 520,
      busy: busy,
      footerLeft: Text(
        message.isEmpty ? '取消收藏只移除快捷入口，不删除磁盘中的文件。' : message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: ui(12, c: message.isEmpty ? d.ink3 : d.pen),
      ),
      actions: [
        DeskButton(
          '取消',
          quiet: true,
          onPressed: busy ? null : () => Navigator.pop(context),
        ),
        DeskButton(
          widget.selectionLabel,
          primary: true,
          onPressed: busy || selected == null
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
                  autofocus: true,
                  style: ui(13, c: d.ink),
                  decoration: const InputDecoration(
                    prefixIconConstraints: BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    hintText: '搜索收藏名称或路径',
                  ),
                  onChanged: (v) =>
                      setState(() => query = v.trim().toLowerCase()),
                ),
              ),
              const SizedBox(width: 8),
              DeskButton(
                '添加收藏',
                icon: Icons.add_rounded,
                onPressed: busy ? null : () => choose(add: true),
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
                child: AnimatedBuilder(
                  animation: Listenable.merge([
                    widget.library.favoriteFolders,
                    widget.library.favoriteNames,
                  ]),
                  builder: (context, _) {
                    final folders = widget.library.favoriteFolders.value
                        .where(
                          (p) => '${widget.library.favoriteName(p)}\n$p'
                              .toLowerCase()
                              .contains(query),
                        )
                        .toList();
                    if (folders.isEmpty) {
                      return Center(
                        child: Text(
                          query.isEmpty ? '尚未添加收藏文件夹' : '没有匹配的收藏',
                          style: ui(12.5, c: d.ink3),
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: folders.length,
                      itemBuilder: (_, i) => favoriteRow(context, folders[i]),
                    );
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              DeskButton(
                '浏览其他文件夹',
                icon: Icons.folder_open_outlined,
                onPressed: busy ? null : choose,
              ),
              DeskButton(
                '重命名',
                quiet: true,
                onPressed: busy || selected == null ? null : rename,
              ),
              DeskButton(
                '取消收藏',
                quiet: true,
                onPressed: busy || selected == null
                    ? null
                    : () => operation(() async {
                        final ok = await widget.library.setFavorite(
                          selected!,
                          false,
                        );
                        if (ok) selected = null;
                        return ok;
                      }),
              ),
              DeskButton(
                '重新定位',
                quiet: true,
                onPressed: busy || selected == null
                    ? null
                    : () => choose(relocate: true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget favoriteRow(BuildContext context, String path) {
    final d = context.desk;
    final current = selected == path;
    return Material(
      color: current ? d.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: busy ? null : () => setState(() => selected = path),
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: d.line)),
          ),
          child: Row(
            children: [
              Icon(Icons.star_rounded, size: 16, color: d.ink2),
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
              if (current) Icon(Icons.check_rounded, size: 17, color: d.ink),
            ],
          ),
        ),
      ),
    );
  }
}
