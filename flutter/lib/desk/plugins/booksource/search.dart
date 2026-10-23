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

  Map<String, dynamic> _searchParams(String key) {
    // 收藏或手动选择的书源（LIB-220/221）：明确指定，不再叠加“快速”“只搜优先”。
    final ids = _scopeIds();
    return {
      'key': key,
      'stream': true,
      'searchId': activeSearchId,
      'concurrency': settings.searchConcurrency,
      'quick': ids == null && settings.quick,
      'limit': settings.quickLimit,
      'skipUnhealthy': settings.skipUnhealthy && !includeSkippedOnce,
      'includeWebView': settings.includeWebView || ids != null,
      'filterTitle': settings.filterTitle,
      'onlyPriority': ids == null && settings.onlyPriority,
      'sourceIds': ?ids,
      if (searchScope.startsWith('f:')) 'files': [searchScope.substring(2)],
      if (searchScope.startsWith('g:')) 'groups': [searchScope.substring(2)],
    };
  }

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
    if (_scopeIds()?.isEmpty ?? false) {
      update(() => searchStatus = '收藏或选中的书源都已不在，请重新选择搜索范围。');
      return;
    }
    _saveSettings(() => settings.rememberSearch(key));
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
      // 读取详情和目录时书源脚本可能请求验证码等交互（LIB-212）。
      await _enableInteractions('${s['sourceId']}');
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
    final morePages = searchPages.values.any(
      (p) => p['ended'] != true && p['failed'] != true,
    );
    final failedPages = searchPages.values
        .where((p) => p['failed'] == true)
        .toList();
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // R1c：大搜索条——一张圆角卡片里放搜索框、范围与按钮。
        Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            color: d.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: d.lineStrong),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('booksource-query'),
                  controller: query,
                  style: ui(15, c: d.ink),
                  decoration: InputDecoration(
                    hintText: '搜索书名或作者',
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: d.ink2,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 20,
                    ),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 190,
                child: DeskChoice<String>(
                  key: const ValueKey('booksource-search-scope'),
                  value:
                      (searchScope == 'fav' &&
                              settings.favoriteSources.isEmpty) ||
                          (searchScope == 'pick' && pickedSources.isEmpty)
                      ? ''
                      : searchScope,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部来源与分组')),
                    if (settings.favoriteSources.isNotEmpty)
                      DropdownMenuItem(
                        value: 'fav',
                        child: Text(
                          '收藏的书源（${settings.favoriteSources.length}）',
                        ),
                      ),
                    DropdownMenuItem(
                      value: 'pick',
                      child: Text(
                        pickedSources.isEmpty ? '选择书源…' : _pickedLabel(),
                      ),
                    ),
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
                      : (v) => v == 'pick'
                            ? _pickSources()
                            : update(() => searchScope = v ?? ''),
                ),
              ),
              const SizedBox(width: 8),
              DeskButton(
                '搜索',
                key: const ValueKey('booksource-search'),
                primary: true,
                busy: searching,
                onPressed: searching ? null : _search,
              ),
              if (searching) ...[
                const SizedBox(width: 6),
                DeskButton(
                  '停止',
                  key: const ValueKey('booksource-search-stop'),
                  onPressed: () =>
                      api!.call('search.cancel', {'searchId': activeSearchId}),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    key: const ValueKey('booksource-quick'),
                    label: const Text('快速'),
                    tooltip: _scopeIds() != null
                        ? '已指定要搜的书源，这次不按“快速”筛选'
                        : '只搜健康排名靠前的 ${settings.quickLimit} 个书源',
                    selected: settings.quick && _scopeIds() == null,
                    onSelected: _scopeIds() != null
                        ? null
                        : (v) => _saveSettings(() => settings.quick = v),
                  ),
                  FilterChip(
                    key: const ValueKey('booksource-priority-only'),
                    label: const Text('只搜优先'),
                    tooltip: _scopeIds() != null
                        ? '已指定要搜的书源，这次不按“只搜优先”筛选'
                        : '只搜置顶书源和“优先”分组',
                    selected: settings.onlyPriority && _scopeIds() == null,
                    onSelected: _scopeIds() != null
                        ? null
                        : (v) => _saveSettings(() => settings.onlyPriority = v),
                  ),
                  FilterChip(
                    key: const ValueKey('booksource-include-skipped'),
                    label: const Text('含暂避源'),
                    tooltip: '这一次也搜连续失败而暂时跳过的书源',
                    selected: includeSkippedOnce,
                    onSelected: searching
                        ? null
                        : (v) => update(() => includeSkippedOnce = v),
                  ),
                  FilterChip(
                    key: const ValueKey('booksource-favorites-scope'),
                    avatar: Icon(
                      searchScope == 'fav'
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      size: 16,
                    ),
                    label: Text(
                      settings.favoriteSources.isEmpty
                          ? '收藏'
                          : '收藏 ${settings.favoriteSources.length}',
                    ),
                    tooltip: settings.favoriteSources.isEmpty
                        ? '在书源页点星标收藏书源后，可一键只搜收藏'
                        : '只搜收藏的书源',
                    showCheckmark: false,
                    selected: searchScope == 'fav',
                    onSelected: searching || settings.favoriteSources.isEmpty
                        ? null
                        : (v) => update(() => searchScope = v ? 'fav' : ''),
                  ),
                  if (searchScope == 'pick' && pickedSources.isNotEmpty)
                    InputChip(
                      key: const ValueKey('booksource-picked-chip'),
                      label: Text(_pickedLabel()),
                      tooltip: '点一下修改所选书源',
                      onPressed: searching ? null : _pickSources,
                      onDeleted: searching
                          ? null
                          : () => update(() {
                              pickedSources.clear();
                              searchScope = '';
                            }),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: 120,
              child: DeskChoice<String>(
                key: const ValueKey('booksource-result-sort'),
                value: settings.resultSort,
                items: [
                  for (final e in {
                    'overall': '综合排序',
                    'chapters': '章节数',
                    'latest': '最新章节',
                    'sources': '书源数',
                    'speed': '响应速度',
                  }.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => _saveSettings(() {
                  settings.resultSort = v ?? 'overall';
                  _orderResults(query.text.trim());
                }),
              ),
            ),
            IconButton(
              key: const ValueKey('booksource-enrich'),
              tooltip: '补全前 10 本的真实章节数（读取目录）',
              icon: enriching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.format_list_numbered, size: 20),
              onPressed: searching || enriching || results.isEmpty
                  ? null
                  : _enrichResults,
            ),
          ],
        ),
        if (sources.isEmpty)
          DeskNote(
            '还没有书源。先到“书源”页签导入阅读 JSON、单文件 JS 或 so-novel JSON。',
            tone: Tone.info,
          )
        else if (searchStatus.isNotEmpty || searchPages.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (searchStatus.isNotEmpty)
                  DeskText(searchStatus, size: 12, color: d.ink2),
                if (searchPages.isNotEmpty) ...[
                  DeskButton(
                    '加载更多',
                    key: const ValueKey('booksource-search-more'),
                    quiet: true,
                    onPressed: searching || !morePages
                        ? null
                        : () => _continueSearch(),
                  ),
                  DeskButton(
                    '只重试失败的（${failedPages.length}）',
                    key: const ValueKey('booksource-search-retry'),
                    quiet: true,
                    onPressed: searching || failedPages.isEmpty
                        ? null
                        : () => _continueSearch(retry: true),
                  ),
                  if (failedPages.isNotEmpty)
                    DeskMenuButton<String>(
                      tooltip: '单独重试某个书源',
                      onSelected: (id) =>
                          _continueSearch(retry: true, sourceId: id),
                      itemBuilder: (_) => [
                        for (final p in failedPages)
                          PopupMenuItem(
                            value: '${p['sourceId']}',
                            child: Text('重试 ${p['sourceName']}'),
                          ),
                      ],
                      // R1：用图标代替“▾”文字（缺字时会显示成方框）。
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DeskText('单独重试', size: 12, color: d.ink2),
                          Icon(
                            Icons.expand_more_rounded,
                            size: 15,
                            color: d.ink2,
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: results.isEmpty
              ? _searchEmpty(context)
              : LayoutBuilder(
                  builder: (context, box) => box.maxWidth >= 620
                      ? GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisExtent: 104,
                                crossAxisSpacing: 8,
                              ),
                          itemCount: results.length,
                          itemBuilder: (context, i) => _resultRow(i),
                        )
                      : ListView.builder(
                          itemCount: results.length,
                          itemBuilder: (context, i) => _resultRow(i),
                        ),
                ),
        ),
        Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: d.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: d.line),
          ),
          child: Row(
            children: [
              DeskText('已选 ${selectedBooks.length} 本', size: 12, color: d.ink2),
              DeskButton(
                '全选结果',
                quiet: true,
                onPressed: results.isEmpty
                    ? null
                    : () => update(
                        () => selectedBooks.addAll(results.map(_bookKey)),
                      ),
              ),
              if (selectedBooks.isNotEmpty)
                DeskButton(
                  '清空',
                  quiet: true,
                  onPressed: () => update(selectedBooks.clear),
                ),
              const Spacer(),
              DeskButton(
                '书名清单…',
                key: const ValueKey('booksource-batch'),
                quiet: true,
                busy: batchBusy,
                onPressed: batchBusy || searching ? null : _batchDownload,
              ),
              const SizedBox(width: 6),
              DeskButton(
                '加入下载（${selectedBooks.length}）',
                key: const ValueKey('booksource-download-selected'),
                primary: selectedBooks.isNotEmpty,
                quiet: selectedBooks.isEmpty,
                onPressed: selectedBooks.isEmpty ? null : _downloadSelected,
              ),
            ],
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
          Expanded(
            flex: 4,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: d.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: d.line),
              ),
              child: _detail(context),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索结果一行：书名首字封面块、书名、作者 · 章数 · 书源数 · 最快书源 · 最新章节。
  Widget _resultRow(int i) {
    final d = context.desk;
    final r = results[i];
    final list = r['sources'] as List;
    final first = (list.first as Map)['book'] as Map;
    final fastest = list
        .map((s) => _num((s as Map)['ms']))
        .where((ms) => ms > 0)
        .fold<num>(0, (a, b) => a == 0 || b < a ? b : a);
    final name = '${r['name']}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected == i ? d.accentSoft : d.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: selected == i ? d.accent : d.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('booksource-result-$i'),
          onTap: () => update(() {
            selected = i;
            selectedSource = 0;
            toc = null;
            detailError = null;
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Row(
              children: [
                _coverThumb(
                  first['coverUrl']?.toString(),
                  name,
                  width: 60,
                  height: 80,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DeskText(name, bold: true, lines: 1),
                      // R1c：卡片两列时信息分行，不再挤成一行被截断。
                      DeskText(
                        [
                          if ('${r['author']}'.isNotEmpty) '${r['author']}',
                          if (_num(first['chapterCount']) > 0)
                            '${first['countExact'] == true ? '' : '约'}${first['chapterCount']} 章',
                        ].join(' · '),
                        size: 12,
                        color: d.ink2,
                        lines: 1,
                      ),
                      DeskText(
                        [
                          '${list.length} 个书源',
                          if (fastest > 0)
                            '最快 ${(fastest / 1000).toStringAsFixed(1)}s',
                        ].join(' · '),
                        size: 12,
                        color: fastest > 0 && fastest < 1000 ? d.add : d.ink2,
                        lines: 1,
                      ),
                      if ('${first['lastChapter'] ?? ''}'.isNotEmpty)
                        DeskText(
                          '最新：${first['lastChapter']}',
                          size: 12,
                          color: d.ink3,
                          lines: 1,
                        ),
                    ],
                  ),
                ),
                Checkbox(
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
              ],
            ),
          ),
        ),
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _coverThumb(
                book['coverUrl']?.toString(),
                '${c['name']}',
                width: 84,
                height: 112,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DeskText('${c['name']}', bold: true, size: 17),
                    if ('${c['author']}'.isNotEmpty)
                      DeskText('${c['author']}', color: d.ink2),
                  ],
                ),
              ),
            ],
          ),
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

  /// 封面缩略图（R1c）：书源给了封面地址就加载，加载失败或没有时显示书名首字。
  Widget _coverThumb(
    String? url,
    String name, {
    required double width,
    required double height,
  }) {
    final d = context.desk;
    final placeholder = Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: d.sunken,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: d.line),
      ),
      child: DeskText(
        name.isEmpty ? '?' : name.characters.first,
        size: width / 2.6,
        color: d.ink3,
      ),
    );
    if (url == null || !url.startsWith('http')) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        width: width,
        height: height,
        fit: BoxFit.cover,
        cacheWidth: (width * 2).round(),
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }

  /// 搜索页空状态（R1c）：最近搜索可以点着再搜。
  Widget _searchEmpty(BuildContext context) {
    final d = context.desk;
    if (searching) {
      return Center(child: DeskText('正在搜索…', color: d.ink2));
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.travel_explore_rounded, size: 34, color: d.lineStrong),
            const SizedBox(height: 10),
            DeskText('输入书名或作者开始搜索', color: d.ink2),
            if (settings.recentSearches.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('最近搜索', style: ui(11.5, w: 600, c: d.ink3)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  for (final q in settings.recentSearches)
                    ActionChip(
                      key: ValueKey('booksource-recent-$q'),
                      avatar: Icon(
                        Icons.history_rounded,
                        size: 15,
                        color: d.ink3,
                      ),
                      label: Text(q),
                      onPressed: () {
                        query.text = q;
                        _search();
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
