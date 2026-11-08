// 排版页“段落与识别”分页：系统提示、诗词、场景块、生僻字注音（R5-13 拆出，逻辑不变）。
part of 'layout_page.dart';

extension _LayoutParagraphSection on _LayoutPageState {
  /// 系统提示自定义识别规则（V78）：写进本书 rule_options，进变更记录。
  Future<void> setSystemPatterns(List<String> next, String done) async {
    final current = session;
    if (current == null) return;
    update(() => busy = true);
    try {
      final options = Map<String, dynamic>.from(
        (current.saved['rule_options'] as Map?) ?? const {},
      );
      if (next.isEmpty) {
        options.remove('system_patterns');
      } else {
        options['system_patterns'] = next;
      }
      await current.apply(await current.preview({'rule_options': options}));
      if (mounted) {
        update(() {
          systemPatterns = next;
          message = done;
        });
      }
    } catch (error) {
      if (mounted) {
        update(() => message = deskErrorText(error, '识别规则未能保存'));
      }
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  /// 系统提示识别范围（V121，LAY-169）：写进本书 rule_options，进变更记录。
  Future<void> setSystemScope(String next) async {
    final current = session;
    if (current == null || next == systemScope) return;
    update(() => busy = true);
    try {
      final options = Map<String, dynamic>.from(
        (current.saved['rule_options'] as Map?) ?? const {},
      );
      if (next == 'auto') {
        options.remove('system_scope');
      } else {
        options['system_scope'] = next;
      }
      await current.apply(await current.preview({'rule_options': options}));
      if (mounted) {
        update(() {
          systemScope = next;
          message = '识别范围已改为“${systemScopes[next]}”';
        });
      }
    } catch (error) {
      if (mounted) {
        update(() => message = deskErrorText(error, '识别范围未能保存'));
      }
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  Widget systemScopeControls() {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 64,
              child: Text('识别范围', style: ui(12, c: d.ink2)),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DeskSegmented<String>(
                  key: const ValueKey('layout-system-scope'),
                  value: systemScope,
                  options: systemScopes,
                  onChanged: busy ? null : setSystemScope,
                ),
                const SizedBox(height: 4),
                Text(switch (systemScope) {
                  'all' => '每一行整行【】都按系统提示排（V121 以前的规则）。',
                  'keyword' => '只把带系统用语（叮、任务、奖励、等级、属性等）或数值的整行【】按系统提示排。',
                  _ =>
                    '按内容区分：台词、聊天消息、书前标签不算系统提示；'
                        '【】多为系统提示的书，拿不准的行也按系统提示排。',
                }, style: ui(11.5, c: d.ink3)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget systemPatternControls() {
    final d = context.desk;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SizedBox(
              width: 64,
              child: Text('自定义识别', style: ui(12, c: d.ink2)),
            ),
          ),
          Expanded(
            child: Wrap(
              key: const ValueKey('layout-system-patterns'),
              children: [
                for (final p in systemPatterns)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, bottom: 4),
                    child: InputChip(
                      key: ValueKey(('layout-system-pattern', p)),
                      label: Text(
                        systemPatternLabel(p),
                        style: ui(12, c: d.ink),
                      ),
                      onDeleted: busy
                          ? null
                          : () => setSystemPatterns(
                              [...systemPatterns]..remove(p),
                              '已删除识别规则',
                            ),
                      deleteButtonTooltipMessage: '删除这条规则',
                    ),
                  ),
                DeskButton(
                  '添加规则…',
                  key: const ValueKey('layout-system-pattern-add'),
                  quiet: true,
                  onPressed: busy || systemPatterns.length >= 20
                      ? null
                      : () async {
                          final p = await showSystemPatternDialog(context);
                          if (p == null || !mounted) return;
                          if (systemPatterns.contains(p)) return;
                          await setSystemPatterns([
                            ...systemPatterns,
                            p,
                          ], '已添加识别规则');
                        },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 样式包带的系统提示块样式（V78）：一并切到分类样式并套用。
  void applyPackBlocks(Object? blocks) {
    if (blocks is! Map || !mounted) return;
    edit(() {
      systemBlockStyle = 'styled';
      systemStyles = Map<String, dynamic>.from(blocks);
    });
  }

  /// 样式包带的场景样式（V82）：聊天记录样式、书信样式与改过的各场景参数一并套用。
  void applyPackInsets(Object? insets) {
    if (insets is! Map || !mounted) return;
    edit(() {
      chatBlockStyle = insets['chat_block_style'] as String? ?? chatBlockStyle;
      letterBlockStyle =
          insets['letter_block_style'] as String? ?? letterBlockStyle;
      final styles = (insets['styles'] as Map?)?.cast<String, dynamic>();
      insetStyles = styles == null || styles.isEmpty ? null : styles;
    });
  }

  /// 系统提示与诗词（V50，LAY-121/122）：三个选项，问号说明识别规则。
  Widget blockControls(
    String label,
    String help,
    String field,
    String value,
    Map<String, String> options,
    void Function(String) assign,
  ) => foldRow(
    field: field,
    label: label,
    help: DeskHelp(help, key: ValueKey('layout-help-$field')),
    current: options[value] ?? value,
    control: KeyedSubtree(
      key: ValueKey('layout-$field'),
      child: DeskSegmented<String>(
        value: value,
        options: options,
        onChanged: busy ? null : (next) => edit(() => assign(next)),
      ),
    ),
  );

  /// 场景识别规则（V82，LAY-137）：写进本书 rule_options.inset_rules，进变更记录；添加规则时一并开启识别。
  Future<void> setInsetRules(
    List<Map<String, dynamic>> next,
    String done, {
    bool enable = false,
  }) async {
    final current = session;
    if (current == null) return;
    update(() => busy = true);
    try {
      // 先把还没保存的排版修改存掉，再单独写规则。
      _saveTimer?.cancel();
      await save();
      final clean = identity == baseline;
      final options = Map<String, dynamic>.from(
        (current.saved['rule_options'] as Map?) ?? const {},
      );
      if (next.isEmpty) {
        options.remove('inset_rules');
      } else {
        options['inset_rules'] = next;
      }
      await current.apply(
        await current.preview({
          'rule_options': options,
          if (enable && insetDetect != 'on') 'inset_detect': 'on',
        }),
      );
      if (mounted) {
        update(() {
          insetRules = next;
          if (enable) insetDetect = 'on';
          _identityCache = _computeIdentity();
          savedValues = {...savedValues, 'inset_detect': insetDetect};
          if (clean) baseline = identity;
          message = done;
        });
      }
    } catch (error) {
      if (mounted) {
        update(() => message = deskErrorText(error, '识别规则未能保存'));
      }
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  Widget insetDetectControls() {
    final d = context.desk;
    return foldRow(
      field: 'inset_detect',
      label: '场景识别',
      help: const DeskHelp(
        '按规则把整段正文认成场景：内置“诏书”（以奉天承运、圣旨、诏曰开头，到“钦此”结束）与“论坛楼层”'
        '（连续两层以上的“1楼”“#2”“沙发”）；也可以添加自己的规则：选场景，写开头和结尾（文字或正则）与最多行数。'
        '手工标注优先，其次规则，再其次聊天自动识别。内置项可在规则页单独关闭。原文不改。',
        key: ValueKey('layout-help-inset_detect'),
      ),
      current:
          '${insetDetectModes[insetDetect] ?? insetDetect}'
          '${insetRules.isEmpty ? '' : ' · 自定义 ${insetRules.length} 条'}',
      control: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: const ValueKey('layout-inset_detect'),
            child: DeskSegmented<String>(
              value: insetDetect,
              options: insetDetectModes,
              onChanged: busy
                  ? null
                  : (value) => edit(() => insetDetect = value),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            key: const ValueKey('layout-inset-rules'),
            children: [
              for (final (i, r) in insetRules.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 6, bottom: 4),
                  child: InputChip(
                    key: ValueKey(('layout-inset-rule', i)),
                    label: Text(insetRuleLabel(r), style: ui(12, c: d.ink)),
                    onDeleted: busy
                        ? null
                        : () => setInsetRules(
                            [...insetRules]..removeAt(i),
                            '已删除场景识别规则',
                          ),
                    deleteButtonTooltipMessage: '删除这条规则',
                  ),
                ),
              DeskButton(
                '添加规则…',
                key: const ValueKey('layout-inset-rule-add'),
                quiet: true,
                onPressed: busy || insetRules.length >= 20
                    ? null
                    : () async {
                        final rule = await showInsetRuleDialog(context);
                        if (rule == null || !mounted) return;
                        await setInsetRules(
                          [...insetRules, rule],
                          '已添加场景识别规则',
                          enable: true,
                        );
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 各场景的样式（V82，LAY-136）：预设、我的场景样式、自定义，“编辑…”打开编辑器。
  Widget insetStyleControls() {
    final d = context.desk;
    final settings = widget.library is SettingsService
        ? widget.library as SettingsService
        : null;
    Map<String, Object> current(String scene) {
      final mine = insetStyles?[scene];
      return mine is Map
          ? Map<String, Object>.from(mine)
          : defaultInsetStyle(scene, chatBlockStyle);
    }

    void choose(String scene, Map<String, Object> style) => edit(() {
      // 选聊天的三种预设之一且开着识别时，改的是“聊天记录”设置本身。
      final preset = insetPresetOf(scene, style);
      if (scene == 'chat' && chatBlockStyle != 'off' && preset != 'custom') {
        chatBlockStyle = preset;
        insetStyles = {...?insetStyles}..remove('chat');
      } else if (sameInsetStyle(
        defaultInsetStyle(scene, chatBlockStyle),
        style,
      )) {
        insetStyles = {...?insetStyles}..remove(scene);
      } else {
        insetStyles = {...?insetStyles, scene: style};
      }
      if (insetStyles!.isEmpty) insetStyles = null;
    });

    Widget row(String scene, Object? library) {
      final style = current(scene);
      final saved = savedInsetsOf(library, scene);
      final preset = insetPresetOf(scene, style);
      final matched =
          preset != 'custom' ||
          saved.values.any((s) => sameInsetStyle(s, style));
      Widget chip(
        String text,
        bool selected,
        VoidCallback onTap,
        Key key, {
        VoidCallback? onDelete,
      }) => Padding(
        padding: const EdgeInsets.only(right: 6, bottom: 4),
        child: InputChip(
          key: key,
          label: Text(text, style: ui(12, c: d.ink)),
          selected: selected,
          showCheckmark: false,
          onPressed: busy ? null : onTap,
          onDeleted: busy ? null : onDelete,
          deleteButtonTooltipMessage: '从我的场景样式中删除',
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: 64,
                child: Text(insetTypes[scene]!, style: ui(12, c: d.ink2)),
              ),
            ),
            Expanded(
              child: Wrap(
                key: ValueKey('layout-inset-$scene'),
                children: [
                  for (final e in insetStylePresets.entries)
                    if (e.value.$1 == scene)
                      chip(
                        e.value.$2,
                        preset == e.key,
                        () => choose(scene, Map.of(e.value.$3)),
                        ValueKey(('layout-inset-preset', scene, e.key)),
                      ),
                  for (final e in saved.entries)
                    chip(
                      e.key,
                      sameInsetStyle(e.value, style),
                      () => choose(scene, e.value),
                      ValueKey(('layout-inset-saved', scene, e.key)),
                      onDelete: settings == null
                          ? null
                          : () => settings.savePatch({
                              'inset_style_library': [
                                for (final item
                                    in (library as List? ?? const []))
                                  if (!(item is Map &&
                                      item['scene'] == scene &&
                                      item['name'] == e.key))
                                    item,
                              ],
                            }),
                    ),
                  if (!matched)
                    chip(
                      '自定义',
                      true,
                      () {},
                      ValueKey(('layout-inset-custom', scene)),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: DeskButton(
                      '编辑…',
                      key: ValueKey(('layout-inset-edit', scene)),
                      quiet: true,
                      onPressed: busy
                          ? null
                          : () async {
                              final result = await showInsetStyleEditor(
                                context,
                                scene: scene,
                                initial: style,
                                takenNames: saved.keys.toSet(),
                              );
                              if (result == null || !mounted) return;
                              choose(scene, result.style);
                              if (result.name != null && settings != null) {
                                await settings.savePatch({
                                  'inset_style_library': [
                                    ...(library as List? ?? const []),
                                    {
                                      'name': result.name,
                                      'scene': scene,
                                      'style': result.style,
                                    },
                                  ],
                                });
                              }
                            },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget rows(Object? library) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final scene in insetTypes.keys) row(scene, library)],
    );
    return foldRow(
      field: 'inset_styles',
      label: '各场景样式',
      help: const DeskHelp(
        '每种场景选一种样式，“编辑…”可逐项调整（外框、线型、底色、标题与饰纹、对齐、字号、首字放大、字体、卷轴杆），'
        '另存为“我的场景样式”后所有书可用；导出章节样式包时连同聊天、书信样式一起带上。'
        '“淡纸纹”是真机测试过的最浅一级，深色模式下会随页面反转；AZW3 不显示底色与楷体。',
        key: ValueKey('layout-help-inset_styles'),
      ),
      current: insetStyles == null || insetStyles!.isEmpty
          ? '全部内置'
          : '改过 ${insetStyles!.length} 种',
      control: settings == null
          ? rows(null)
          : ValueListenableBuilder<SettingsSnapshot>(
              valueListenable: settings.snapshot,
              builder: (_, snap, _) =>
                  rows(snap.configuration['inset_style_library']),
            ),
    );
  }

  /// 系统提示（V50、V77，LAY-121/132）：识别方式；“分类样式”下单行提示与多行面板各选一种样式。
  Widget systemControls() {
    final d = context.desk;
    final styles = systemStyles ?? defaultSystemStyles();
    final note = presetOf(styles['note'] as Map?, notePresetNames);
    final panel = presetOf(styles['panel'] as Map?, panelPresetNames);
    void choose(String kind, Map<String, Object> style) => edit(() {
      systemStyles = {...Map<String, dynamic>.from(styles), kind: style};
    });
    Widget presets(
      String kind,
      String label,
      String value,
      Map<String, String> names,
    ) {
      final current = styles[kind] as Map?;
      final settings = widget.library is SettingsService
          ? widget.library as SettingsService
          : null;
      Widget chips(Object? library) {
        final saved = savedStylesOf(library, kind);
        final matched =
            value != 'custom' || saved.values.any((s) => sameStyle(s, current));
        Widget chip(
          String text,
          bool selected,
          VoidCallback onTap,
          Key key, {
          VoidCallback? onDelete,
        }) => Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 4),
          child: InputChip(
            key: key,
            label: Text(text, style: ui(12, c: d.ink)),
            selected: selected,
            showCheckmark: false,
            onPressed: busy ? null : onTap,
            onDeleted: busy ? null : onDelete,
            deleteButtonTooltipMessage: '从我的样式中删除',
          ),
        );
        return Wrap(
          children: [
            for (final e in names.entries)
              chip(
                e.value,
                value == e.key,
                () => choose(
                  kind,
                  Map<String, Object>.from(blockStylePresets[e.key]!),
                ),
                ValueKey('layout-system-$kind-${e.key}'),
              ),
            for (final e in saved.entries)
              chip(
                e.key,
                sameStyle(e.value, current),
                () => choose(kind, e.value),
                ValueKey(('layout-system-saved', kind, e.key)),
                onDelete: settings == null
                    ? null
                    : () => settings.savePatch({
                        'block_style_library': [
                          for (final item in (library as List? ?? const []))
                            if (!(item is Map &&
                                item['kind'] == kind &&
                                item['name'] == e.key))
                              item,
                        ],
                      }),
              ),
            if (!matched)
              chip('自定义', true, () {}, ValueKey('layout-system-$kind-custom')),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: DeskButton(
                '编辑…',
                key: ValueKey('layout-system-edit-$kind'),
                quiet: true,
                onPressed: busy
                    ? null
                    : () async {
                        final result = await showBlockStyleEditor(
                          context,
                          kind: kind,
                          initial: styleOrPreset(
                            current,
                            kind == 'note' ? 'bar' : 'titled',
                          ),
                          takenNames: saved.keys.toSet(),
                        );
                        if (result == null || !mounted) return;
                        choose(kind, result.style);
                        if (result.name != null && settings != null) {
                          await settings.savePatch({
                            'block_style_library': [
                              ...(library as List? ?? const []),
                              {
                                'name': result.name,
                                'kind': kind,
                                'style': result.style,
                              },
                            ],
                          });
                        }
                      },
              ),
            ),
          ],
        );
      }

      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: 64,
                child: Text(label, style: ui(12, c: d.ink2)),
              ),
            ),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey('layout-system-$kind'),
                child: settings == null
                    ? chips(null)
                    : ValueListenableBuilder<SettingsSnapshot>(
                        valueListenable: settings.snapshot,
                        builder: (_, snap, _) =>
                            chips(snap.configuration['block_style_library']),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    return foldRow(
      field: 'system_block_style',
      label: '系统提示',
      help: const DeskHelp(
        '整行由【……】组成的行（如“【叮！新手礼包已发放。】”）。行中间夹着【】的句子不算。'
        '“分类样式”：只有一行的按“单行提示”排，连续两行以上合成“面板”；紧挨在前面单独一行的“叮！”并入面板；'
        '面板首行短且没有冒号时作标题，“键：值”的键名可加粗，成品里可去掉【】。'
        '“编辑…”可逐项调整并另存为“我的样式”（所有书可用）；更自由的写法是在附加 CSS 里用公开类名 '
        '.blk-note、.blk-panel、.blk-panel-title、.blk-key、.system-line。'
        '原文不改；同时用于 EPUB、AZW3、MOBI、KFX。小预览按所选样式画出单行提示与面板，只是近似，以真机预览为准（Kindle 上 AZW3 不显示底色，KFX 可能不显示边框）。下方是本书按已保存的设置识别到的数量，“查看位置”逐处列出。',
        key: ValueKey('layout-help-system_block_style'),
      ),
      current: systemBlockStyle == 'styled'
          ? describeSystemStyles(styles)
          : systemBlockStyles[systemBlockStyle] ?? systemBlockStyle,
      control: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KeyedSubtree(
            key: const ValueKey('layout-system_block_style'),
            child: DeskSegmented<String>(
              value: systemBlockStyle,
              options: systemBlockStyles,
              onChanged: busy
                  ? null
                  : (value) => edit(() {
                      systemBlockStyle = value;
                      if (value == 'styled') {
                        systemStyles ??= defaultSystemStyles();
                      }
                    }),
            ),
          ),
          if (systemBlockStyle == 'styled') ...[
            presets('note', '单行提示', note, notePresetNames),
            presets('panel', '多行面板', panel, panelPresetNames),
          ],
          if (systemBlockStyle != 'off') ...[
            systemScopeControls(),
            systemPatternControls(),
          ],
          if (widget.library is RuleCatalogLibrary)
            RecognitionCounts(
              library: widget.library as RuleCatalogLibrary,
              bookId: widget.bookId,
            ),
        ],
      ),
    );
  }

  /// 生僻字注音（V73，LAY-129）：注音方式与范围；只标正文。
  Widget rareCharControls() => foldRow(
    field: 'rare_char_ruby',
    label: '生僻字注音',
    help: const DeskHelp(
      '不在《通用规范汉字表》8105 字里的字（选“表外字和三级字”时也包括表中最后 1605 个三级字），'
      '在上方标拼音。繁体字按对应简体判断；只标正文，不标标题和目录；已有注音的字不重复标。'
      '多音字取最常用读音。原文不改；同时用于 EPUB、AZW3、MOBI、KFX。小预览里不显示注音。',
      key: ValueKey('layout-help-rare-char'),
    ),
    current: rareCharRuby == 'off'
        ? rareCharRubyModes['off']!
        : '${rareCharRubyModes[rareCharRuby] ?? rareCharRuby} · '
              '${rareCharScopes[rareCharScope] ?? rareCharScope}',
    control: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KeyedSubtree(
          key: const ValueKey('layout-rare_char_ruby'),
          child: DeskSegmented<String>(
            value: rareCharRuby,
            options: rareCharRubyModes,
            onChanged: busy
                ? null
                : (value) => edit(() => rareCharRuby = value),
          ),
        ),
        const SizedBox(height: 6),
        KeyedSubtree(
          key: const ValueKey('layout-rare_char_scope'),
          child: DeskSegmented<String>(
            value: rareCharScope,
            options: rareCharScopes,
            onChanged: busy || rareCharRuby == 'off'
                ? null
                : (value) => edit(() => rareCharScope = value),
          ),
        ),
      ],
    ),
  );
}
