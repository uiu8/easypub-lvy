part of '../booksource_page.dart';

extension _BookSourceSettingsView on _BookSourcePageState {
  void _saveSettings(VoidCallback action) {
    update(action);
    settings.save(widget.settingsPath);
  }

  /// 读插件端偏好；旧版插件没有这些接口时保持默认，不影响其他功能。
  Future<void> _loadPluginPreferences() async {
    try {
      final options = await api!.call('sources.importOptions.get');
      final auto = await api!.call('library.autoCheck.get');
      importOptions = Map<String, dynamic>.from(options as Map);
      autoCheckHours = ((auto as Map)['hours'] as num? ?? 0).toInt();
      autoCheckLast = (auto['lastChecked'] as num? ?? 0).toInt();
    } catch (_) {}
  }

  Future<void> _setImportOption(String key, Object value) async {
    final next = {...importOptions, key: value};
    try {
      final r = await api!.call('sources.importOptions.set', {'options': next});
      update(() => importOptions = Map<String, dynamic>.from(r as Map));
    } catch (e) {
      update(() => sourceMessage = '$e');
    }
  }

  Future<void> _setAutoCheck({int? hours, int? concurrency}) async {
    if (concurrency != null) {
      _saveSettings(() => settings.updateConcurrency = concurrency);
    }
    try {
      final r = await api!.call('library.autoCheck.set', {
        'hours': hours ?? autoCheckHours,
        'concurrency': settings.updateConcurrency,
      });
      update(() {
        autoCheckHours = ((r as Map)['hours'] as num).toInt();
        autoCheckLast = (r['lastChecked'] as num? ?? 0).toInt();
      });
    } catch (e) {
      update(() => shelfMessage = '$e');
    }
  }

  Future<bool> _ensureFolder() async {
    if (settings.folder.isNotEmpty) return true;
    final folder = await widget.chooseFolder();
    if (folder == null || !mounted) return false;
    _saveSettings(() => settings.folder = folder);
    return true;
  }

  /// 设置页（参考轻悦时光）：分组卡片，每行左边是名称和“?”说明，右边是控件。
  Widget _card(String title, List<Widget> rows) {
    final d = context.desk;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      decoration: BoxDecoration(
        color: d.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: d.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeskText(title, size: 13, color: d.ink2),
          const SizedBox(height: 4),
          for (final (i, row) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, color: d.line),
            row,
          ],
        ],
      ),
    );
  }

  Widget _row(String label, Widget control, {String? help}) {
    final d = context.desk;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Row(
        children: [
          Flexible(child: DeskText(label, size: 14)),
          if (help != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: help,
              child: Icon(Icons.help, size: 16, color: d.ink3),
            ),
          ],
          const SizedBox(width: 12),
          const Spacer(),
          control,
        ],
      ),
    );
  }

  Widget _toggle(
    String label,
    bool value,
    ValueChanged<bool> change, {
    Key? key,
    String? help,
  }) => _row(
    label,
    Switch(key: key, value: value, onChanged: change),
    help: help,
  );

  Widget _numberChoice(
    String label,
    int value,
    List<int> values,
    ValueChanged<int> change, {
    Key? key,
    String? help,
    String Function(int)? text,
  }) {
    final all = {...values, value}.toList()..sort();
    return _row(
      label,
      SizedBox(
        width: 120,
        child: DeskChoice<int>(
          key: key,
          value: value,
          items: [
            for (final n in all)
              DropdownMenuItem(value: n, child: Text(text?.call(n) ?? '$n')),
          ],
          onChanged: (v) {
            if (v != null) change(v);
          },
        ),
      ),
      help: help,
    );
  }

  Widget _settingsTab(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: DeskScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _card('下载', [
                _row(
                  settings.folder.isEmpty ? '下载文件夹（未设置）' : settings.folder,
                  DeskButton(
                    '选择…',
                    key: const ValueKey('booksource-folder'),
                    quiet: true,
                    onPressed: () async {
                      final folder = await widget.chooseFolder();
                      if (folder != null && mounted) {
                        _saveSettings(() => settings.folder = folder);
                      }
                    },
                  ),
                ),
                _numberChoice(
                  '每本书并发上限',
                  settings.threads,
                  [1, 2, 4, 6, 8, 12, 16, 24, 32],
                  (n) => _saveSettings(() => settings.threads = n),
                  key: const ValueKey('booksource-threads'),
                  help: '一本书同时下载的章节数上限。遇到限流会自动降速；书源自带的访问频率仍然有效。',
                ),
                _numberChoice(
                  '同时下载书数',
                  settings.maxBooks,
                  [1, 2, 3, 4],
                  (n) {
                    _saveSettings(() => settings.maxBooks = n);
                    _queueAction('queue.configure', {'maxBooks': n});
                  },
                  key: const ValueKey('booksource-max-books'),
                  help: '下载队列里同时进行的书数，其余排队。',
                ),
                _toggle(
                  '下载完自动加入书库',
                  settings.autoImport,
                  (v) => _saveSettings(() => settings.autoImport = v),
                  key: const ValueKey('booksource-auto-import'),
                ),
                _toggle(
                  '清理分页首尾的固定提示',
                  settings.removePagePrompts,
                  (v) => _saveSettings(() => settings.removePagePrompts = v),
                  key: const ValueKey('booksource-page-prompts'),
                  help: '去掉每页开头结尾的“本章未完，点击下一页”这类固定提示，不改动正文。',
                ),
              ]),
              _card('换源与多源', [
                _toggle(
                  '取不到的章节自动从其他书源补全',
                  settings.fill,
                  (v) => _saveSettings(() => settings.fill = v),
                  key: const ValueKey('booksource-fill'),
                ),
                _numberChoice(
                  '换源补章时同时尝试的书源数',
                  settings.alternateConcurrency,
                  [1, 2, 3, 4],
                  (n) => _saveSettings(() => settings.alternateConcurrency = n),
                  key: const ValueKey('booksource-alternate-concurrency'),
                  help: '同一章同一时间只交给一个书源；抓失败会交给其他书源再试。',
                ),
                _toggle(
                  '多源分摊下载',
                  settings.multiSource,
                  (v) => _saveSettings(() => settings.multiSource = v),
                  key: const ValueKey('booksource-multi'),
                  help: '至少 50 章、并且目录能对上的同书书源一起分担章节，各站点分别限速。',
                ),
                _numberChoice('最多替代源数', settings.maxAlternates, [
                  0,
                  1,
                  2,
                  3,
                  4,
                ], (n) => _saveSettings(() => settings.maxAlternates = n)),
              ]),
              _card('搜索与校验', [
                _numberChoice(
                  '搜索并发',
                  settings.searchConcurrency,
                  [8, 16, 24, 32, 48, 64],
                  (n) => _saveSettings(() => settings.searchConcurrency = n),
                  help: '同时搜索的书源数。',
                ),
                _numberChoice(
                  '快速搜索源数',
                  settings.quickLimit,
                  [20, 40, 60, 100, 200],
                  (n) => _saveSettings(() => settings.quickLimit = n),
                  help: '“快速搜索”只搜健康排名靠前的这么多个书源。',
                ),
                _numberChoice('完整校验并发', settings.checkConcurrency, [
                  4,
                  8,
                  16,
                  24,
                  32,
                ], (n) => _saveSettings(() => settings.checkConcurrency = n)),
                _toggle(
                  '暂时跳过连续失败的书源',
                  settings.skipUnhealthy,
                  (v) => _saveSettings(() => settings.skipUnhealthy = v),
                  help: '连续三次失败的书源暂避一段时间，到期自动重试。',
                ),
                _toggle(
                  '包含 WebView 书源',
                  settings.includeWebView,
                  (v) => _saveSettings(() => settings.includeWebView = v),
                  help: '普通书源搜完后再逐个搜索需要网页环境的书源，速度较慢。',
                ),
                _toggle(
                  '只显示书名包含关键词的结果',
                  settings.filterTitle,
                  (v) => _saveSettings(() => settings.filterTitle = v),
                ),
              ]),
              _card('书架更新', [
                _numberChoice(
                  '检查更新时同时检查的书数',
                  settings.updateConcurrency,
                  [1, 2, 4, 8],
                  (n) => _setAutoCheck(concurrency: n),
                  key: const ValueKey('booksource-update-concurrency'),
                ),
                _numberChoice(
                  '定时检查更新',
                  autoCheckHours,
                  [0, 1, 3, 6, 12, 24, 72],
                  (h) => _setAutoCheck(hours: h),
                  key: const ValueKey('booksource-auto-check'),
                  text: (h) => h == 0 ? '关闭' : '每 $h 小时',
                  help: '只在插件运行时检查；发现新章节会在书架提示，不会自动下载。',
                ),
              ]),
              _card('导入书源', [
                _row(
                  '新导入的书源放在',
                  SizedBox(
                    width: 120,
                    child: DeskChoice<String>(
                      key: const ValueKey('booksource-import-position'),
                      value: importOptions['position'] == 'top'
                          ? 'top'
                          : 'bottom',
                      items: const [
                        DropdownMenuItem(value: 'top', child: Text('最前')),
                        DropdownMenuItem(value: 'bottom', child: Text('最后')),
                      ],
                      onChanged: (v) {
                        if (v != null) _setImportOption('position', v);
                      },
                    ),
                  ),
                  help: '同样适用于从网址导入和订阅更新。',
                ),
                _toggle(
                  '名称覆盖',
                  importOptions['overrideName'] != false,
                  (v) => _setImportOption('overrideName', v),
                  key: const ValueKey('booksource-override-name'),
                  help: '重新导入同一书源时改用新文件里的名称。',
                ),
                _toggle(
                  '分组覆盖',
                  importOptions['overrideGroup'] == true,
                  (v) => _setImportOption('overrideGroup', v),
                  key: const ValueKey('booksource-override-group'),
                  help: '重新导入同一书源时改用新文件里的分组；关闭则保留你整理的分组。',
                ),
              ]),
              _card('网络', [
                _row(
                  '代理、直连对照与本机绕过',
                  DeskButton(
                    '网络与代理…',
                    key: const ValueKey('booksource-proxy'),
                    onPressed: _proxyDialog,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
}
