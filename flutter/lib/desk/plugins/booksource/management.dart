part of '../booksource_page.dart';

extension _BookSourceManagement on _BookSourcePageState {
  Future<void> _pin(
    List<String> ids, {
    bool bottom = false,
    bool pinned = true,
  }) => _sourceAction('sources.pin', {
    'ids': ids,
    'pinned': pinned,
    if (bottom) 'position': 'bottom',
  });

  Future<void> _moveSource(String id, String before) async {
    final ordered = [
      ...sources,
    ]..sort((a, b) => _num(a['customOrder']).compareTo(_num(b['customOrder'])));
    final ids = ordered.map((s) => '${s['id']}').toList()..remove(id);
    final index = ids.indexOf(before);
    ids.insert(index < 0 ? ids.length : index, id);
    await _sourceAction('sources.order', {'ids': ids}, message: '书源顺序已保存。');
  }

  Widget _dragSourceRow(Map<String, dynamic> source, String group) =>
      DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != source['id'],
        onAcceptWithDetails: (d) => _moveSource(d.data, '${source['id']}'),
        builder: (context, candidates, rejected) => DecoratedBox(
          decoration: BoxDecoration(
            border: candidates.isEmpty
                ? null
                : Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
          ),
          child: Draggable<String>(
            key: ValueKey('booksource-drag-${source['id']}-$group'),
            data: '${source['id']}',
            feedback: Material(
              elevation: 4,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('${source['name']}'),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: .35,
              child: _sourceRow(source, group),
            ),
            child: _sourceRow(source, group),
          ),
        ),
      );

  Widget _sourceFilters() => Wrap(
    spacing: 6,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final tag in [
        '可用',
        '慢',
        '限流',
        '需验证',
        '需登录',
        '需代理',
        '无搜索',
        '失效',
        'WebView',
        'JS',
        '批量',
      ])
        FilterChip(
          label: Text(tag),
          selected: sourceTags.contains(tag),
          onSelected: (v) => update(() {
            if (v) {
              sourceTags.add(tag);
            } else {
              sourceTags.remove(tag);
            }
          }),
        ),
      FilterChip(
        key: const ValueKey('booksource-recommended'),
        label: const Text('推荐下载源'),
        selected: recommendedOnly,
        onSelected: (v) => update(() => recommendedOnly = v),
      ),
      DeskButton(
        '保存筛选',
        key: const ValueKey('booksource-filter-save'),
        quiet: true,
        onPressed: () async {
          final name = await _askText('保存筛选组合');
          if (name == null || name.isEmpty) return;
          await api!.call('filters.save', {
            'name': name,
            'filter': {
              'tags': sourceTags.toList(),
              'recommended': recommendedOnly,
              'status': sourceStatusFilter,
              'text': sourceFilter.text,
            },
          });
          update(() => sourceMessage = '筛选组合“$name”已保存。');
        },
      ),
      DeskButton(
        '已存筛选',
        quiet: true,
        onPressed: () async {
          final filters = await api!.call('filters.list') as List;
          if (!mounted) return;
          final picked = await showDialog<Map>(
            context: context,
            builder: (dialog) => DeskAlert(
              title: const Text('筛选组合'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (filters.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(18),
                      child: Text('还没有保存筛选组合。'),
                    ),
                  for (final raw in filters)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(dialog, raw as Map),
                      child: Text('${raw['name']}'),
                    ),
                ],
              ),
              actions: [
                DeskButton(
                  '关闭',
                  quiet: true,
                  onPressed: () => Navigator.pop(dialog),
                ),
              ],
            ),
          );
          if (picked != null) {
            update(() {
              final f = picked['filter'] as Map;
              sourceTags
                ..clear()
                ..addAll(List<String>.from(f['tags'] as List? ?? []));
              recommendedOnly = f['recommended'] == true;
              sourceStatusFilter = '${f['status'] ?? 'all'}';
              sourceFilter.text = '${f['text'] ?? ''}';
            });
          }
        },
      ),
    ],
  );

  Future<void> _editSource(Map source, Map detail) async {
    final p = Map<String, dynamic>.from(detail['crawl'] as Map? ?? {});
    final fields = <String, TextEditingController>{
      for (final (key, _) in _crawlFields)
        key: TextEditingController(text: '${p[key] ?? ''}'),
      'group': TextEditingController(
        text: '${detail['group'] ?? source['group'] ?? ''}',
      ),
      'concurrentRate': TextEditingController(
        text: '${detail['concurrentRate'] ?? ''}',
      ),
      'userAgent': TextEditingController(text: _sourceUa(detail)),
      'phrases': TextEditingController(
        text: (p['throttlePhrases'] as List? ?? []).join('\n'),
      ),
    };
    bool enabled = source['enabled'] == true;
    String proxyMode = '${p['proxyMode'] ?? ''}';
    if (proxyMode.isEmpty && p['useProxy'] == true) proxyMode = 'proxy';
    int rating = _num(source['rating']).toInt().clamp(-2, 2);
    String? error;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => DeskControllerScope(
        controllers: fields.values,
        child: StatefulBuilder(
          builder: (dialog, change) => DeskAlert(
            title: Text('下载参数 · ${source['name']}'),
            content: SizedBox(
              width: 600,
              height: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _toggle(
                          '启用书源',
                          enabled,
                          (v) => change(() => enabled = v),
                        ),
                        DeskChoice<String>(
                          isExpanded: false,
                          value: proxyMode,
                          items: const [
                            DropdownMenuItem(
                              value: '',
                              child: Text('跟随全局网络设置'),
                            ),
                            DropdownMenuItem(
                              value: 'direct',
                              child: Text('此书源始终直连'),
                            ),
                            DropdownMenuItem(
                              value: 'proxy',
                              child: Text('此书源使用配置的代理'),
                            ),
                          ],
                          onChanged: (v) => change(() => proxyMode = v!),
                        ),
                        DeskChoice<int>(
                          key: const ValueKey('booksource-rating'),
                          isExpanded: false,
                          value: rating,
                          items: [
                            for (var n = -2; n <= 2; n++)
                              DropdownMenuItem(value: n, child: Text('评分 $n')),
                          ],
                          onChanged: (v) => change(() => rating = v ?? 0),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final (key, label) in _crawlFields)
                          SizedBox(
                            width: 260,
                            child: TextField(
                              key: ValueKey('booksource-profile-$key'),
                              controller: fields[key],
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: label,
                                hintText: '留空使用默认值',
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      children: [
                        if (detail['suggestion'] is Map)
                          DeskButton(
                            '应用导入建议',
                            quiet: true,
                            onPressed: () => change(() {
                              final suggestion = detail['suggestion'] as Map;
                              for (final (key, _) in _crawlFields) {
                                if (suggestion[key] != null) {
                                  fields[key]!.text = '${suggestion[key]}';
                                }
                              }
                            }),
                          ),
                        if (_num((detail['learned'] as Map?)?['safeLimit']) > 0)
                          DeskButton(
                            '应用建议并发 ${detail['learned']['safeLimit']}',
                            quiet: true,
                            onPressed: () => change(
                              () => fields['concurrency']!.text =
                                  '${detail['learned']['safeLimit']}',
                            ),
                          ),
                      ],
                    ),
                    TextField(
                      controller: fields['group'],
                      decoration: const InputDecoration(labelText: '分组（逗号分隔）'),
                    ),
                    TextField(
                      controller: fields['concurrentRate'],
                      decoration: const InputDecoration(
                        labelText: '访问频率',
                        hintText: '毫秒，或 次数/毫秒',
                      ),
                    ),
                    TextField(
                      controller: fields['userAgent'],
                      decoration: const InputDecoration(
                        labelText: 'User-Agent',
                      ),
                    ),
                    TextField(
                      controller: fields['phrases'],
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: '追加限流提示词（每行一条）',
                      ),
                    ),
                    if (error != null) DeskNote(error!, tone: Tone.warn),
                  ],
                ),
              ),
            ),
            actions: [
              DeskButton(
                '取消',
                quiet: true,
                onPressed: () => Navigator.pop(dialog, false),
              ),
              DeskButton(
                '保存',
                key: const ValueKey('booksource-profile-save'),
                primary: true,
                onPressed: () {
                  for (final (key, _) in _crawlFields) {
                    final text = fields[key]!.text.trim();
                    if (text.isNotEmpty &&
                        (int.tryParse(text) == null || int.parse(text) < 0)) {
                      change(() => error = '下载参数请输入非负整数。');
                      return;
                    }
                  }
                  final min = int.tryParse(fields['minInterval']!.text) ?? 0,
                      max = int.tryParse(fields['maxInterval']!.text) ?? 0;
                  if (max < min) {
                    change(() => error = '最大间隔不能小于最小间隔。');
                    return;
                  }
                  Navigator.pop(dialog, true);
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (accepted == true) {
      final profile = <String, dynamic>{
        for (final (key, _) in _crawlFields)
          key: int.tryParse(fields[key]!.text),
        'useProxy': proxyMode == 'proxy',
        'proxyMode': proxyMode,
        'throttlePhrases': fields['phrases']!.text
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
      };
      profile['minInterval'] ??= 0;
      profile['maxInterval'] ??= 0;
      await _sourceAction('sources.crawlProfile.set', {
        'id': source['id'],
        'profile': profile,
        'enabled': enabled,
        'group': fields['group']!.text,
        'concurrentRate': fields['concurrentRate']!.text,
        'userAgent': fields['userAgent']!.text,
      });
      await _sourceAction('sources.rate', {
        'id': source['id'],
        'rating': rating,
      }, message: '书源参数与评分已保存。');
    }
  }

  Future<void> _proxyDialog() async {
    try {
      final config = await api!.call('network.proxy.get') as Map;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _NetworkDialog(api!, config),
      );
    } catch (e) {
      if (mounted) update(() => sourceMessage = bookSourceErrorText(e));
    }
  }

  Future<void> _diagnose(DownloadTask task) async {
    final live = await api!.call('download.diagnose') as Map;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => DeskAlert(
        title: Text('下载诊断 · ${task.title}'),
        content: SizedBox(
          width: 740,
          height: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final h in live['hosts'] as List? ?? [])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DeskText(
                      '${h['host']} · 并发 ${h['active']}/${h['limit']} · 间隔 ${h['interval']} ms · 冷却 ${(_num(h['cooldownMs']) / 1000).ceil()} 秒\n'
                      '疑似桩页 ${h['stubCount']} · HTTP 限流 ${h['httpLimited']} · 平均网络 ${h['networkMs']} ms',
                      size: 12,
                    ),
                  ),
                const Divider(),
                const DeskText('章节状态与耗时', bold: true),
                for (final c in task.chapters)
                  DeskText(
                    '第 ${c['index']} 章 · ${c['status']} · 尝试 ${c['attempts']} 次 · ${c['error'] ?? ''}\n'
                    '排队 ${c['timing']?['queue'] ?? 0} / 网络 ${c['timing']?['net'] ?? 0} / 解析 ${c['timing']?['parse'] ?? 0} / 保存 ${c['timing']?['store'] ?? 0} ms'
                    '${(c['action'] ?? '') == '' ? '' : '\n${c['action']}'}',
                    size: 12,
                  ),
              ],
            ),
          ),
        ),
        actions: [DeskButton('关闭', onPressed: () => Navigator.pop(dialog))],
      ),
    );
  }

  Future<void> _provenance(Map record) async {
    final items =
        await api!.call('library.provenance', {'key': record['key']}) as List;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => DeskAlert(
        title: const Text('章节来源'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: ListView(
            children: [
              if (items.isEmpty) const Text('旧缓存没有记录章节来源。'),
              for (final item in items)
                ListTile(
                  dense: true,
                  title: Text('第 ${item['index']} 章 · ${item['chars']} 字'),
                  subtitle: SelectableText('${item['source']}\n${item['url']}'),
                ),
            ],
          ),
        ),
        actions: [DeskButton('关闭', onPressed: () => Navigator.pop(dialog))],
      ),
    );
  }
}

const _crawlFields = [
  ('concurrency', '并发上限（1–32）'),
  ('minInterval', '最小间隔（毫秒）'),
  ('maxInterval', '最大间隔（毫秒）'),
  ('retries', '重试次数（0–3）'),
  ('timeoutMs', '正文超时（毫秒，最多 180000）'),
];
num _num(dynamic value) => value is num ? value : 0;
String _sourceUa(Map detail) {
  try {
    return '${(jsonDecode('${detail['header']}') as Map)['User-Agent'] ?? ''}';
  } catch (_) {
    return '';
  }
}

class _LatencyChart extends StatelessWidget {
  const _LatencyChart(this.values);
  final List values;
  @override
  Widget build(BuildContext context) {
    final maximum = values.map(_num).fold<num>(1, (a, b) => a > b ? a : b);
    return Semantics(
      label: '最近 ${values.length} 次请求耗时，单位毫秒',
      child: SizedBox(
        height: 64,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final v in values)
              Expanded(
                child: Tooltip(
                  message: '$v ms',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.primary,
                      child: SizedBox(
                        height: (_num(v) / maximum * 56)
                            .clamp(2, 56)
                            .toDouble(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
