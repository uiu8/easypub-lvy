part of '../booksource_page.dart';

extension _BookSourceSources on _BookSourcePageState {
  /// 导入结果里写明新书源放在哪里、分组是否保留（对应设置里的导入偏好）。
  String _importSummary(Map r) {
    int count(Object? v) => v is num ? v.toInt() : (v is List ? v.length : 0);
    final added = count(r['added']), updated = count(r['updated']);
    final skipped = count(r['skipped']);
    final parts = <String>[
      added > 0
          ? '新增 $added 个书源（放在${importOptions['position'] == 'top' ? '最前' : '最后'}）'
          : '没有新增书源',
      if (updated > 0)
        '更新 $updated 个${importOptions['overrideGroup'] == true ? '' : '（保留了你的分组）'}',
      if (skipped > 0) '跳过 $skipped 条无法识别的',
    ];
    return '${parts.join('，')}；共 ${r['total']} 个。';
  }

  Future<void> _importFile() async {
    final path = await widget.chooseSourceFile();
    if (path == null) return;
    try {
      final r = await api!.call('sources.import', {'path': path}) as Map;
      await _loadSources();
      update(() => sourceMessage = _importSummary(r));
    } catch (e) {
      update(() => sourceMessage = '$e');
    }
  }

  Future<void> _importUrl(BuildContext context) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从网址导入书源'),
        content: SizedBox(
          width: 460,
          child: TextField(
            key: const ValueKey('booksource-import-url-field'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'https://…（书源 JSON 的网址）',
            ),
          ),
        ),
        actions: [
          DeskButton(
            '取消',
            quiet: true,
            onPressed: () => Navigator.pop(context),
          ),
          DeskButton(
            '导入',
            primary: true,
            onPressed: () => Navigator.pop(context, controller.text.trim()),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    update(() {
      importingSource = true;
      sourceMessage = '正在通过当前网络设置下载书源，大文件最多等待 2 分钟…';
    });
    try {
      final r = await api!.call('sources.importUrl', {'url': url}) as Map;
      await _loadSources();
      sourceMessage = '从网址导入：${_importSummary(r)}';
      if (r['previewRequired'] == true && mounted) {
        await _subscriptionPreview(url, r['subscription'] as Map);
      }
    } catch (e) {
      sourceMessage = '$e';
    } finally {
      importingSource = false;
    }
    if (mounted) update(() {});
  }

  Future<void> _login(BuildContext context, Map<String, dynamic> source) async {
    try {
      final info =
          await api!.call('source.loginInfo', {'id': source['id']}) as Map;
      final ui = info['ui'];
      if (ui is List && ui.isNotEmpty) {
        final fields = [
          for (final f in ui)
            if (f is Map && f['type'] != 'button') Map<String, dynamic>.from(f),
        ];
        final controllers = {
          for (final f in fields) '${f['name']}': TextEditingController(),
        };
        if (!context.mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('登录 ${source['name']}'),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final f in fields)
                    TextField(
                      controller: controllers['${f['name']}'],
                      obscureText: f['type'] == 'password',
                      decoration: InputDecoration(labelText: '${f['name']}'),
                    ),
                  const SizedBox(height: 10),
                  const DeskText('填写的信息只在本次运行里使用，不保存到文件。', size: 12),
                ],
              ),
            ),
            actions: [
              DeskButton(
                '取消',
                quiet: true,
                onPressed: () => Navigator.pop(context, false),
              ),
              DeskButton(
                '登录',
                primary: true,
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          ),
        );
        if (ok != true) return;
        final r = await api!.call('source.login', {
          'id': source['id'],
          'info': {for (final e in controllers.entries) e.key: e.value.text},
        }) as Map;
        sourceMessage = '${r['message']}';
      } else {
        update(() => sourceMessage = '已打开登录网页：在窗口里登录，完成后关闭窗口。');
        final r = await api!.call('source.login', {'id': source['id']}) as Map;
        sourceMessage = '${r['message']}';
      }
    } catch (e) {
      sourceMessage = '登录没有完成：$e';
    }
    if (mounted) update(() {});
  }

  Future<String?> _askText(
    String title, {
    String initial = '',
    String hint = '',
    bool multiline = false,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: multiline ? 8 : 1,
            maxLines: multiline ? 14 : 1,
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        actions: [
          DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(dialog)),
          DeskButton(
            '确定',
            primary: true,
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
          ),
        ],
      ),
    );
    // 弹层关闭动画结束后 TextField 不再使用控制器。
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    return result;
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            DeskButton(
              '取消',
              quiet: true,
              onPressed: () => Navigator.pop(dialog, false),
            ),
            DeskButton(
              '确认删除',
              dangerous: true,
              onPressed: () => Navigator.pop(dialog, true),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _sourceAction(
    String method,
    Map<String, dynamic> params, {
    String? message,
  }) async {
    try {
      final result = await api!.call(method, params);
      await _loadSources();
      update(() {
        selectedSources.removeWhere((id) => !sources.any((s) => s['id'] == id));
        sourceMessage =
            message ??
            '操作完成${result is Map && result['changed'] != null ? '，处理 ${result['changed']} 个书源' : ''}。';
      });
    } catch (e) {
      update(() => sourceMessage = '$e');
    }
  }

  Future<void> _probe(bool ping, [List<String>? ids]) async {
    update(() {
      if (ping) {
        pinging = true;
      } else {
        checking = true;
      }
      checkStatus = ping ? '正在测速…' : '正在校验搜索、详情、目录与正文…';
    });
    try {
      final r = await api!.call(ping ? 'sources.ping' : 'sources.check', {
        'ids': ?ids,
        'concurrency': ping ? 32 : settings.checkConcurrency,
        if (checkKeyword.text.trim().isNotEmpty)
          'key': checkKeyword.text.trim(),
      }) as Map;
      await _loadSources();
      checkStatus =
          '${ping ? '测速' : '校验'}了 ${r['total']} 个书源，${ping ? '可连接' : '通过校验'} ${r['ok']} 个。';
    } catch (e) {
      checkStatus = '$e';
    }
    update(() {
      if (ping) {
        pinging = false;
      } else {
        checking = false;
      }
    });
  }

  Future<void> _removeSources(List<String> ids) async {
    if (ids.isEmpty ||
        !await _confirm('删除书源', '确认删除这 ${ids.length} 个书源？已下载的书会保留。')) {
      return;
    }
    await _sourceAction('sources.removeMany', {
      'ids': ids,
    }, message: '已删除 ${ids.length} 个书源。');
  }

  Future<void> _dedupe() async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('清理重复书源'),
        content: const Text('同一书源地址保留规则更新时间最新的一份，其余选择停用或删除。'),
        actions: [
          DeskButton('取消', quiet: true, onPressed: () => Navigator.pop(dialog)),
          DeskButton('停用重复', onPressed: () => Navigator.pop(dialog, 'disable')),
          DeskButton(
            '删除重复',
            dangerous: true,
            onPressed: () => Navigator.pop(dialog, 'delete'),
          ),
        ],
      ),
    );
    if (action != null) {
      await _sourceAction('sources.dedupe', {'action': action});
    }
  }

  Future<void> _sourceDetail(Map<String, dynamic> source) async {
    try {
      final detail =
          await api!.call('sources.detail', {'id': source['id']}) as Map;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('${source['name']}'),
          content: SizedBox(
            width: 640,
            height: 430,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    '${detail['url']}\nWebView：${detail['webView'] == true ? '需要' : '不需要'} · 登录：${detail['login'] == true ? '需要' : '不需要'}\n访问频率：${detail['concurrentRate'] == '' ? '未设置' : detail['concurrentRate']}',
                  ),
                  const SizedBox(height: 12),
                  DeskText(
                    '标签：${(detail['tags'] as List? ?? []).join(' / ')}',
                    size: 12,
                  ),
                  _LatencyChart(
                    (detail['health'] as Map?)?['ms'] as List? ?? [],
                  ),
                  DeskText(
                    '建议并发：${(detail['learned'] as Map?)?['safeLimit'] ?? '尚未学习'} · 最近限流时间：${(detail['learned'] as Map?)?['lastThrottleAt'] ?? '暂无'}',
                    size: 12,
                  ),
                  for (final warning in detail['warnings'] as List? ?? [])
                    DeskNote('$warning'),
                  DeskButton(
                    '下载参数与评分',
                    key: const ValueKey('booksource-profile'),
                    onPressed: () {
                      Navigator.pop(dialog);
                      _editSource(source, detail);
                    },
                  ),
                  for (final entry in {
                    'ruleSearch': '搜索',
                    'ruleBookInfo': '详情',
                    'ruleToc': '目录',
                    'ruleContent': '正文',
                  }.entries) ...[
                    const SizedBox(height: 12),
                    DeskText(entry.value, bold: true),
                    SelectableText(
                      const JsonEncoder.withIndent('  ')
                          .convert(detail[entry.key] ?? {}),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            DeskButton(
              '关闭',
              quiet: true,
              onPressed: () => Navigator.pop(dialog),
            ),
            DeskButton(
              '用这个书源单独搜索',
              onPressed: () {
                Navigator.pop(dialog);
                update(() {
                  sourceOnly = '${source['id']}';
                  searchScope = '';
                  tab = 'search';
                });
              },
            ),
          ],
        ),
      );
    } catch (e) {
      update(() => sourceMessage = '$e');
    }
  }

  List<Map<String, dynamic>> _shownSources() {
    final filter = sourceFilter.text.trim().toLowerCase();
    final shown = sources.where((s) {
      if (filter.isNotEmpty &&
          !'${s['name']} ${s['url'] ?? s['id']} ${s['group']}'
              .toLowerCase()
              .contains(filter)) {
        return false;
      }
      if (recommendedOnly && s['recommended'] != true) return false;
      if (!sourceTags.every((t) => (s['tags'] as List? ?? []).contains(t))) {
        return false;
      }
      final check = s['check'] as Map?;
      if (_sourceCauses.containsKey(sourceStatusFilter)) {
        return (s['cause'] ?? check?['cause']) == sourceStatusFilter;
      }
      return switch (sourceStatusFilter) {
        'ok' => check?['ok'] == true,
        'failed' => check?['ok'] == false,
        'untested' => check == null,
        'webview' => s['webView'] == true,
        'login' => s['login'] == true,
        'disabled' => s['enabled'] != true,
        _ => true,
      };
    }).toList();
    num speed(Map s) => ((s['check'] as Map?)?['ms'] as num?) ?? 999999;
    shown.sort(
      (a, b) => switch (sourceSort) {
        'manual' => _num(a['customOrder']).compareTo(_num(b['customOrder'])),
        'rating' => (_num(b['rating']) * 50 + _num(b['autoWeight'])).compareTo(
          _num(a['rating']) * 50 + _num(a['autoWeight']),
        ),
        'speed' => speed(a).compareTo(speed(b)),
        'name' => '${a['name']}'.compareTo('${b['name']}'),
        'recent' => (((b['health'] as Map?)?['lastOk'] as num?) ?? 0).compareTo(
          ((a['health'] as Map?)?['lastOk'] as num?) ?? 0,
        ),
        'import' => ((b['importedAt'] as num?) ?? 0).compareTo(
          (a['importedAt'] as num?) ?? 0,
        ),
        _ => 0,
      },
    );
    return shown;
  }

  Widget _sourcesTab(BuildContext context) {
    final d = context.desk;
    final shown = _shownSources();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final source in shown) {
      final keys = settings.groupBy == 'file'
          ? ['${source['file'] ?? '旧版导入'}']
          : _sourceGroups(source);
      for (final key in keys.isEmpty ? ['未分组'] : keys) {
        (groups[key] ??= []).add(source);
      }
    }
    final rows = <Widget>[];
    for (final entry in groups.entries) {
      final name = entry.key, items = entry.value;
      final collapsedKey = '${settings.groupBy}:$name';
      final collapsed = settings.collapsed.contains(collapsedKey);
      final ids = items.map((s) => '${s['id']}').toList();
      final ok = items.where((s) => (s['check'] as Map?)?['ok'] == true).length;
      final failed = items
          .where((s) => (s['check'] as Map?)?['ok'] == false)
          .length;
      rows.add(
        Container(
          key: ValueKey('booksource-group-$name'),
          color: d.surface,
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    key: ValueKey('booksource-collapse-$name'),
                    tooltip: collapsed ? '展开来源' : '收起来源',
                    icon: Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                    ),
                    onPressed: () => _saveSettings(() {
                      if (collapsed) {
                        settings.collapsed.remove(collapsedKey);
                      } else {
                        settings.collapsed.add(collapsedKey);
                      }
                    }),
                  ),
                  Expanded(
                    child: DeskText(
                      '${settings.groupBy == 'file' ? _sourceFileName(name) : name} · ${items.length} 个'
                      ' · 可用 $ok / 失效 $failed / 未测 ${items.length - ok - failed}',
                      bold: true,
                      lines: 2,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  DeskButton('整组置顶', quiet: true, onPressed: () => _pin(ids)),
                  DeskButton(
                    '整组置底',
                    quiet: true,
                    onPressed: () => _pin(ids, bottom: true),
                  ),
                  DeskButton(
                    '全部启用',
                    quiet: true,
                    onPressed: () => _sourceAction('sources.setEnabledMany', {
                      'ids': ids,
                      'enabled': true,
                    }),
                  ),
                  DeskButton(
                    '全部停用',
                    quiet: true,
                    onPressed: () => _sourceAction('sources.setEnabledMany', {
                      'ids': ids,
                      'enabled': false,
                    }),
                  ),
                  DeskButton(
                    '测速',
                    quiet: true,
                    onPressed: pinging ? null : () => _probe(true, ids),
                  ),
                  DeskButton(
                    '校验',
                    quiet: true,
                    onPressed: checking ? null : () => _probe(false, ids),
                  ),
                  if (settings.groupBy == 'file' && name.startsWith('http'))
                    DeskButton(
                      '从网址更新',
                      quiet: true,
                      onPressed: () => _subscriptionPreview(name),
                    ),
                  DeskButton(
                    settings.groupBy == 'file' ? '删除整个文件' : '删除这组',
                    quiet: true,
                    onPressed: () => _removeSources(ids),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      if (!collapsed) {
        for (final source in items) {
          rows.add(_dragSourceRow(source, name));
        }
      }
    }
    final failedIds = sources
        .where((s) => (s['check'] as Map?)?['ok'] == false)
        .map((s) => '${s['id']}')
        .toList();
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DeskButton(
                '导入书源文件…',
                key: const ValueKey('booksource-import'),
                icon: Icons.file_open_outlined,
                onPressed: _importFile,
              ),
              DeskButton(
                '从网址导入…',
                key: const ValueKey('booksource-import-url'),
                quiet: true,
                busy: importingSource,
                onPressed: importingSource ? null : () => _importUrl(context),
              ),
              DeskButton(
                '测速书源',
                key: const ValueKey('booksource-ping'),
                quiet: true,
                busy: pinging,
                onPressed: pinging ? null : () => _probe(true),
              ),
              DeskButton(
                '订阅与更新',
                key: const ValueKey('booksource-subscriptions'),
                quiet: true,
                onPressed: _subscriptions,
              ),
              DeskButton(
                '不支持的写法排行',
                key: const ValueKey('booksource-unsupported-ranking'),
                quiet: true,
                onPressed: _unsupportedRanking,
              ),
              DeskButton(
                '校验书源',
                key: const ValueKey('booksource-check'),
                quiet: true,
                busy: checking,
                onPressed: checking ? null : () => _probe(false),
              ),
              DeskButton(
                '清理重复',
                key: const ValueKey('booksource-dedupe'),
                quiet: true,
                onPressed: _dedupe,
              ),
              if (failedIds.isNotEmpty) ...[
                DeskButton(
                  '停用失效的',
                  key: const ValueKey('booksource-disable-failed'),
                  quiet: true,
                  onPressed: () => _sourceAction('sources.setEnabled', {
                    'ids': failedIds,
                    'enabled': false,
                  }, message: '已停用 ${failedIds.length} 个校验失败的书源。'),
                ),
                DeskButton(
                  '删除失效的',
                  key: const ValueKey('booksource-delete-failed'),
                  quiet: true,
                  onPressed: () => _removeSources(failedIds),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 210,
                child: TextField(
                  key: const ValueKey('booksource-filter'),
                  controller: sourceFilter,
                  decoration: const InputDecoration(
                    hintText: '名称 / 网址 / 分组',
                    isDense: true,
                  ),
                  onChanged: (_) => update(() {}),
                ),
              ),
              SizedBox(
                width: 140,
                child: DeskChoice<String>(
                  value: sourceStatusFilter,
                  items: [
                    for (final e in {
                      'all': '全部状态',
                      'ok': '可用',
                      'failed': '失效',
                      'untested': '未测',
                      'webview': 'WebView',
                      'login': '需登录',
                      'disabled': '已停用',
                      ..._sourceCauses,
                    }.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) =>
                      update(() => sourceStatusFilter = v ?? 'all'),
                ),
              ),
              SizedBox(
                width: 140,
                child: DeskChoice<String>(
                  value: sourceSort,
                  items: [
                    for (final e in {
                      'manual': '自定顺序（可拖动）',
                      'rating': '评分与权重',
                      'import': '导入顺序',
                      'speed': '按速度',
                      'name': '按名称',
                      'recent': '最近成功',
                    }.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => update(() => sourceSort = v ?? 'import'),
                ),
              ),
              SizedBox(
                width: 150,
                child: DeskChoice<String>(
                  value: settings.groupBy,
                  items: const [
                    DropdownMenuItem(value: 'file', child: Text('按来源文件')),
                    DropdownMenuItem(value: 'group', child: Text('按分组')),
                  ],
                  onChanged: (v) =>
                      _saveSettings(() => settings.groupBy = v ?? 'file'),
                ),
              ),
              SizedBox(
                width: 190,
                child: TextField(
                  controller: checkKeyword,
                  decoration: const InputDecoration(
                    hintText: '校验词（留空按书源）',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          _sourceFilters(),
          if (sourceMessage != null) DeskNote(sourceMessage!),
          if (checkStatus != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: DeskText(checkStatus!, size: 12, color: d.ink2),
            ),
          if (rows.isEmpty) const DeskNote('没有符合条件的书源。'),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) => rows[i],
            ),
          ),
          _selectionBar(shown),
        ],
      ),
    );
  }

  /// 底部操作条（参考轻悦时光）：全选 / 反选常驻；选中后显示启用、停用、删除和“更多”。
  Widget _selectionBar(List<Map<String, dynamic>> shown) {
    final d = context.desk;
    final ids = shown.map((s) => '${s['id']}').toList();
    final picked = ids.where(selectedSources.contains).length;
    final all = ids.isNotEmpty && picked == ids.length;
    final chosen = selectedSources.toList();
    final any = chosen.isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: d.line),
      ),
      child: Row(
        children: [
          DeskButton(
            '${all ? '取消全选' : '全选'}（$picked/${ids.length}）',
            key: const ValueKey('booksource-select-all'),
            quiet: true,
            onPressed: ids.isEmpty
                ? null
                : () => update(() {
                    if (all) {
                      selectedSources.removeAll(ids);
                    } else {
                      selectedSources.addAll(ids);
                    }
                  }),
          ),
          DeskButton(
            '反选',
            key: const ValueKey('booksource-select-invert'),
            quiet: true,
            onPressed: ids.isEmpty
                ? null
                : () => update(() {
                    for (final id in ids) {
                      if (!selectedSources.remove(id)) selectedSources.add(id);
                    }
                  }),
          ),
          if (selectedSources.length > picked)
            DeskText(
              '（另有 ${selectedSources.length - picked} 个不在当前筛选中）',
              size: 12,
              color: d.ink2,
            ),
          const Spacer(),
          DeskButton(
            '启用',
            key: const ValueKey('booksource-enable-selected'),
            quiet: true,
            onPressed: !any
                ? null
                : () => _sourceAction('sources.setEnabledMany', {
                    'ids': chosen,
                    'enabled': true,
                  }),
          ),
          DeskButton(
            '停用',
            key: const ValueKey('booksource-disable-selected'),
            quiet: true,
            onPressed: !any
                ? null
                : () => _sourceAction('sources.setEnabledMany', {
                    'ids': chosen,
                    'enabled': false,
                  }),
          ),
          DeskButton(
            '删除',
            key: const ValueKey('booksource-remove-selected'),
            quiet: true,
            onPressed: !any ? null : () => _removeSources(chosen),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('booksource-more'),
            enabled: any,
            tooltip: '更多操作',
            onSelected: (v) async {
              switch (v) {
                case 'top':
                  await _pin(chosen);
                case 'bottom':
                  await _pin(chosen, bottom: true);
                case 'group':
                  final group = await _askText('修改分组', hint: '多个分组用逗号分隔');
                  if (group != null) {
                    await _sourceAction('sources.setGroup', {
                      'ids': chosen,
                      'group': group,
                    });
                  }
                case 'ping':
                  if (!pinging) await _probe(true, chosen);
                case 'check':
                  if (!checking) await _probe(false, chosen);
                case 'export':
                  if (!await _ensureFolder()) return;
                  final path =
                      '${settings.folder}${Platform.pathSeparator}书源导出-${DateTime.now().millisecondsSinceEpoch}.json';
                  await _sourceAction('sources.export', {
                    'ids': chosen,
                    'path': path,
                  }, message: '已导出：$path');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'top', child: Text('置顶')),
              PopupMenuItem(value: 'bottom', child: Text('置底')),
              PopupMenuItem(value: 'group', child: Text('改分组…')),
              PopupMenuItem(value: 'ping', child: Text('测速')),
              PopupMenuItem(value: 'check', child: Text('校验')),
              PopupMenuItem(value: 'export', child: Text('导出 JSON')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: DeskText('更多 ▾', size: 13, color: any ? d.ink : d.ink3),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceRow(Map<String, dynamic> s, String group) {
    final d = context.desk;
    final check = s['check'] as Map?, health = s['health'] as Map?;
    final ping = s['ping'] as Map?;
    final stage = const {
      'engine': '引擎',
      'search': '搜索',
      'detail': '详情',
      'toc': '目录',
      'content': '正文',
    }[check?['stage']];
    final ms = (check?['ms'] as num?)?.toInt();
    final reasons = List<String>.from(s['reasons'] as List? ?? []);
    final tone = check?['ok'] == false
        ? Tone.pen
        : ms == null
        ? Tone.info
        : ms < 1500
        ? Tone.ok
        : ms < 4000
        ? Tone.warn
        : Tone.pen;
    final tile = ListTile(
      key: ValueKey('booksource-source-$group-${s['id']}'),
      dense: true,
      leading: Checkbox(
        key: ValueKey('booksource-source-select-${s['id']}'),
        value: selectedSources.contains('${s['id']}'),
        onChanged: (v) => update(() {
          if (v == true) {
            selectedSources.add('${s['id']}');
          } else {
            selectedSources.remove('${s['id']}');
          }
        }),
      ),
      title: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (s['pinned'] == true)
            const Tooltip(
              message: '已置顶',
              child: Icon(Icons.push_pin, size: 16),
            ),
          DeskText('${s['name']}', bold: true, lines: 1),
          for (final tag in s['tags'] as List? ?? [])
            DeskTag('$tag', Tone.info),
          if (s['supported'] != true)
            const DeskTag('不能用', Tone.warn)
          else if (s['webView'] == true)
            const DeskTag('网页', Tone.info),
          if (s['duplicate'] == true) const DeskTag('重复', Tone.warn),
          if (s['updated'] == true) const DeskTag('已更新', Tone.accent),
          if (check != null)
            Tooltip(
              message:
                  '最近 20 次：${(health?['ms'] as List? ?? []).join(' / ')} ms',
              child: DeskTag(
                check['ok'] == true ? '可用 ${ms ?? 0}ms' : '未通过校验',
                tone,
              ),
            ),
          if (ping != null)
            DeskTag(
              ping['ok'] == true ? '可连接 ${ping['ms']}ms' : '连接失败',
              ping['ok'] == true ? Tone.info : Tone.warn,
            ),
        ],
      ),
      subtitle: DeskText(
        [
          if (reasons.isNotEmpty) reasons.join('；') else '${s['group'] ?? ''}',
          if (check?['ok'] == false)
            '校验${stage == null ? '' : '（$stage）'}：${check?['error'] ?? ''}${_sourceCauses.containsKey(s['cause'] ?? check?['cause']) ? ' · ${_sourceCauses[s['cause'] ?? check?['cause']]}' : ''}',
          if (check?['ok'] == true && check?['chars'] != null)
            '目录 ${check?['chapters']} 章，抽查正文 ${check?['chars']} 字',
          if (health?['lastError'] != null &&
              '${health?['lastError']}'.isNotEmpty)
            '${health?['lastError']}',
        ].where((t) => t.isNotEmpty).join(' · '),
        size: 12,
        color: d.ink2,
        lines: 2,
      ),
      onTap: () => _sourceDetail(s),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: ValueKey('booksource-pin-${s['id']}'),
            tooltip: s['pinned'] == true ? '取消置顶' : '置顶书源',
            icon: Icon(
              s['pinned'] == true ? Icons.push_pin : Icons.push_pin_outlined,
              size: 18,
            ),
            onPressed: () => _pin(['${s['id']}'], pinned: s['pinned'] != true),
          ),
          IconButton(
            tooltip: '置底书源',
            icon: const Icon(Icons.vertical_align_bottom, size: 18),
            onPressed: () => _pin(['${s['id']}'], bottom: true),
          ),
          if (s['login'] == true && s['supported'] == true)
            DeskButton(
              '登录',
              key: ValueKey('booksource-login-${s['id']}'),
              quiet: true,
              onPressed: () => _login(context, s),
            ),
          Switch(
            value: s['enabled'] == true,
            onChanged: s['supported'] != true
                ? null
                : (v) => _sourceAction('sources.setEnabled', {
                    'ids': [s['id']],
                    'enabled': v,
                  }),
          ),
          IconButton(
            tooltip: '删除书源',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => _removeSources(['${s['id']}']),
          ),
        ],
      ),
    );
    // 每个书源一张圆角卡片，选中时换底色（参考轻悦时光的书源列表）。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selectedSources.contains('${s['id']}')
            ? d.accentSoft
            : d.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: d.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: tile,
      ),
    );
  }
}

List<String> _sourceGroups(Map source) => source['groups'] is List
    ? List<String>.from(source['groups'] as List)
    : '${source['group'] ?? ''}'
          .split(RegExp('[,;，]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
String _sourceFileName(String path) => path.split(RegExp(r'[/\\]')).last;
