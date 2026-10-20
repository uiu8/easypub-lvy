part of '../booksource_page.dart';

extension _BookSourceSearch on _BookSourcePageState {
  String _bookKey(Map item) => '${item['name']}\n${item['author']}';

  void _queueSearchEvent(Map<String, dynamic> event) {
    if (event['event'] == 'search.progress') {
      pendingSearchProgress = event;
    } else {
      pendingSearchResults.add(event);
      // 第一本立即显示；随后最多每 50ms 合并、排序并刷新一次。
      if (results.isEmpty && (event['items'] as List? ?? []).isNotEmpty) {
        _flushSearchEvents();
      }
    }
    searchRefresh ??= Timer(
      const Duration(milliseconds: 50),
      _flushSearchEvents,
    );
  }

  void _flushSearchEvents() {
    searchRefresh?.cancel();
    searchRefresh = null;
    if (!mounted ||
        (pendingSearchResults.isEmpty && pendingSearchProgress == null)) {
      return;
    }
    update(() {
      for (final event in pendingSearchResults) {
        _mergeSearch(event);
      }
      if (pendingSearchResults.isNotEmpty) _orderResults(query.text.trim());
      pendingSearchResults.clear();
      final p = pendingSearchProgress;
      if (p != null) {
        searchStatus =
            '已搜 ${p['done']}/${p['total']} 个书源，找到 ${results.length} 本 · 暂避 ${p['skipped'] ?? 0} 个近期故障源';
      }
      pendingSearchProgress = null;
    });
  }

  Map<String, dynamic> _searchParams(String key) => {
    'key': key,
    'stream': true,
    'searchId': activeSearchId,
    'concurrency': settings.searchConcurrency,
    'quick': settings.quick,
    'limit': settings.quickLimit,
    'skipUnhealthy': settings.skipUnhealthy && !includeSkippedOnce,
    'includeWebView': settings.includeWebView || sourceOnly != null,
    'filterTitle': settings.filterTitle,
    'onlyPriority': settings.onlyPriority,
    if (sourceOnly != null) 'sourceIds': [sourceOnly],
    if (searchScope.startsWith('f:')) 'files': [searchScope.substring(2)],
    if (searchScope.startsWith('g:')) 'groups': [searchScope.substring(2)],
  };

  void _mergeSearch(Map event) {
    if (event['pageState'] is Map) {
      searchPages['${event['sourceId']}'] = Map<String, dynamic>.from(
        event['pageState'] as Map,
      );
    }
    for (final raw in event['items'] as List? ?? []) {
      final book = Map<String, dynamic>.from(raw as Map);
      final entry = {
        'sourceId': event['sourceId'],
        'sourceName': event['sourceName'],
        'book': book,
        'ms': event['ms'],
        'pinned': event['pinned'],
        'rating': event['rating'],
        'score': event['score'],
        'customOrder': event['customOrder'],
      };
      final key = _bookKey(book);
      final existing = resultIndex[key];
      if (existing == null) {
        final row = <String, dynamic>{
          'name': book['name'],
          'author': book['author'],
          'sources': [entry],
        };
        resultIndex[key] = row;
        results.add(row);
      } else {
        final sources = existing['sources'] as List;
        if (!sources.any((s) => (s as Map)['sourceId'] == event['sourceId'])) {
          sources.add(entry);
        }
      }
    }
  }

  void _sortResults(String key) => _orderResults(key);

  Future<void> _enqueueResult(Map<String, dynamic> result) async {
    final list = List<Map>.from(result['sources'] as List)
      ..sort(_sourceCompare);
    final first = list.first;
    await api!.call('queue.add', {
      'sourceId': first['sourceId'],
      'book': first['book'],
      if (settings.fill || settings.multiSource)
        'alternates': [
          for (final source in list.skip(1))
            {'sourceId': source['sourceId'], 'book': source['book']},
        ],
      'options': {
        'folder': settings.folder,
        'threads': settings.threads,
        'multiSource': settings.multiSource,
        'maxAlternates': settings.maxAlternates,
        'alternateConcurrency': settings.alternateConcurrency,
        'removePagePrompts': settings.removePagePrompts,
      },
    });
  }

  Future<void> _downloadSelected() async {
    if (!await _ensureFolder()) return;
    final chosen = results
        .where((r) => selectedBooks.contains(_bookKey(r)))
        .toList();
    try {
      await api!.call('queue.configure', {'maxBooks': settings.maxBooks});
      for (final result in chosen) {
        await _enqueueResult(result);
      }
      await _loadQueue();
      update(() {
        selectedBooks.clear();
        tab = 'downloads';
      });
    } catch (e) {
      update(() => searchStatus = '$e');
    }
  }

  Future<void> _batchDownload() async {
    final text = await _askText(
      '按书名清单下载',
      hint: '每行一个：书名 或 书名 作者',
      multiline: true,
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    update(() {
      batchBusy = true;
      searchStatus = '正在逐本查找候选书源…';
    });
    try {
      final response = await api!.call('batch.resolve', {
        ..._searchParams(''),
        'text': text,
      }) as Map;
      final rows = List<Map>.from(response['items'] as List);
      final picks = <int, int>{
        for (var i = 0; i < rows.length; i++)
          i: rows[i]['status'] == 'resolved' ? 0 : -1,
      };
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, change) => AlertDialog(
            title: const Text('确认书名清单'),
            content: SizedBox(
              width: 620,
              height: 420,
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final row = rows[i];
                  final choices = row['candidates'] as List;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DeskText('${row['line']}', bold: true),
                        if (choices.isEmpty)
                          const DeskText('未找到；可返回搜索页单独搜索或换关键词。', size: 12)
                        else
                          DropdownButton<int>(
                            isExpanded: true,
                            value: picks[i],
                            items: [
                              const DropdownMenuItem(
                                value: -1,
                                child: Text('暂不下载'),
                              ),
                              for (var j = 0; j < choices.length; j++)
                                DropdownMenuItem(
                                  value: j,
                                  child: Text(
                                    '${(choices[j] as Map)['name']} · ${choices[j]['author']} · ${(choices[j]['sources'] as List).length} 个书源',
                                  ),
                                ),
                            ],
                            onChanged: (v) => change(() => picks[i] = v ?? -1),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            actions: [
              DeskButton(
                '取消',
                quiet: true,
                onPressed: () => Navigator.pop(dialog, false),
              ),
              DeskButton(
                '加入下载',
                primary: true,
                onPressed: () => Navigator.pop(dialog, true),
              ),
            ],
          ),
        ),
      );
      if (accepted != true || !await _ensureFolder()) return;
      await api!.call('queue.configure', {'maxBooks': settings.maxBooks});
      for (final entry in picks.entries) {
        if (entry.value >= 0) {
          await _enqueueResult(
            Map<String, dynamic>.from(
              (rows[entry.key]['candidates'] as List)[entry.value] as Map,
            ),
          );
        }
      }
      await _loadQueue();
      update(() => tab = 'downloads');
    } catch (e) {
      update(() => searchStatus = '$e');
    } finally {
      update(() => batchBusy = false);
    }
  }

  Future<void> _search() async {
    final key = query.text.trim();
    if (key.isEmpty || api == null || searching) return;
    searchRefresh?.cancel();
    searchRefresh = null;
    pendingSearchResults.clear();
    pendingSearchProgress = null;
    resultIndex.clear();
    searchPages.clear();
    update(() {
      searching = true;
      searchStatus = '正在搜索…';
      results = [];
      selected = null;
      toc = null;
      selectedBooks.clear();
      activeSearchId = 'ui-${DateTime.now().microsecondsSinceEpoch}';
    });
    final searchId = activeSearchId;
    try {
      final r = await api!.call('search', _searchParams(key)) as Map;
      if (!mounted || searchId != activeSearchId) return;
      // 汇总或停止先排空尾批，防止迟到的定时刷新覆盖“已停止”和最终数量。
      _flushSearchEvents();
      if (r['results'] is List) {
        results = [
          for (final x in r['results'] as List)
            Map<String, dynamic>.from(x as Map),
        ];
        resultIndex
          ..clear()
          ..addEntries(results.map((row) => MapEntry(_bookKey(row), row)));
      }
      _sortResults(key);
      _applySearchPages(r);
      searchStatus =
          '${r['cancelled'] == true ? '已停止 · ' : ''}搜了 ${r['searched']} 个书源（${r['failed']} 个失败或超时，${r['empty'] ?? 0} 个无结果），找到 ${results.length} 本 · 暂避 ${r['skipped'] ?? 0} 个近期故障源';
      await _loadSources();
    } catch (e) {
      if (!mounted || searchId != activeSearchId) return;
      _flushSearchEvents();
      searchStatus = '$e';
    }
    if (mounted && searchId == activeSearchId) update(() => searching = false);
    includeSkippedOnce = false;
  }

  void _applySearchPages(Map result) {
    for (final raw in result['pages'] as List? ?? []) {
      final page = Map<String, dynamic>.from(raw as Map);
      searchPages['${page['sourceId']}'] = page;
    }
  }

  Future<void> _continueSearch({bool retry = false, String? sourceId}) async {
    if (searching || activeSearchId == null) return;
    final id = activeSearchId;
    update(() {
      searching = true;
      searchStatus = retry ? '正在重试失败书源…' : '正在加载后续页…';
    });
    try {
      final result = await api!.call(retry ? 'search.retry' : 'search.more', {
        'searchId': id,
        'sourceId': ?sourceId,
      }) as Map;
      if (!mounted || activeSearchId != id) return;
      _flushSearchEvents();
      _applySearchPages(result);
      searchStatus =
          '${result['cancelled'] == true ? '已停止 · ' : ''}本次请求 ${result['searched']} 个书源，累计 ${results.length} 本';
    } catch (e) {
      if (!mounted || activeSearchId != id) return;
      searchStatus = '$e';
    } finally {
      if (mounted && activeSearchId == id) update(() => searching = false);
    }
  }

  Map<String, dynamic>? get _current =>
      selected == null ? null : results[selected!];
  Map<String, dynamic>? get _currentSource {
    final c = _current;
    if (c == null) return null;
    final list = c['sources'] as List;
    return Map<String, dynamic>.from(
      list[selectedSource.clamp(0, list.length - 1)] as Map,
    );
  }

  Future<void> _loadToc() async {
    final s = _currentSource;
    if (s == null) return;
    final bookKey = _bookKey(_current!);
    bool stillSelected() =>
        mounted &&
        _current != null &&
        _bookKey(_current!) == bookKey &&
        _currentSource?['sourceId'] == s['sourceId'];
    update(() {
      loadingToc = true;
      detailError = null;
      toc = null;
    });
    try {
      final info = await api!.call('book.info', {
        'sourceId': s['sourceId'],
        'book': s['book'],
      });
      if (!stillSelected()) return;
      ((_current!['sources'] as List)[selectedSource] as Map)['book'] = info;
      final list = await api!.call('book.toc', {
        'sourceId': s['sourceId'],
        'book': info,
      }) as List;
      if (!stillSelected()) return;
      toc = list;
      from.text = '1';
      to.text = '${list.length}';
    } catch (e) {
      if (stillSelected()) detailError = '$e';
    } finally {
      if (mounted) update(() => loadingToc = false);
    }
  }

  Future<void> _download() async {
    final s = _currentSource;
    if (s == null) return;
    if (!await _ensureFolder()) return;
    final book = Map<String, dynamic>.from(s['book'] as Map);
    try {
      final r = await api!.call('download.start', {
        'sourceId': s['sourceId'],
        'book': book,
        'toc': ?toc,
        if (settings.fill || settings.multiSource)
          'alternates': [
            for (final (i, x) in (_current!['sources'] as List).indexed)
              if (i != selectedSource)
                {'sourceId': (x as Map)['sourceId'], 'book': x['book']},
          ],
        'options': {
          'folder': settings.folder,
          'threads': settings.threads,
          'multiSource': settings.multiSource,
          'maxAlternates': settings.maxAlternates,
          'alternateConcurrency': settings.alternateConcurrency,
          'removePagePrompts': settings.removePagePrompts,
          'from': ?int.tryParse(from.text),
          'to': ?int.tryParse(to.text),
        },
      }) as Map;
      update(() {
        if (_task(r['taskId']) == null) {
          tasks.insert(
            0,
            DownloadTask(
              '${r['taskId']}',
              '${book['name']}',
              '${s['sourceName']}',
            ),
          );
        }
        tab = 'downloads';
      });
    } catch (e) {
      update(() => detailError = '$e');
    }
  }

  Widget _searchTab(BuildContext context) {
    final d = context.desk;
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('booksource-query'),
                controller: query,
                decoration: const InputDecoration(
                  hintText: '书名或作者',
                  isDense: true,
                ),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 10),
            DeskButton(
              '搜索',
              key: const ValueKey('booksource-search'),
              primary: true,
              busy: searching,
              onPressed: searching ? null : _search,
            ),
            if (searching)
              DeskButton(
                '停止搜索',
                key: const ValueKey('booksource-search-stop'),
                quiet: true,
                onPressed: () =>
                    api!.call('search.cancel', {'searchId': activeSearchId}),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 210,
              child: DeskChoice<String>(
                key: const ValueKey('booksource-search-scope'),
                value: searchScope,
                items: [
                  const DropdownMenuItem(value: '', child: Text('全部来源与分组')),
                  for (final file in {
                    for (final s in sources) '${s['file'] ?? '旧版导入'}',
                  })
                    DropdownMenuItem(
                      value: 'f:$file',
                      child: Text('文件：${_sourceFileName(file)}'),
                    ),
                  for (final group in {
                    for (final s in sources) ..._sourceGroups(s),
                  })
                    DropdownMenuItem(
                      value: 'g:$group',
                      child: Text('分组：$group'),
                    ),
                ],
                onChanged: searching
                    ? null
                    : (v) => update(() {
                        searchScope = v ?? '';
                        sourceOnly = null;
                      }),
              ),
            ),
            _toggle(
              '快速搜索',
              settings.quick,
              (v) => _saveSettings(() => settings.quick = v),
            ),
            DeskButton(
              '这次也搜暂避源',
              quiet: true,
              onPressed: searching
                  ? null
                  : () {
                      includeSkippedOnce = true;
                      _search();
                    },
            ),
            if (sourceOnly != null)
              DeskButton(
                '取消单源限制',
                quiet: true,
                onPressed: searching
                    ? null
                    : () => update(() => sourceOnly = null),
              ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            DeskButton(
              '全选结果',
              quiet: true,
              onPressed: results.isEmpty
                  ? null
                  : () => update(
                      () => selectedBooks.addAll(results.map(_bookKey)),
                    ),
            ),
            DeskButton(
              '加入下载（${selectedBooks.length}）',
              key: const ValueKey('booksource-download-selected'),
              quiet: true,
              onPressed: selectedBooks.isEmpty ? null : _downloadSelected,
            ),
            DeskButton(
              '书名清单…',
              key: const ValueKey('booksource-batch'),
              quiet: true,
              busy: batchBusy,
              onPressed: batchBusy || searching ? null : _batchDownload,
            ),
          ],
        ),
        _resultControls(),
        if (searchPages.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              DeskButton(
                '加载更多',
                key: const ValueKey('booksource-search-more'),
                onPressed:
                    searching ||
                        !searchPages.values.any(
                          (p) => p['ended'] != true && p['failed'] != true,
                        )
                    ? null
                    : () => _continueSearch(),
              ),
              DeskButton(
                '只重试失败的',
                key: const ValueKey('booksource-search-retry'),
                onPressed:
                    searching ||
                        !searchPages.values.any((p) => p['failed'] == true)
                    ? null
                    : () => _continueSearch(retry: true),
              ),
              for (final p in searchPages.values.where(
                (p) => p['failed'] == true,
              ))
                DeskButton(
                  '重试 ${p['sourceName']}',
                  quiet: true,
                  onPressed: searching
                      ? null
                      : () => _continueSearch(
                          retry: true,
                          sourceId: '${p['sourceId']}',
                        ),
                ),
            ],
          ),
        if (sources.isEmpty)
          DeskNote(
            '还没有书源。先到“书源”页签导入阅读 JSON、单文件 JS 或 so-novel JSON。',
            tone: Tone.info,
          )
        else if (searchStatus.isNotEmpty)
          DeskText(searchStatus, size: 12, color: d.ink2),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (context, i) {
              final r = results[i];
              final first =
                  ((r['sources'] as List).first as Map)['book'] as Map;
              return Material(
                color: selected == i ? d.surface : Colors.transparent,
                child: ListTile(
                  key: ValueKey('booksource-result-$i'),
                  dense: true,
                  leading: Checkbox(
                    key: ValueKey('booksource-select-$i'),
                    value: selectedBooks.contains(_bookKey(r)),
                    onChanged: (v) => update(() {
                      if (v == true) {
                        selectedBooks.add(_bookKey(r));
                      } else {
                        selectedBooks.remove(_bookKey(r));
                      }
                    }),
                  ),
                  title: DeskText('${r['name']}', bold: true),
                  subtitle: DeskText(
                    [
                      if ('${r['author']}'.isNotEmpty) '${r['author']}',
                      '${(r['sources'] as List).length} 个书源',
                      if (_num(first['chapterCount']) > 0)
                        '${first['countExact'] == true ? '' : '约'}${first['chapterCount']} 章',
                      if ('${first['lastChapter'] ?? ''}'.isNotEmpty)
                        '最新：${first['lastChapter']}',
                    ].join(' · '),
                    size: 12,
                    color: d.ink2,
                    lines: 1,
                  ),
                  onTap: () => update(() {
                    selected = i;
                    selectedSource = 0;
                    toc = null;
                    detailError = null;
                  }),
                ),
              );
            },
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 5, child: list),
          const SizedBox(width: 14),
          Expanded(flex: 4, child: _detail(context)),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context) {
    final d = context.desk;
    final c = _current;
    if (c == null) {
      return Center(child: DeskText('选一本书查看详情与目录', color: d.ink2));
    }
    final s = _currentSource!;
    final book = s['book'] as Map;
    final sourceList = c['sources'] as List;
    return DeskScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DeskText('${c['name']}', bold: true, size: 17),
          if ('${c['author']}'.isNotEmpty)
            DeskText('${c['author']}', color: d.ink2),
          const SizedBox(height: 10),
          const DeskLabel('书源'),
          DropdownButton<int>(
            key: const ValueKey('booksource-source-choice'),
            isExpanded: true,
            value: selectedSource.clamp(0, sourceList.length - 1),
            items: [
              for (var i = 0; i < sourceList.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    _sourceLabel(sourceList[i] as Map),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => update(() {
              selectedSource = v ?? 0;
              toc = null;
              detailError = null;
            }),
          ),
          if ('${book['kind'] ?? ''}'.isNotEmpty)
            DeskText('分类：${book['kind']}', size: 12, color: d.ink2),
          if ('${book['wordCount'] ?? ''}'.isNotEmpty)
            DeskText('字数：${book['wordCount']}', size: 12, color: d.ink2),
          if ('${book['intro'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: 8),
            DeskText('${book['intro']}', lines: 6),
          ],
          const SizedBox(height: 12),
          if (toc == null)
            DeskButton(
              '读取目录',
              key: const ValueKey('booksource-load-toc'),
              busy: loadingToc,
              onPressed: loadingToc ? null : _loadToc,
            )
          else ...[
            DeskText(
              '共 ${toc!.length} 章'
              '${toc!.any((x) => (x as Map)['isVip'] == true || x['isPay'] == true) ? '（含付费章节，付费内容取不到时会列出）' : ''}',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const DeskText('从第'),
                SizedBox(
                  width: 70,
                  child: TextField(
                    key: const ValueKey('booksource-from'),
                    controller: from,
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
                const DeskText('章到第'),
                SizedBox(
                  width: 70,
                  child: TextField(
                    key: const ValueKey('booksource-to'),
                    controller: to,
                    decoration: const InputDecoration(isDense: true),
                  ),
                ),
                const DeskText('章'),
              ],
            ),
            const SizedBox(height: 10),
            DeskButton(
              '下载',
              key: const ValueKey('booksource-download'),
              primary: true,
              icon: Icons.download,
              onPressed: _download,
            ),
          ],
          if (detailError != null) ...[
            const SizedBox(height: 10),
            DeskNote(detailError!, tone: Tone.warn),
          ],
        ],
      ),
    );
  }
}
