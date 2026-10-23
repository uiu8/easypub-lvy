part of '../booksource_page.dart';

// 书源页三栏（R1c，用户确认的预览）：左“文件 → 分组”树（筛选列表），中书源列表（文件下再按分组分节），
// 右检查面板（选中书源的耗时曲线、校验结果与操作）。窄时先收起检查面板，再收起树。

extension _SourcePanes on _BookSourcePageState {
  /// 书源所在的分组（列表分节与树都用第一个分组；没有时为“未分组”）。
  String _primaryGroup(Map<String, dynamic> s) {
    final groups = _sourceGroups(s);
    return groups.isEmpty ? '未分组' : groups.first;
  }

  String _sourceFile(Map<String, dynamic> s) => '${s['file'] ?? '旧版导入'}';

  /// 树的节点：'' 全部；'f:文件'；'f:文件\ng:分组'；'g:分组'（按分组时）。
  bool _inSourceNode(Map<String, dynamic> s) {
    final node = sourceNode;
    if (node.isEmpty) return true;
    if (node == 'fav') return _isFavorite('${s['id']}');
    if (node.startsWith('g:')) {
      return _sourceGroups(s).contains(node.substring(2)) ||
          (node == 'g:未分组' && _sourceGroups(s).isEmpty);
    }
    final parts = node.split('\n');
    if (_sourceFile(s) != parts.first.substring(2)) return false;
    return parts.length < 2 || _primaryGroup(s) == parts[1].substring(2);
  }

  Widget _sourcesTab(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final tree = box.maxWidth >= 760;
      final inspector = box.maxWidth >= 1080;
      sourceInspectorShown = inspector;
      final d = context.desk;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tree)
            Container(
              width: 220,
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: d.line)),
              ),
              child: _sourceTree(context),
            ),
          Expanded(child: _sourceList(context, withSearch: !tree)),
          if (inspector)
            Container(
              width: 280,
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: d.line)),
              ),
              child: _sourceInspector(context),
            ),
        ],
      );
    },
  );

  Widget _sourceTree(BuildContext context) {
    final d = context.desk;
    final shown = _shownSources();
    Widget node(
      String id,
      String label,
      int count, {
      IconData? icon,
      int depth = 0,
      Widget? leading,
      bool muted = false,
    }) {
      final on = sourceNode == id;
      return Padding(
        padding: const EdgeInsets.only(bottom: 1),
        child: Material(
          color: on ? d.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('booksource-node-$id'),
            onTap: () => update(() => sourceNode = id),
            child: Padding(
              padding: EdgeInsets.fromLTRB(6.0 + depth * 18, 6, 8, 6),
              child: Row(
                children: [
                  ?leading,
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: on ? d.accent : d.ink2),
                    const SizedBox(width: 7),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ui(
                        12.5,
                        w: on || depth == 0 ? 600 : 450,
                        c: muted ? d.ink3 : d.ink,
                      ),
                    ),
                  ),
                  Text('$count', style: mono(11, c: d.ink3)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final rows = <Widget>[
      node('', '全部书源', shown.length, icon: Icons.all_inclusive_rounded),
      if (settings.favoriteSources.isNotEmpty)
        node(
          'fav',
          '收藏',
          shown.where((s) => _isFavorite('${s['id']}')).length,
          icon: Icons.star_rounded,
        ),
      const SizedBox(height: 6),
    ];
    if (settings.groupBy == 'file') {
      final files = <String, List<Map<String, dynamic>>>{};
      for (final s in shown) {
        (files[_sourceFile(s)] ??= []).add(s);
      }
      for (final file in files.entries) {
        final open = treeOpen.contains(file.key);
        rows.add(
          node(
            'f:${file.key}',
            _sourceFileName(file.key),
            file.value.length,
            icon: file.key.startsWith('http')
                ? Icons.cloud_outlined
                : file.key == '旧版导入'
                ? Icons.history_rounded
                : Icons.description_outlined,
            leading: InkWell(
              key: ValueKey('booksource-tree-toggle-${file.key}'),
              onTap: () => update(() {
                if (!treeOpen.remove(file.key)) treeOpen.add(file.key);
              }),
              child: Icon(
                open ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                size: 16,
                color: d.ink3,
              ),
            ),
          ),
        );
        if (open) {
          final groups = <String, int>{};
          for (final s in file.value) {
            groups.update(_primaryGroup(s), (n) => n + 1, ifAbsent: () => 1);
          }
          final names = groups.keys.toList()
            ..sort(
              (a, b) => a == '未分组'
                  ? 1
                  : b == '未分组'
                  ? -1
                  : a.compareTo(b),
            );
          for (final g in names) {
            rows.add(
              node(
                'f:${file.key}\ng:$g',
                g,
                groups[g]!,
                depth: 1,
                muted: g == '未分组',
              ),
            );
          }
        }
      }
    } else {
      final groups = <String, int>{};
      for (final s in shown) {
        final names = _sourceGroups(s);
        for (final g in names.isEmpty ? ['未分组'] : names) {
          groups.update(g, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      for (final g in groups.entries) {
        rows.add(
          node(
            'g:${g.key}',
            g.key,
            g.value,
            icon: Icons.label_outline_rounded,
            muted: g.key == '未分组',
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
          child: _sourceSearchField(),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            children: rows,
          ),
        ),
      ],
    );
  }

  Widget _sourceSearchField() => TextField(
    key: const ValueKey('booksource-filter'),
    controller: sourceFilter,
    decoration: const InputDecoration(
      hintText: '搜索书源',
      isDense: true,
      prefixIcon: Icon(Icons.search, size: 18),
      prefixIconConstraints: BoxConstraints(minWidth: 36, minHeight: 20),
    ),
    onChanged: (_) => update(() {}),
  );

  /// 子分组标题（按来源文件分组时，文件下再按书源自己的分组分节）。
  Widget _subgroupHeader(
    String file,
    String group,
    List<Map<String, dynamic>> items,
  ) {
    final d = context.desk;
    final collapsedKey = 'file:$file/$group';
    final collapsed = settings.collapsed.contains(collapsedKey);
    final ids = items.map((s) => '${s['id']}').toList();
    final ok = items.where((s) => (s['check'] as Map?)?['ok'] == true).length;
    final failed = items
        .where((s) => (s['check'] as Map?)?['ok'] == false)
        .length;
    return Padding(
      key: ValueKey('booksource-subgroup-$file/$group'),
      padding: const EdgeInsets.fromLTRB(26, 4, 0, 2),
      child: Row(
        children: [
          InkWell(
            key: ValueKey('booksource-collapse-$file/$group'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => _saveSettings(() {
              if (collapsed) {
                settings.collapsed.remove(collapsedKey);
              } else {
                settings.collapsed.add(collapsedKey);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 17,
                    color: d.ink2,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.label_outline_rounded, size: 14, color: d.ink3),
                  const SizedBox(width: 5),
                  Text(
                    group,
                    style: ui(12.5, w: 600, c: group == '未分组' ? d.ink3 : d.ink),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${items.length} 个 · 可用 $ok · 未通过 $failed',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ui(11.5, c: d.ink3),
            ),
          ),
          DeskMenuButton<VoidCallback>(
            key: ValueKey('booksource-subgroup-menu-$file/$group'),
            tooltip: '这个分组的操作',
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (f) => f(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: () => _sourceAction('sources.setEnabledMany', {
                  'ids': ids,
                  'enabled': true,
                }),
                child: const Text('全部启用'),
              ),
              PopupMenuItem(
                value: () => _sourceAction('sources.setEnabledMany', {
                  'ids': ids,
                  'enabled': false,
                }),
                child: const Text('全部停用'),
              ),
              PopupMenuItem(
                enabled: !pinging,
                value: () => _probe(true, ids),
                child: const Text('测速这个分组'),
              ),
              PopupMenuItem(
                enabled: !checking,
                value: () => _probe(false, ids),
                child: const Text('校验这个分组'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 列表分节：按来源文件时，文件下再按分组分节（只有一个分组且是“未分组”时不再分节）。
  List<Widget> _sourceRows(List<Map<String, dynamic>> shown) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final source in shown) {
      final keys = settings.groupBy == 'file'
          ? [_sourceFile(source)]
          : _sourceGroups(source);
      for (final key in keys.isEmpty ? ['未分组'] : keys) {
        (groups[key] ??= []).add(source);
      }
    }
    final rows = <Widget>[];
    for (final entry in groups.entries) {
      rows.add(_groupHeader(entry.key, entry.value));
      if (settings.collapsed.contains('${settings.groupBy}:${entry.key}')) {
        continue;
      }
      if (settings.groupBy != 'file') {
        for (final source in entry.value) {
          rows.add(_dragSourceRow(source, entry.key));
        }
        continue;
      }
      final sub = <String, List<Map<String, dynamic>>>{};
      for (final source in entry.value) {
        (sub[_primaryGroup(source)] ??= []).add(source);
      }
      if (sub.length == 1 && sub.keys.single == '未分组') {
        for (final source in entry.value) {
          rows.add(_dragSourceRow(source, entry.key));
        }
        continue;
      }
      final names = sub.keys.toList()
        ..sort(
          (a, b) => a == '未分组'
              ? 1
              : b == '未分组'
              ? -1
              : 0,
        );
      for (final g in names) {
        rows.add(_subgroupHeader(entry.key, g, sub[g]!));
        if (settings.collapsed.contains('file:${entry.key}/$g')) continue;
        for (final source in sub[g]!) {
          rows.add(_dragSourceRow(source, entry.key));
        }
      }
    }
    return rows;
  }

  Widget _sourceInspector(BuildContext context) {
    final d = context.desk;
    final s = sources.where((x) => '${x['id']}' == focusedSource).firstOrNull;
    if (s == null) {
      final shown = _shownSources().where(_inSourceNode).toList();
      final ok = shown.where((x) => (x['check'] as Map?)?['ok'] == true).length;
      final failed = shown
          .where((x) => (x['check'] as Map?)?['ok'] == false)
          .length;
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('当前范围', style: ui(12, w: 600, c: d.ink3)),
            const SizedBox(height: 10),
            Row(
              children: [
                _stat('书源', '${shown.length}'),
                const SizedBox(width: 8),
                _stat('可用', '$ok', tone: d.add),
                const SizedBox(width: 8),
                _stat('未通过', '$failed', tone: d.pen),
              ],
            ),
            const SizedBox(height: 18),
            Icon(Icons.touch_app_outlined, size: 22, color: d.ink3),
            const SizedBox(height: 6),
            Text(
              '点列表里的书源，在这里看耗时、校验结果和操作。',
              textAlign: TextAlign.center,
              style: ui(12.5, c: d.ink2, h: 1.6),
            ),
          ],
        ),
      );
    }
    final id = '${s['id']}';
    final check = s['check'] as Map?, ping = s['ping'] as Map?;
    final health = s['health'] as Map?;
    final samples = [
      for (final v in health?['ms'] as List? ?? const []) (v as num).toDouble(),
    ];
    final last = (check?['ms'] ?? ping?['ms']) as num?;
    final failed = check?['ok'] == false;
    // 静态告警在“最近一次校验”里写成兼容提示，这里不再当成问题列出（V102 A）。
    final warnings = List<String>.from(s['staticWarnings'] as List? ?? []);
    final reasons = List<String>.from(s['reasons'] as List? ?? [])
        .where((r) => s['supported'] != true || !warnings.contains(r))
        .toList();
    String when(num? at) {
      if (at == null || at == 0) return '';
      final t = DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000);
      String two(int v) => v.toString().padLeft(2, '0');
      return '${t.month}月${t.day}日 ${two(t.hour)}:${two(t.minute)}';
    }

    return ListView(
      key: ValueKey('booksource-inspector-$id'),
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            if (s['pinned'] == true) ...[
              Icon(Icons.push_pin, size: 15, color: d.ink2),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                '${s['name']}',
                style: ui(15, w: 650, c: d.ink),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Switch(
              value: s['enabled'] == true,
              onChanged: s['supported'] != true
                  ? null
                  : (v) => _sourceAction('sources.setEnabled', {
                      'ids': [id],
                      'enabled': v,
                    }),
            ),
          ],
        ),
        Row(
          children: [
            Icon(Icons.label_outline_rounded, size: 14, color: d.ink3),
            const SizedBox(width: 5),
            Text(_primaryGroup(s), style: ui(12, c: d.ink2)),
          ],
        ),
        const SizedBox(height: 2),
        Tooltip(
          message: _sourceFile(s),
          child: Row(
            children: [
              Icon(Icons.description_outlined, size: 14, color: d.ink3),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  _sourceFileName(_sourceFile(s)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui(12, c: d.ink2),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            _stat(
              '最近耗时',
              last == null ? '—' : '${(last / 1000).toStringAsFixed(2)}s',
            ),
            const SizedBox(width: 8),
            _stat(
              '校验',
              failed
                  ? '未通过'
                  : check?['ok'] == true
                  ? '通过'
                  : '未测',
              tone: failed
                  ? d.pen
                  : check?['ok'] == true
                  ? d.add
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          samples.length < 2 ? '耗时曲线（测速两次以上才有）' : '最近 ${samples.length} 次耗时',
          style: ui(11.5, c: d.ink3),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 44,
          child: samples.length < 2
              ? Container(
                  decoration: BoxDecoration(
                    color: d.sunken,
                    borderRadius: BorderRadius.circular(6),
                  ),
                )
              : CustomPaint(
                  key: const ValueKey('booksource-inspector-spark'),
                  painter: _SparkPainter(samples, failed ? d.pen : d.add),
                ),
        ),
        if (samples.length >= 2)
          Text(
            '最快 ${(samples.reduce(math.min) / 1000).toStringAsFixed(2)}s · 最慢 ${(samples.reduce(math.max) / 1000).toStringAsFixed(2)}s',
            style: ui(11.5, c: d.ink3),
          ),
        if (failed || reasons.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: failed ? d.pen.withValues(alpha: .07) : d.sunken,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (failed)
                  Text(
                    '校验没通过：${_checkReason(check).isEmpty ? '原因未知' : _checkReason(check)}',
                    style: ui(12, c: d.pen, h: 1.5),
                  ),
                for (final r in reasons)
                  Text(r, style: ui(12, c: d.ink2, h: 1.5)),
              ],
            ),
          ),
        ],
        _lastCheck(s),
        if (when(check?['at'] as num?) case final at when at.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('上次校验：$at', style: ui(11.5, c: d.ink3)),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DeskButton(
                '测速',
                key: ValueKey('booksource-inspector-ping-$id'),
                icon: Icons.speed_rounded,
                onPressed: pinging ? null : () => _probe(true, [id]),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DeskButton(
                '校验',
                key: ValueKey('booksource-inspector-check-$id'),
                icon: Icons.fact_check_outlined,
                onPressed: checking ? null : () => _probe(false, [id]),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (s['login'] == true && s['supported'] == true) ...[
          DeskButton(
            '登录…',
            icon: Icons.login_rounded,
            onPressed: () => _login(context, s),
          ),
          const SizedBox(height: 8),
        ],
        DeskButton(
          '详情、评分与下载参数…',
          key: ValueKey('booksource-inspector-detail-$id'),
          quiet: true,
          onPressed: () => _sourceDetail(s),
        ),
      ],
    );
  }

  Widget _stat(String label, String value, {Color? tone}) {
    final d = context.desk;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: d.sunken,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: ui(11, c: d.ink3)),
            const SizedBox(height: 2),
            Text(value, style: ui(15, w: 650, c: tone ?? d.ink)),
          ],
        ),
      ),
    );
  }
}

/// 小折线（耗时、速度）：按最小到最大归一，留出上下边距。
class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);
  final List<double> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final span = hi - lo == 0 ? 1 : hi - lo;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = 4 + (size.height - 8) * (1 - (values[i] - lo) / span);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.color != color || old.values.join() != values.join();
}
