part of '../booksource_page.dart';

extension _BookSourceShelf on _BookSourcePageState {
  bool _hasShelfUpdate(Map r) =>
      r['catalogChanged'] == true || (r['newChapters'] as num? ?? 0) > 0;

  String _catalogSummary(Map r) {
    final change = r['catalogChanges'] as Map? ?? {};
    return [
      if ((change['added'] as num? ?? r['newChapters'] as num? ?? 0) > 0)
        '${change['added'] ?? r['newChapters']} 新章',
      if ((change['removed'] as num? ?? 0) > 0) '${change['removed']} 删除',
      if ((change['modified'] as num? ?? 0) > 0) '${change['modified']} 修改',
      if ((change['moved'] as num? ?? 0) > 0) '${change['moved']} 调序',
      if ((change['volumes'] as num? ?? 0) > 0) '卷目录变化',
    ].join(' · ');
  }

  Future<void> _rebuild(String key) async {
    update(() {
      shelfBusy = true;
      shelfMessage = '正在用本地缓存重新整理…';
    });
    try {
      final result = await api!.call('library.rebuild', {'key': key}) as Map;
      final message = '已重新整理并保留备份：${result['backup']}';
      update(() {
        shelfMessage = message;
        sourceMessage = message;
      });
      await _loadShelf();
    } catch (e) {
      update(() {
        shelfMessage = '$e';
        sourceMessage = '$e';
      });
    } finally {
      update(() => shelfBusy = false);
    }
  }

  Future<void> _updateAll() async {
    final pending = shelf.where(_hasShelfUpdate).toList();
    update(() => shelfBusy = true);
    try {
      for (final record in pending) {
        await api!.call('library.update', {'key': record['key']});
      }
      await _loadQueue();
      update(() => tab = 'downloads');
    } catch (e) {
      update(() => shelfMessage = '$e');
    } finally {
      update(() => shelfBusy = false);
    }
  }

  Future<void> _loadShelf() async {
    try {
      final list = await api!.call('library.list') as List;
      shelf = [for (final x in list) Map<String, dynamic>.from(x as Map)];
    } catch (e) {
      shelfMessage = '$e';
    }
    if (mounted) update(() {});
  }

  Future<void> _checkShelf() async {
    update(() {
      shelfBusy = true;
      shelfMessage = '正在检查更新…';
    });
    try {
      final r = await api!.call('library.check', {
        'concurrency': settings.updateConcurrency,
      }) as Map;
      shelf = [
        for (final x in r['records'] as List)
          Map<String, dynamic>.from(x as Map),
      ];
      final changed =
          (r['changedBooks'] as num?) ?? shelf.where(_hasShelfUpdate).length;
      final errors =
          (r['errors'] as num?) ??
          shelf.where((r) => r['checkError'] != null).length;
      shelfMessage = [
        if (changed > 0) '$changed 本目录有变化，共 ${r['newChapters']} 个新章节。',
        if (errors > 0) '$errors 本检查失败，可查看书目中的原因。',
        if (changed == 0 && errors == 0) '都是最新的。',
      ].join(' ');
    } catch (e) {
      shelfMessage = '$e';
    }
    if (mounted) update(() => shelfBusy = false);
  }

  Future<void> _updateBook(Map<String, dynamic> record) async {
    try {
      final r =
          await api!.call('library.update', {'key': record['key']}) as Map;
      final book = record['book'] as Map;
      update(() {
        if (_task(r['taskId']) == null) {
          tasks.insert(
            0,
            DownloadTask(
              '${r['taskId']}',
              '${book['name']}（追更）',
              '${record['sourceName']}',
            ),
          );
        }
        tab = 'downloads';
      });
    } catch (e) {
      update(() => shelfMessage = '$e');
    }
  }

  String _autoCheckLabel() {
    if (autoCheckHours == 0) return '定时检查：关闭（可在“设置”里打开）';
    final last = autoCheckLast == 0
        ? '尚未检查'
        : () {
            final t = DateTime.fromMillisecondsSinceEpoch(autoCheckLast * 1000);
            String two(int n) => n.toString().padLeft(2, '0');
            return '上次 ${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
          }();
    return '定时检查：每 $autoCheckHours 小时 · $last';
  }

  Widget _shelfTab(BuildContext context) {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DeskButton(
                '检查更新',
                key: const ValueKey('booksource-shelf-check'),
                icon: Icons.update,
                busy: shelfBusy,
                onPressed: shelfBusy || shelf.isEmpty ? null : _checkShelf,
              ),
              DeskButton(
                '全部追更',
                key: const ValueKey('booksource-shelf-update-all'),
                quiet: true,
                onPressed: shelfBusy || !shelf.any(_hasShelfUpdate)
                    ? null
                    : _updateAll,
              ),
              DeskText(
                '更新时复用未变章节，只补新增或修改；失败时保留原 TXT。',
                size: 12,
                color: d.ink2,
              ),
              DeskText(
                key: const ValueKey('booksource-shelf-auto'),
                _autoCheckLabel(),
                size: 12,
                color: d.ink2,
              ),
            ],
          ),
          if (shelfMessage != null) ...[
            const SizedBox(height: 8),
            DeskNote(shelfMessage!),
          ],
          const SizedBox(height: 8),
          if (shelf.isEmpty) const DeskNote('还没有下载过的书。'),
          Expanded(
            child: ListView(
              children: [
                for (final r in shelf)
                  ListTile(
                    key: ValueKey('booksource-shelf-${r['key']}'),
                    dense: true,
                    title: Row(
                      children: [
                        Flexible(
                          child: DeskText(
                            '${(r['book'] as Map)['name']}',
                            bold: true,
                            lines: 1,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (_hasShelfUpdate(r))
                          DeskTag(_catalogSummary(r), Tone.accent),
                      ],
                    ),
                    subtitle: DeskText(
                      [
                        '${(r['book'] as Map)['author'] ?? ''}',
                        '${r['sourceName']}',
                        '${r['chapters']} 章',
                        if ('${r['latestOnline'] ?? r['latest'] ?? ''}'
                            .isNotEmpty)
                          '最新：${r['latestOnline'] ?? r['latest']}',
                        if (r['checkError'] != null) '检查失败：${r['checkError']}',
                      ].where((x) => x.isNotEmpty).join(' · '),
                      size: 12,
                      color: d.ink2,
                      lines: 2,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DeskButton(
                          '章节来源',
                          quiet: true,
                          onPressed: () => _provenance(r),
                        ),
                        DeskButton(
                          '重新整理',
                          key: ValueKey('booksource-rebuild-${r['key']}'),
                          quiet: true,
                          onPressed: shelfBusy
                              ? null
                              : () => _rebuild('${r['key']}'),
                        ),
                        DeskButton(
                          _hasShelfUpdate(r) ? '更新' : '重新下载',
                          key: ValueKey('booksource-shelf-update-${r['key']}'),
                          quiet: true,
                          onPressed: () => _updateBook(r),
                        ),
                        if (widget.openFolder != null)
                          IconButton(
                            tooltip: '打开文件夹',
                            icon: const Icon(
                              Icons.folder_open_outlined,
                              size: 18,
                            ),
                            onPressed: () => widget.openFolder!('${r['path']}'),
                          ),
                        IconButton(
                          tooltip: '删除记录与缓存（TXT 保留）',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await api!.call('library.remove', {
                              'key': r['key'],
                              'deleteCache': true,
                            });
                            await _loadShelf();
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
