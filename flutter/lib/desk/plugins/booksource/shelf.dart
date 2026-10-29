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
      // 重新整理只改下载的 TXT，不碰书库里的草稿（V111）。
      final message =
          '已重新整理并保留备份：${result['backup']}。这本书已在书库时，书库里还是原来的版本，可在书库的书籍菜单里用“刷新来源”采用。';
      update(() {
        shelfMessage = message;
        sourceMessage = message;
      });
      await _loadShelf();
    } catch (e) {
      update(() {
        shelfMessage = bookSourceErrorText(e);
        sourceMessage = bookSourceErrorText(e);
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
      update(() => shelfMessage = bookSourceErrorText(e));
    } finally {
      update(() => shelfBusy = false);
    }
  }

  Future<void> _loadShelf() async {
    try {
      final list = await api!.call('library.list') as List;
      shelf = [for (final x in list) Map<String, dynamic>.from(x as Map)];
    } catch (e) {
      shelfMessage = bookSourceErrorText(e);
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
      shelfMessage = bookSourceErrorText(e);
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
      update(() => shelfMessage = bookSourceErrorText(e));
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
    // 同一本书（书名 + 作者）的多条下载记录合成一组。
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final r in shelf) {
      final book = r['book'] as Map;
      (groups['${book['name']}\n${book['author'] ?? ''}'] ??= []).add(r);
    }
    final updates = shelf.where(_hasShelfUpdate).length;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DeskButton(
                '检查更新',
                key: const ValueKey('booksource-shelf-check'),
                icon: Icons.update,
                busy: shelfBusy,
                onPressed: shelfBusy || shelf.isEmpty ? null : _checkShelf,
              ),
              const SizedBox(width: 8),
              DeskButton(
                updates == 0 ? '全部追更' : '全部追更（$updates）',
                key: const ValueKey('booksource-shelf-update-all'),
                primary: updates > 0,
                quiet: updates == 0,
                onPressed: shelfBusy || updates == 0 ? null : _updateAll,
              ),
              const Spacer(),
              Tooltip(
                message: '更新时复用未变章节，只补新增或修改；失败时保留原 TXT。',
                child: DeskText(
                  key: const ValueKey('booksource-shelf-auto'),
                  _autoCheckLabel(),
                  size: 12,
                  color: d.ink2,
                ),
              ),
            ],
          ),
          if (shelfMessage != null) ...[
            const SizedBox(height: 8),
            DeskNote(shelfMessage!),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: shelf.isEmpty
                ? const DeskEmptyState(
                    '还没有下载过的书。在“搜索”里找书并下载后会出现在这里。',
                    icon: Icons.auto_stories_outlined,
                  )
                : ListView(
                    children: [
                      for (final g in groups.entries)
                        _shelfGroup(g.key, g.value),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _shelfGroup(String key, List<Map<String, dynamic>> records) {
    final d = context.desk;
    final book = records.first['book'] as Map;
    final name = '${book['name']}';
    final added = records
        .map((r) => (r['newChapters'] as num? ?? 0).toInt())
        .fold(0, (a, b) => a > b ? a : b);
    final changed = records.any(_hasShelfUpdate);
    final single = records.length == 1;
    final expanded = single || shelfExpanded.contains(key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: d.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: d.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: single
                  ? null
                  : () => update(() {
                      if (!shelfExpanded.remove(key)) shelfExpanded.add(key);
                    }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: d.sunken,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: d.line),
                      ),
                      child: DeskText(
                        name.isEmpty ? '?' : name.characters.first,
                        size: 16,
                        color: d.ink2,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: DeskText(name, bold: true, lines: 1),
                              ),
                              if (changed) ...[
                                const SizedBox(width: 8),
                                DeskTag(
                                  added > 0 ? '+$added 新章' : '目录有变化',
                                  Tone.ok,
                                ),
                              ],
                            ],
                          ),
                          DeskText(
                            [
                              if ('${book['author'] ?? ''}'.isNotEmpty)
                                '${book['author']}',
                              '${records.first['chapters']} 章',
                              if (!single)
                                '${records.length} 个下载记录（${records.map((r) => r['sourceName']).join('、')}）',
                            ].join(' · '),
                            size: 12,
                            color: d.ink2,
                            lines: 1,
                          ),
                          if (single) _shelfRecordLine(records.first),
                        ],
                      ),
                    ),
                    if (single)
                      ..._shelfActions(records.first)
                    else
                      Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        color: d.ink2,
                      ),
                  ],
                ),
              ),
            ),
            if (!single && expanded)
              for (final r in records)
                Container(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: d.line)),
                  ),
                  padding: const EdgeInsets.fromLTRB(60, 6, 8, 6),
                  child: Row(
                    children: [
                      Expanded(child: _shelfRecordLine(r)),
                      ..._shelfActions(r),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 单条下载记录的说明：书源、最新章节、变化摘要、检查错误。
  Widget _shelfRecordLine(Map r) {
    final d = context.desk;
    return DeskText(
      [
        '${r['sourceName']}',
        if ('${r['latestOnline'] ?? r['latest'] ?? ''}'.isNotEmpty)
          '最新：${r['latestOnline'] ?? r['latest']}',
        if (_hasShelfUpdate(r)) _catalogSummary(r),
        if (r['checkError'] != null) '检查失败：${r['checkError']}',
      ].where((x) => x.isNotEmpty).join(' · '),
      size: 12,
      color: r['checkError'] != null ? d.pen : d.ink2,
      lines: 2,
    );
  }

  /// 主按钮“追更 / 重新下载”，文件夹，其余收进“⋯”。
  List<Widget> _shelfActions(Map<String, dynamic> r) => [
    DeskButton(
      _hasShelfUpdate(r) ? '追更' : '重新下载',
      key: ValueKey('booksource-shelf-update-${r['key']}'),
      primary: _hasShelfUpdate(r),
      quiet: !_hasShelfUpdate(r),
      onPressed: () => _updateBook(r),
    ),
    if (widget.openFolder != null)
      IconButton(
        tooltip: '打开文件夹',
        icon: const Icon(Icons.folder_open_outlined, size: 18),
        onPressed: () => widget.openFolder!('${r['path']}'),
      ),
    DeskMenuButton<VoidCallback>(
      key: ValueKey('booksource-shelf-menu-${r['key']}'),
      tooltip: '更多操作',
      icon: const Icon(Icons.more_horiz, size: 20),
      onSelected: (f) => f(),
      itemBuilder: (_) => [
        PopupMenuItem(value: () => _provenance(r), child: const Text('章节来源')),
        PopupMenuItem(
          key: ValueKey('booksource-rebuild-${r['key']}'),
          enabled: !shelfBusy,
          value: () => _rebuild('${r['key']}'),
          child: const Text('不联网重新整理'),
        ),
        PopupMenuItem(
          value: () async {
            await api!.call('library.remove', {
              'key': r['key'],
              'deleteCache': true,
            });
            await _loadShelf();
          },
          child: const Text('删除记录与缓存（TXT 保留）'),
        ),
      ],
    ),
  ];
}
