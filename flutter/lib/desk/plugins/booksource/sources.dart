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
      update(() => sourceMessage = bookSourceErrorText(e));
    }
  }

  Future<void> _importUrl(BuildContext context) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => DeskControllerScope(
        controllers: [controller],
        child: DeskAlert(
          title: const Text('从网址导入书源'),
          content: SizedBox(
            width: 460,
            child: TextField(
              key: const ValueKey('booksource-import-url-field'),
              controller: controller,
              autofocus: true,
              decoration: deskInput(context, hint: 'https://…（书源 JSON 的网址）'),
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
      sourceMessage = bookSourceErrorText(e);
    } finally {
      importingSource = false;
    }
    if (mounted) update(() {});
  }

  Future<void> _login(BuildContext context, Map<String, dynamic> source) async {
    final id = '${source['id']}';
    try {
      final info =
          await api!.call('source.loginInfo', {'id': source['id']}) as Map;
      final ui = info['ui'];
      if (ui is List && ui.isNotEmpty) {
        final fields = [
          for (final f in ui)
            if (f is Map && f['type'] != 'button') Map<String, dynamic>.from(f),
        ];
        // 登录界面按钮（阅读 loginUi 的 button，LIB-216）：按序号让插件执行书源自带的动作。
        final buttons = [
          for (final (i, f) in ui.indexed)
            if (f is Map && f['type'] == 'button') (i, '${f['name']}'),
        ];
        if (!context.mounted) return;
        final controllers = {
          for (final f in fields) '${f['name']}': TextEditingController(),
        };
        int? running;
        String? actionMessage;
        loginDialogSource = id;
        loginNotice.value = null;
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => DeskControllerScope(
            controllers: controllers.values,
            child: StatefulBuilder(
              builder: (context, change) {
                Future<void> runAction(int index) async {
                  loginNotice.value = null;
                  change(() {
                    running = index;
                    actionMessage = null;
                  });
                  try {
                    await _enableInteractions(id);
                    final r = await api!.call('source.loginAction', {
                      'id': id,
                      'index': index,
                      if (fields.isNotEmpty)
                        'info': {
                          for (final e in controllers.entries)
                            e.key: e.value.text,
                        },
                    }) as Map;
                    actionMessage = '${r['message']}';
                  } catch (e) {
                    actionMessage = '没有执行：${bookSourceErrorText(e)}';
                  }
                  if (context.mounted) change(() => running = null);
                }

                return DeskAlert(
                  title: Text('登录 ${source['name']}'),
                  content: SizedBox(
                    width: 380,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final f in fields)
                          TextField(
                            controller: controllers['${f['name']}'],
                            obscureText: f['type'] == 'password',
                            decoration: InputDecoration(
                              labelText: '${f['name']}',
                            ),
                          ),
                        if (buttons.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (i, name) in buttons)
                                DeskButton(
                                  name,
                                  key: ValueKey('booksource-login-action-$i'),
                                  busy: running == i,
                                  onPressed: running == null
                                      ? () => runAction(i)
                                      : null,
                                ),
                            ],
                          ),
                        ],
                        ValueListenableBuilder<String?>(
                          valueListenable: loginNotice,
                          builder: (_, notice, _) {
                            final text = notice ?? actionMessage;
                            return text == null
                                ? const SizedBox.shrink()
                                : Padding(
                                    padding: const EdgeInsets.only(top: 10),
                                    child: DeskNote(
                                      text,
                                      key: const ValueKey(
                                        'booksource-login-notice',
                                      ),
                                    ),
                                  );
                          },
                        ),
                        if (fields.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          const DeskText(
                            '登录信息用当前 Windows 账户加密保存在本机，只有这个书源能读取；再次登录会覆盖之前保存的内容。',
                            size: 12,
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    if (fields.isNotEmpty)
                      DeskButton(
                        '忘记已保存的登录信息',
                        key: const ValueKey('booksource-login-forget'),
                        quiet: true,
                        onPressed: () => Navigator.pop(context, 'forget'),
                      ),
                    DeskButton(
                      fields.isEmpty ? '关闭' : '取消',
                      quiet: fields.isNotEmpty,
                      onPressed: () => Navigator.pop(context),
                    ),
                    if (fields.isNotEmpty)
                      DeskButton(
                        '登录',
                        primary: true,
                        onPressed: () => Navigator.pop(context, 'login'),
                      ),
                  ],
                );
              },
            ),
          ),
        );
        loginDialogSource = null;
        if (choice == 'forget') {
          try {
            await api!.call('source.loginData.clear', {'id': id});
            sourceMessage = '已清除保存在本机的登录信息；网站上的登录状态（Cookie）不受影响。';
          } catch (e) {
            sourceMessage = '没有清除登录信息：${bookSourceErrorText(e)}';
          }
        } else if (choice == 'login') {
          final info = {
            for (final e in controllers.entries) e.key: e.value.text,
          };
          // 书源脚本登录时可能用 upLoginData() 取回本次填写的字段（LIB-212）。
          loginDrafts[id] = info;
          await _enableInteractions(id);
          final r =
              await api!.call('source.login', {'id': id, 'info': info}) as Map;
          sourceMessage = '${r['message']}';
        } else {
          return;
        }
      } else {
        update(() => sourceMessage = '已打开登录网页：在窗口里登录，完成后关闭窗口。');
        await _enableInteractions(id);
        final r = await api!.call('source.login', {'id': id}) as Map;
        sourceMessage = '${r['message']}';
      }
    } catch (e) {
      sourceMessage = '登录没有完成：${bookSourceErrorText(e)}';
    } finally {
      loginDrafts.remove(id);
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
    return showDialog<String>(
      context: context,
      builder: (dialog) => DeskControllerScope(
        controllers: [controller],
        child: DeskAlert(
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
            DeskButton(
              '取消',
              quiet: true,
              onPressed: () => Navigator.pop(dialog),
            ),
            DeskButton(
              '确定',
              primary: true,
              onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => DeskAlert(
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
      update(() => sourceMessage = bookSourceErrorText(e));
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
      checkStatus = bookSourceErrorText(e);
    }
    update(() {
      if (ping) {
        pinging = false;
      } else {
        checking = false;
      }
    });
  }

  /// 重置书源运行状态（V108，LIB-289）：丢掉本次运行里书源脚本存的设备、临时 Cookie 与缓存，
  /// 下次使用时重新生成；登录信息保留。番茄 APP 书源搜不到、目录取不到时用它换一批新设备。
  Future<void> _resetSource(Map<String, dynamic> s) async {
    try {
      await api!.call('source.reset', {'id': s['id']});
      update(
        () => sourceMessage =
            '已重置“${s['name']}”：下次搜索或下载时重新生成设备和临时数据，登录信息保留。正在进行的下载不受影响。',
      );
    } catch (e) {
      update(() => sourceMessage = '没有重置：${bookSourceErrorText(e)}');
    }
  }

  /// “去验证”（LIB-279）：单源交互式校验，插件自己弹出验证网页；每次用新的 checkId。
  /// 结果作为新的一次校验写入，关窗或取消记为验证未完成，不把旧失败改成通过。
  Future<void> _verifySource(String id) async {
    if (verifying.containsKey(id) || api == null) return;
    final checkId = 'verify-${DateTime.now().microsecondsSinceEpoch}';
    await _enableInteractions(id);
    update(() => verifying[id] = checkId);
    try {
      await api!.call('sources.check', {
        'ids': [id],
        'interactive': true,
        'checkId': checkId,
        if (checkKeyword.text.trim().isNotEmpty)
          'key': checkKeyword.text.trim(),
      });
      await _loadSources();
    } catch (e) {
      if (mounted) update(() => checkStatus = bookSourceErrorText(e));
    } finally {
      if (mounted && verifying[id] == checkId) {
        update(() => verifying.remove(id));
      }
    }
  }

  /// 取消只是发出信号，原请求收尾后由 [_verifySource] 清掉状态。
  Future<void> _cancelVerify(String id) async {
    final checkId = verifying[id];
    if (checkId == null) return;
    try {
      await api!.call('sources.check.cancel', {'checkId': checkId});
    } catch (_) {
      // 任务已结束：原请求会自己收尾。
    }
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
      builder: (dialog) => DeskAlert(
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

  /// 书源详情里的“最近一次校验”（V102）：结果、停在哪步、原因、校验词、兼容提示。
  Widget _lastCheck(Map<String, dynamic> source) {
    final d = context.desk;
    final check = source['check'] as Map?;
    final warnings = List<String>.from(source['staticWarnings'] as List? ?? []);
    final stage = const {
      'engine': '脚本初始化',
      'search': '搜索',
      'detail': '详情',
      'toc': '目录',
      'content': '正文',
    }[check?['stage']];
    final attempts = (check?['searchAttempts'] as num?)?.toInt() ?? 0;
    final origin = _keywordOrigins[check?['keywordOrigin']];
    final rows = <(String, String)>[
      (
        '结果',
        check == null
            ? '还没有校验'
            : check['ok'] == true
            ? '通过'
            : '未通过${stage == null ? '' : ' · 停在$stage'}',
      ),
      if (check?['ok'] == false && _checkReason(check).isNotEmpty)
        ('原因', _checkReason(check)),
      if (origin != null)
        ('校验词', '$origin${attempts > 1 ? '，共试了 $attempts 次' : ''}'),
      if (check?['ok'] == true && check?['chars'] != null)
        ('内容', '目录 ${check?['chapters']} 章，抽查正文 ${check?['chars']} 字'),
      if (warnings.isNotEmpty && source['supported'] == true)
        ('兼容提示', '${warnings.join('；')}（静态扫描，未必执行）'),
    ];
    return Padding(
      key: const ValueKey('booksource-last-check'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DeskText('最近一次校验', bold: true, size: 13),
          const SizedBox(height: 4),
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 72,
                    child: DeskText(k, size: 12, color: d.ink2),
                  ),
                  Expanded(child: DeskText(v, size: 12)),
                ],
              ),
            ),
          if (check?['ok'] == false &&
              (source['cause'] ?? check?['cause']) == 'verification' &&
              !verifying.containsKey('${source['id']}'))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DeskButton(
                '去验证',
                key: const ValueKey('booksource-last-check-verify'),
                icon: Icons.verified_user_outlined,
                onPressed: () => _verifySource('${source['id']}'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _sourceDetail(Map<String, dynamic> source) async {
    try {
      final detail =
          await api!.call('sources.detail', {'id': source['id']}) as Map;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => DeskAlert(
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
                  _lastCheck(source),
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
              _isFavorite('${source['id']}') ? '取消收藏' : '收藏',
              key: const ValueKey('booksource-detail-favorite'),
              quiet: true,
              onPressed: () {
                Navigator.pop(dialog);
                _toggleFavorite('${source['id']}');
              },
            ),
            DeskButton(
              '用这个书源单独搜索',
              onPressed: () {
                Navigator.pop(dialog);
                update(() {
                  pickedSources
                    ..clear()
                    ..add('${source['id']}');
                  searchScope = 'pick';
                  tab = 'search';
                });
              },
            ),
          ],
        ),
      );
    } catch (e) {
      update(() => sourceMessage = bookSourceErrorText(e));
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

  /// 工具条菜单：菜单项沿用原来按钮的 Key，测试与快捷操作仍能找到它们。
  Widget _menu(
    String label,
    List<(Key?, String, VoidCallback?)> items, {
    Key? key,
    IconData? icon,
  }) {
    final d = context.desk;
    return DeskMenuButton<int>(
      key: key,
      tooltip: label,
      onSelected: (i) => items[i].$3?.call(),
      itemBuilder: (_) => [
        for (final (i, item) in items.indexed)
          PopupMenuItem<int>(
            key: item.$1,
            value: i,
            enabled: item.$3 != null,
            child: Text(item.$2),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: d.line),
          borderRadius: BorderRadius.circular(8),
          color: d.surface,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: d.ink2),
              const SizedBox(width: 6),
            ],
            DeskText(label, size: 13),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 16, color: d.ink2),
          ],
        ),
      ),
    );
  }

  /// 中间的书源列表（R1c）：树显示时搜索框在树里，否则在这里；行按“文件 → 分组”两级分节。
  Widget _sourceList(BuildContext context, {required bool withSearch}) {
    final d = context.desk;
    final shown = _shownSources().where(_inSourceNode).toList();
    final rows = _sourceRows(shown);
    final failedIds = sources
        .where((s) => (s['check'] as Map?)?['ok'] == false)
        .map((s) => '${s['id']}')
        .toList();
    final activeFilters = sourceTags.length + (recommendedOnly ? 1 : 0);
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
              _menu(
                '导入',
                [
                  (const ValueKey('booksource-import'), '导入书源文件…', _importFile),
                  (
                    const ValueKey('booksource-import-url'),
                    '从网址导入…',
                    importingSource ? null : () => _importUrl(context),
                  ),
                  (
                    const ValueKey('booksource-fqnovel'),
                    '接入本机 FQNovel…',
                    _fqnovel,
                  ),
                  (
                    const ValueKey('booksource-subscriptions'),
                    '订阅与更新…',
                    _subscriptions,
                  ),
                ],
                key: const ValueKey('booksource-menu-import'),
                icon: Icons.file_download_outlined,
              ),
              _menu(
                '检查',
                [
                  (
                    const ValueKey('booksource-ping'),
                    '测速全部（只测能否连上）',
                    pinging ? null : () => _probe(true),
                  ),
                  (
                    const ValueKey('booksource-check'),
                    '校验全部（搜索到正文走一遍）',
                    checking ? null : () => _probe(false),
                  ),
                ],
                key: const ValueKey('booksource-menu-check'),
                icon: Icons.speed,
              ),
              _menu(
                '维护',
                [
                  (const ValueKey('booksource-dedupe'), '清理重复…', _dedupe),
                  (
                    const ValueKey('booksource-disable-failed'),
                    '停用未通过校验的（${failedIds.length}）',
                    failedIds.isEmpty
                        ? null
                        : () => _sourceAction('sources.setEnabled', {
                            'ids': failedIds,
                            'enabled': false,
                          }, message: '已停用 ${failedIds.length} 个校验失败的书源。'),
                  ),
                  (
                    const ValueKey('booksource-delete-failed'),
                    '删除未通过校验的（${failedIds.length}）…',
                    failedIds.isEmpty ? null : () => _removeSources(failedIds),
                  ),
                  (
                    const ValueKey('booksource-unsupported-ranking'),
                    '不支持的写法排行',
                    _unsupportedRanking,
                  ),
                ],
                key: const ValueKey('booksource-menu-maintain'),
                icon: Icons.build_outlined,
              ),
              if (pinging || checking)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (withSearch) SizedBox(width: 220, child: _sourceSearchField()),
              SizedBox(
                width: 140,
                child: DeskChoice<String>(
                  value: sourceStatusFilter,
                  items: [
                    for (final e in {
                      'all': '全部状态',
                      'ok': '可用',
                      'failed': '未通过校验',
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
                width: 150,
                child: DeskChoice<String>(
                  value: sourceSort,
                  items: [
                    for (final e in {
                      'manual': '自定顺序',
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
                width: 130,
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
              DeskButton(
                activeFilters == 0 ? '筛选' : '筛选 · $activeFilters',
                key: const ValueKey('booksource-filters-toggle'),
                icon: Icons.filter_list,
                quiet: !showSourceFilters,
                onPressed: () =>
                    update(() => showSourceFilters = !showSourceFilters),
              ),
            ],
          ),
          if (showSourceFilters)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _sourceFilters(),
            )
          else if (activeFilters > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final tag in sourceTags)
                    InputChip(
                      label: Text(tag),
                      onDeleted: () => update(() => sourceTags.remove(tag)),
                    ),
                  if (recommendedOnly)
                    InputChip(
                      label: const Text('推荐下载源'),
                      onDeleted: () => update(() => recommendedOnly = false),
                    ),
                ],
              ),
            ),
          if (sourceMessage != null) ...[
            const SizedBox(height: 8),
            DeskNote(sourceMessage!),
          ],
          if (checkStatus != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: DeskText(checkStatus!, size: 12, color: d.ink2),
            ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            DeskNote(
              sources.isEmpty
                  ? '还没有书源。点“导入”选择阅读 JSON、单文件 JS 或 so-novel JSON，或从网址导入。'
                  : '没有符合条件的书源。',
            ),
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

  /// 分组标题：一行统计，组操作收进“⋯”。“失效”改称“未通过”——可能是网络问题，不一定是书源坏了。
  Widget _groupHeader(String name, List<Map<String, dynamic>> items) {
    final d = context.desk;
    final collapsedKey = '${settings.groupBy}:$name';
    final collapsed = settings.collapsed.contains(collapsedKey);
    final ids = items.map((s) => '${s['id']}').toList();
    final ok = items.where((s) => (s['check'] as Map?)?['ok'] == true).length;
    final failed = items
        .where((s) => (s['check'] as Map?)?['ok'] == false)
        .length;
    final enabled = items.where((s) => s['enabled'] == true).length;
    return Padding(
      key: ValueKey('booksource-group-$name'),
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(
        children: [
          IconButton(
            key: ValueKey('booksource-collapse-$name'),
            tooltip: collapsed ? '展开' : '收起',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 20,
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
            child: Row(
              children: [
                Flexible(
                  child: DeskText(
                    settings.groupBy == 'file' ? _sourceFileName(name) : name,
                    bold: true,
                    lines: 1,
                  ),
                ),
                const SizedBox(width: 10),
                DeskText(
                  '${items.length} 个 · 启用 $enabled · 可用 $ok · 未通过 $failed · 未测 ${items.length - ok - failed}',
                  size: 12,
                  color: d.ink2,
                ),
              ],
            ),
          ),
          DeskMenuButton<VoidCallback>(
            key: ValueKey('booksource-group-menu-$name'),
            tooltip: '这一组的操作',
            icon: const Icon(Icons.more_horiz, size: 20),
            onSelected: (f) => f(),
            itemBuilder: (_) => [
              PopupMenuItem(value: () => _pin(ids), child: const Text('整组置顶')),
              PopupMenuItem(
                value: () => _pin(ids, bottom: true),
                child: const Text('整组置底'),
              ),
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
                child: const Text('测速这一组'),
              ),
              PopupMenuItem(
                enabled: !checking,
                value: () => _probe(false, ids),
                child: const Text('校验这一组'),
              ),
              if (settings.groupBy == 'file' && name.startsWith('http'))
                PopupMenuItem(
                  value: () => _subscriptionPreview(name),
                  child: const Text('从网址更新…'),
                ),
              PopupMenuItem(
                value: () => _removeSources(ids),
                child: Text(settings.groupBy == 'file' ? '删除整个文件…' : '删除这组…'),
              ),
            ],
          ),
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
          DeskMenuButton<String>(
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
              // R1：用图标代替“▾”文字（缺字时会显示成方框）。
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DeskText('更多', size: 13, color: any ? d.ink : d.ink3),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: any ? d.ink2 : d.ink3,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 书源一行：状态圆点（绿可用、黄慢、红未通过、灰未测）、名称与至多两个标签、
  /// 速度、启用开关、“⋯”菜单；需要登录的书源保留“登录”按钮。
  Widget _sourceRow(Map<String, dynamic> s, String group) {
    final d = context.desk;
    final id = '${s['id']}';
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
    // 静态告警只是提示（V102 A）：能试跑的书源不再标“不能用”，从说明里分出来单独写。
    final warnings = List<String>.from(s['staticWarnings'] as List? ?? []);
    final reasons = List<String>.from(s['reasons'] as List? ?? [])
        .where((r) => s['supported'] != true || !warnings.contains(r))
        .toList();
    final failed = check?['ok'] == false;
    final verifyingNow = verifying.containsKey(id);
    final needsVerify =
        failed && (s['cause'] ?? check?['cause']) == 'verification';
    final dot = failed
        ? d.pen
        : check?['ok'] == true
        ? (ms != null && ms >= 4000 ? d.warn : d.add)
        : d.ink3;
    final tags = <(String, Tone)>[
      if (s['supported'] != true) ('不能用', Tone.warn),
      if (s['supported'] == true && warnings.isNotEmpty) ('兼容提示', Tone.info),
      if (s['duplicate'] == true) ('重复', Tone.warn),
      if (s['updated'] == true) ('已更新', Tone.accent),
      for (final tag in s['tags'] as List? ?? []) ('$tag', Tone.info),
      if (s['supported'] == true && s['webView'] == true) ('网页', Tone.info),
    ];
    final speed = failed
        ? '未通过校验'
        : check?['ok'] == true
        ? '${((ms ?? 0) / 1000).toStringAsFixed(ms != null && ms < 10000 ? 2 : 1)}s'
        : ping?['ok'] == true
        ? '可连接 ${ping?['ms']}ms'
        : '未测';
    final detail = verifyingNow
        ? '正在验证，请在弹出的网页里完成；最多等 5 分钟'
        : [
            if (reasons.isNotEmpty) reasons.join('；'),
            if (failed)
              '${_checkReason(check).isEmpty ? '校验没通过${stage == null ? '' : '（$stage）'}' : '校验${stage == null ? '' : '（$stage）'}：${_checkReason(check)}'}${!_hasSpecificReason(check) && _sourceCauses.containsKey(s['cause'] ?? check?['cause']) ? ' · ${_sourceCauses[s['cause'] ?? check?['cause']]}' : ''}',
            if (!failed && s['supported'] == true && warnings.isNotEmpty)
              '可能用到未支持的写法，校验时才知道是否真的用到',
            if (check?['ok'] == true && check?['chars'] != null)
              '目录 ${check?['chapters']} 章，抽查正文 ${check?['chars']} 字',
            if (health?['lastError'] != null &&
                '${health?['lastError']}'.isNotEmpty)
              '${health?['lastError']}',
          ].where((t) => t.isNotEmpty).join(' · ');
    final selectedRow = selectedSources.contains(id);
    final focused = focusedSource == id && sourceInspectorShown;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selectedRow ? d.accentSoft : d.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: focused ? d.accent : d.line,
            width: focused ? 1.4 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('booksource-source-$group-$id'),
          onTap: () => sourceInspectorShown
              ? update(() => focusedSource = id)
              : _sourceDetail(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                Checkbox(
                  key: ValueKey('booksource-source-select-$id'),
                  value: selectedRow,
                  onChanged: (v) => update(() {
                    if (v == true) {
                      selectedSources.add(id);
                    } else {
                      selectedSources.remove(id);
                    }
                  }),
                ),
                Tooltip(
                  message: failed
                      ? '未通过校验'
                      : check?['ok'] == true
                      ? '可用'
                      : '未校验',
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: s['enabled'] == true ? dot : null,
                      border: Border.all(color: dot, width: 1.5),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (s['pinned'] == true) ...[
                            Icon(Icons.push_pin, size: 14, color: d.ink2),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: DeskText(
                              '${s['name']}',
                              bold: true,
                              lines: 1,
                            ),
                          ),
                          for (final t in tags.take(2)) ...[
                            const SizedBox(width: 6),
                            DeskTag(t.$1, t.$2),
                          ],
                          if (tags.length > 2) ...[
                            const SizedBox(width: 6),
                            Tooltip(
                              message: tags.map((t) => t.$1).join('、'),
                              child: DeskTag('+${tags.length - 2}', Tone.info),
                            ),
                          ],
                        ],
                      ),
                      if (detail.isNotEmpty)
                        Tooltip(
                          message: [
                            detail,
                            if (warnings.isNotEmpty)
                              '兼容提示（静态扫描，未必执行）：\n${warnings.join('\n')}',
                          ].join('\n'),
                          child: DeskText(
                            detail,
                            size: 12,
                            color: d.ink2,
                            lines: 1,
                          ),
                        ),
                    ],
                  ),
                ),
                if (verifyingNow) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 6),
                  DeskButton(
                    '取消',
                    key: ValueKey('booksource-verify-cancel-$id'),
                    quiet: true,
                    onPressed: () => _cancelVerify(id),
                  ),
                ] else if (needsVerify)
                  DeskButton(
                    '去验证',
                    key: ValueKey('booksource-verify-$id'),
                    quiet: true,
                    tooltip: '弹出这个书源的网页，完成人工验证后重新校验',
                    onPressed: () => _verifySource(id),
                  ),
                IconButton(
                  key: ValueKey('booksource-favorite-$id'),
                  tooltip: _isFavorite(id) ? '取消收藏' : '收藏',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _isFavorite(id)
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    size: 19,
                    color: _isFavorite(id) ? d.warn : d.ink3,
                  ),
                  onPressed: () => _toggleFavorite(id),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message:
                      '最近 20 次：${(health?['ms'] as List? ?? []).join(' / ')} ms',
                  child: DeskText(
                    speed,
                    size: 12,
                    color: failed ? d.pen : d.ink2,
                  ),
                ),
                if (s['login'] == true && s['supported'] == true)
                  DeskButton(
                    '登录',
                    key: ValueKey('booksource-login-$id'),
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
                DeskMenuButton<VoidCallback>(
                  key: ValueKey('booksource-row-menu-$id'),
                  tooltip: '更多操作',
                  icon: const Icon(Icons.more_horiz, size: 20),
                  onSelected: (f) => f(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      key: ValueKey('booksource-pin-$id'),
                      value: () => _pin([id], pinned: s['pinned'] != true),
                      child: Text(s['pinned'] == true ? '取消置顶' : '置顶'),
                    ),
                    PopupMenuItem(
                      key: ValueKey('booksource-bottom-$id'),
                      value: () => _pin([id], bottom: true),
                      child: const Text('置底'),
                    ),
                    PopupMenuItem(
                      enabled: !pinging,
                      value: () => _probe(true, [id]),
                      child: const Text('测速'),
                    ),
                    PopupMenuItem(
                      enabled: !checking,
                      value: () => _probe(false, [id]),
                      child: const Text('校验'),
                    ),
                    PopupMenuItem(
                      key: ValueKey('booksource-reset-$id'),
                      value: () => _resetSource(s),
                      child: const Text('重置设备与运行状态'),
                    ),
                    PopupMenuItem(
                      value: () => _sourceDetail(s),
                      child: const Text('详情、评分与下载参数…'),
                    ),
                    PopupMenuItem(
                      value: () => _removeSources([id]),
                      child: const Text('删除…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
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
