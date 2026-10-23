part of '../booksource_page.dart';

/// 收藏书源（LIB-219）与搜索范围里的“选择书源”（LIB-220）、收藏快捷搜索（LIB-221）。
/// 收藏只存在书源页的 ui.json，不改插件里的书源数据。
extension _BookSourceFavorites on _BookSourcePageState {
  bool _isFavorite(String id) => settings.favoriteSources.contains(id);

  void _toggleFavorite(String id) => _saveSettings(() {
    if (!settings.favoriteSources.remove(id)) settings.favoriteSources.add(id);
    // 取消最后一个收藏时，“只搜收藏”和树上的收藏节点随之失效。
    if (settings.favoriteSources.isEmpty) {
      if (searchScope == 'fav') searchScope = '';
      if (sourceNode == 'fav') sourceNode = '';
    }
  });

  /// 搜索范围对应的书源 ID；null 表示按全部 / 文件 / 分组搜索。
  List<String>? _scopeIds() => switch (searchScope) {
    'fav' => [
      for (final s in sources)
        if (_isFavorite('${s['id']}')) '${s['id']}',
    ],
    'pick' => pickedSources.toList(),
    _ => null,
  };

  /// 范围标签：下拉框与“已选”标签共用。
  String _pickedLabel() => pickedSources.length == 1
      ? '只搜：${sources.firstWhere((s) => s['id'] == pickedSources.first, orElse: () => const {'name': '1 个书源'})['name']}'
      : '已选 ${pickedSources.length} 个书源';

  /// 选择书源：按 JSON 文件分组，可勾整个文件，也可只勾其中一个或几个书源。
  Future<void> _pickSources() async {
    final picked = <String>{...pickedSources};
    final filter = TextEditingController();
    final open = <String>{
      for (final s in sources)
        if (picked.contains('${s['id']}')) _sourceFile(s),
    };
    var favoritesOnly = false;
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, change) {
          final d = dialog.desk;
          final key = filter.text.trim().toLowerCase();
          final files = <String, List<Map<String, dynamic>>>{};
          for (final s in sources) {
            final id = '${s['id']}';
            if (s['supported'] != true) continue;
            if (favoritesOnly && !_isFavorite(id)) continue;
            if (key.isNotEmpty &&
                !'${s['name']} ${s['group'] ?? ''}'.toLowerCase().contains(
                  key,
                )) {
              continue;
            }
            (files[_sourceFile(s)] ??= []).add(s);
          }
          final rows = <Widget>[];
          for (final file in files.entries) {
            final ids = [for (final s in file.value) '${s['id']}'];
            final count = ids.where(picked.contains).length;
            final expanded = open.contains(file.key) || key.isNotEmpty;
            rows.add(
              Material(
                color: Colors.transparent,
                child: InkWell(
                  key: ValueKey('booksource-pick-file-${file.key}'),
                  onTap: () => change(
                    () => open.contains(file.key)
                        ? open.remove(file.key)
                        : open.add(file.key),
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        key: ValueKey('booksource-pick-file-check-${file.key}'),
                        tristate: true,
                        value: count == 0
                            ? false
                            : count == ids.length
                            ? true
                            : null,
                        onChanged: (_) => change(
                          () => count == ids.length
                              ? picked.removeAll(ids)
                              : picked.addAll(ids),
                        ),
                      ),
                      Icon(
                        expanded
                            ? Icons.expand_more_rounded
                            : Icons.chevron_right_rounded,
                        size: 18,
                        color: d.ink2,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: DeskText(
                          _sourceFileName(file.key),
                          bold: true,
                          size: 13,
                          lines: 1,
                        ),
                      ),
                      DeskText(
                        count == 0 ? '${ids.length}' : '$count/${ids.length}',
                        size: 12,
                        color: d.ink3,
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            );
            if (!expanded) continue;
            for (final s in file.value) {
              final id = '${s['id']}';
              rows.add(
                Padding(
                  padding: const EdgeInsets.only(left: 26),
                  child: Row(
                    children: [
                      Checkbox(
                        key: ValueKey('booksource-pick-$id'),
                        value: picked.contains(id),
                        onChanged: (v) => change(
                          () => v == true ? picked.add(id) : picked.remove(id),
                        ),
                      ),
                      if (_isFavorite(id)) ...[
                        Icon(Icons.star_rounded, size: 15, color: d.warn),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: DeskText('${s['name']}', size: 13, lines: 1),
                      ),
                      if (s['enabled'] != true)
                        DeskText('已停用', size: 11.5, color: d.ink3),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              );
            }
          }
          final favorites = [
            for (final s in sources)
              if (s['supported'] == true && _isFavorite('${s['id']}'))
                '${s['id']}',
          ];
          return DeskAlert(
            key: const ValueKey('booksource-pick-dialog'),
            title: const Text('选择要搜索的书源'),
            content: SizedBox(
              width: 560,
              height: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('booksource-pick-filter'),
                          controller: filter,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '按书源名或分组筛选',
                            prefixIcon: Icon(Icons.search_rounded, size: 18),
                          ),
                          onChanged: (_) => change(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        key: const ValueKey('booksource-pick-favorites-only'),
                        label: Text('只看收藏（${favorites.length}）'),
                        selected: favoritesOnly,
                        onSelected: favorites.isEmpty
                            ? null
                            : (v) => change(() => favoritesOnly = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  DeskText(
                    '点文件名展开，可只勾其中一个或几个书源；勾文件前的方框选中整个文件。停用的书源被选中时也会搜索。',
                    size: 12,
                    color: d.ink2,
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: d.line),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: rows.isEmpty
                          ? Center(
                              child: DeskText(
                                '没有符合条件的书源',
                                size: 13,
                                color: d.ink3,
                              ),
                            )
                          : ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (_, i) => rows[i],
                            ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              DeskButton(
                '选中全部收藏',
                key: const ValueKey('booksource-pick-all-favorites'),
                quiet: true,
                onPressed: favorites.isEmpty
                    ? null
                    : () => change(() => picked.addAll(favorites)),
              ),
              DeskButton(
                '清空',
                quiet: true,
                onPressed: picked.isEmpty ? null : () => change(picked.clear),
              ),
              DeskButton(
                '取消',
                quiet: true,
                onPressed: () => Navigator.pop(dialog),
              ),
              DeskButton(
                picked.isEmpty ? '确定' : '确定（${picked.length}）',
                key: const ValueKey('booksource-pick-confirm'),
                primary: true,
                onPressed: picked.isEmpty
                    ? null
                    : () => Navigator.pop(dialog, {...picked}),
              ),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), filter.dispose);
    if (result == null || !mounted) return;
    update(() {
      pickedSources
        ..clear()
        ..addAll(result);
      searchScope = 'pick';
    });
  }
}
