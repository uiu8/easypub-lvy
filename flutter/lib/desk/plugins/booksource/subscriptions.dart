part of '../booksource_page.dart';

const _sourceCauses = {
  'unsupported': '插件不支持',
  'rule': '规则问题',
  'site': '站点问题',
  'network': '网络问题',
  'verification': '登录或验证',
};

extension _BookSourceSubscriptions on _BookSourcePageState {
  Future<void> _failureCauses(List failures) async {
    String selected = '';
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, change) {
          final rows = failures
              .where((r) => selected.isEmpty || r['cause'] == selected)
              .toList();
          return AlertDialog(
            title: const Text('下载问题分类'),
            content: SizedBox(
              width: 620,
              height: 400,
              child: Column(
                children: [
                  DropdownButton<String>(
                    value: selected,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部原因')),
                      for (final cause in _sourceCauses.entries)
                        DropdownMenuItem(
                          value: cause.key,
                          child: Text(
                            '${cause.value} · ${failures.where((r) => r['cause'] == cause.key).length}',
                          ),
                        ),
                    ],
                    onChanged: (value) => change(() => selected = value ?? ''),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final row in rows)
                          ListTile(
                            title: Text('${row['title'] ?? ''}'),
                            subtitle: Text(
                              '${_sourceCauses[row['cause']] ?? '未分类'} · ${row['reason'] ?? ''}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _subscriptionPreview(String url, [Map? ready]) async {
    update(() => sourceMessage = '正在检查订阅，取得差异后由你确认…');
    try {
      final result =
          ready ??
          await api!.call('subscriptions.preview', {'url': url}) as Map;
      if (!mounted) return;
      final preview = result['preview'] as Map?;
      if (preview == null) {
        update(() => sourceMessage = '规则没有变化。');
        return;
      }
      final diff = preview['diff'] as Map;
      bool busy = false;
      String? error;
      await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, change) => AlertDialog(
            title: const Text('确认订阅更新'),
            content: SizedBox(
              width: 650,
              height: 420,
              child: ListView(
                children: [
                  Text(url),
                  const SizedBox(height: 12),
                  const Text('应用时保留置顶、顺序、评分、启用、分组、下载与代理设置；校验变化的规则，必要时恢复旧规则。'),
                  for (final category in {
                    'added': '新增',
                    'removed': '删除',
                    'changed': '规则变化',
                  }.entries) ...[
                    const SizedBox(height: 12),
                    DeskText(
                      '${category.value} ${(diff[category.key] as List? ?? []).length} 项',
                      bold: true,
                    ),
                    for (final row in diff[category.key] as List? ?? [])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          '${row['name']}${row['fields'] is List ? ' · ${(row['fields'] as List).join('、')} 已变化' : ''}',
                        ),
                      ),
                  ],
                  if (diff['ignored'] is Map &&
                      ((diff['ignored']['duplicates'] ?? 0) > 0 ||
                          (diff['ignored']['unrecognized'] ?? 0) > 0))
                    DeskNote(
                      '忽略 ${diff['ignored']['unrecognized']} 条无法识别记录；同地址 ${diff['ignored']['duplicates']} 条重复记录沿用最后一条，请核对删除清单。',
                      tone: Tone.warn,
                    ),
                  if (error != null) DeskNote(error!, tone: Tone.warn),
                ],
              ),
            ),
            actions: [
              DeskButton(
                '稍后',
                quiet: true,
                onPressed: busy ? null : () => Navigator.pop(dialog),
              ),
              DeskButton(
                '应用并校验',
                key: const ValueKey('booksource-subscription-apply'),
                primary: true,
                busy: busy,
                onPressed: busy
                    ? null
                    : () async {
                        change(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          final applied = await api!.call(
                            'subscriptions.apply',
                            {'url': url, 'previewId': preview['id']},
                          ) as Map;
                          await _loadSources();
                          final reverted = applied['reverted'] as List? ?? [];
                          if (mounted) {
                            update(
                              () => sourceMessage = reverted.isEmpty
                                  ? '订阅已更新，原有个人设置保留。'
                                  : '已更新；${reverted.length} 个规则自动恢复旧版：${reverted.map((r) => r['name']).join('、')}',
                            );
                          }
                          if (dialog.mounted) Navigator.pop(dialog);
                        } catch (e) {
                          if (dialog.mounted) {
                            change(() {
                              busy = false;
                              error = '$e';
                            });
                          }
                        }
                      },
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) update(() => sourceMessage = '$e');
    }
  }

  Future<void> _subscriptions() async {
    try {
      final raw = await api!.call('subscriptions.list') as List;
      if (!mounted) return;
      final items = raw
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList();
      bool busy = false;
      String? message;
      await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, change) {
            Future<void> action(Future<void> Function() work) async {
              change(() {
                busy = true;
                message = null;
              });
              try {
                await work();
                final updated = await api!.call('subscriptions.list') as List;
                if (dialog.mounted) {
                  change(() {
                    items
                      ..clear()
                      ..addAll(
                        updated.map((s) => Map<String, dynamic>.from(s as Map)),
                      );
                  });
                }
              } catch (e) {
                if (dialog.mounted) change(() => message = '$e');
              } finally {
                if (dialog.mounted) change(() => busy = false);
              }
            }

            return AlertDialog(
              title: const Text('订阅与更新'),
              content: SizedBox(
                width: 720,
                height: 460,
                child: ListView(
                  children: [
                    const Text(
                      '网址导入会记录为订阅。自动检查默认关闭，只检查变化，应用前仍需确认。每份订阅保留最近 3 个版本。',
                    ),
                    if (items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('尚无订阅，请先从网址导入书源。'),
                      ),
                    for (final item in items)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${item['url']}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${item['count']} 个书源 · ${(item['versions'] as List? ?? []).length} 个版本',
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Checkbox(
                                      value: item['startup'] == true,
                                      onChanged: busy
                                          ? null
                                          : (v) => change(
                                              () => item['startup'] = v == true,
                                            ),
                                    ),
                                    const Text('启动时检查'),
                                  ],
                                ),
                                SizedBox(
                                  width: 125,
                                  child: TextFormField(
                                    key: ValueKey(
                                      'subscription-days-${item['url']}-${item['days']}',
                                    ),
                                    initialValue: '${item['days'] ?? 0}',
                                    enabled: !busy,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: '每 N 天（0 关闭）',
                                    ),
                                    onChanged: (v) => item['draftDays'] = v,
                                  ),
                                ),
                                DeskButton(
                                  '保存设置',
                                  quiet: true,
                                  onPressed: busy
                                      ? null
                                      : () => action(() async {
                                          final days = int.tryParse(
                                            '${item['draftDays'] ?? item['days'] ?? 0}',
                                          );
                                          if (days == null ||
                                              days < 0 ||
                                              days > 365) {
                                            throw '检查间隔请输入 0～365 天';
                                          }
                                          await api!.call(
                                            'subscriptions.configure',
                                            {
                                              'url': item['url'],
                                              'startup': item['startup'],
                                              'days': days,
                                            },
                                          );
                                        }),
                                ),
                                DeskButton(
                                  item['preview'] is Map ? '查看待更新' : '检查更新',
                                  quiet: true,
                                  onPressed: busy
                                      ? null
                                      : () => action(
                                          () => _subscriptionPreview(
                                            '${item['url']}',
                                            item['preview'] is Map
                                                ? item
                                                : null,
                                          ),
                                        ),
                                ),
                                DeskButton(
                                  '回退上一版',
                                  key: ValueKey(
                                    'subscription-rollback-${item['url']}',
                                  ),
                                  quiet: true,
                                  onPressed:
                                      busy ||
                                          (item['versions'] as List? ?? [])
                                                  .length <
                                              2
                                      ? null
                                      : () => action(() async {
                                          final accepted =
                                              await showDialog<bool>(
                                                context: dialog,
                                                builder: (confirm) =>
                                                    AlertDialog(
                                                      title: const Text(
                                                        '回退上一版规则？',
                                                      ),
                                                      content: const Text(
                                                        '恢复上一版本的书源规则，保留同地址书源当前的个人设置。',
                                                      ),
                                                      actions: [
                                                        DeskButton(
                                                          '取消',
                                                          quiet: true,
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                confirm,
                                                                false,
                                                              ),
                                                        ),
                                                        DeskButton(
                                                          '确认回退',
                                                          onPressed: () =>
                                                              Navigator.pop(
                                                                confirm,
                                                                true,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                              );
                                          if (accepted != true) return;
                                          await api!.call(
                                            'subscriptions.rollback',
                                            {'url': item['url']},
                                          );
                                          await _loadSources();
                                        }),
                                ),
                              ],
                            ),
                            if (item['error'] != null)
                              DeskNote('${item['error']}', tone: Tone.warn),
                          ],
                        ),
                      ),
                    if (message != null) DeskNote(message!, tone: Tone.warn),
                  ],
                ),
              ),
              actions: [
                DeskButton(
                  '关闭',
                  quiet: true,
                  onPressed: busy ? null : () => Navigator.pop(dialog),
                ),
              ],
            );
          },
        ),
      );
    } catch (e) {
      if (mounted) update(() => sourceMessage = '$e');
    }
  }

  Future<void> _unsupportedRanking() async {
    try {
      final result = await api!.call('sources.causes') as Map;
      if (!mounted) return;
      final rows = result['unsupported'] as List? ?? [];
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('不支持的写法排行'),
          content: SizedBox(
            width: 560,
            height: 360,
            child: ListView(
              children: [
                if (rows.isEmpty) const Text('暂无记录；导入和校验后会汇总具体写法。'),
                for (final row in rows)
                  ListTile(
                    title: Text('${row['name']}'),
                    trailing: Text('${row['count']} 个'),
                  ),
              ],
            ),
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
    } catch (e) {
      if (mounted) update(() => sourceMessage = '$e');
    }
  }
}
