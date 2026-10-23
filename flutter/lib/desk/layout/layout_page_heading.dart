// 排版页“标题”分页：章首图、章节样式包、标题样式、场景分隔、章首段落（R5-13 拆出，逻辑不变）。
part of 'layout_page.dart';

extension _LayoutHeadingSection on _LayoutPageState {
  /// 统一章首图（V54，LAY-124）：选图后单独预览并应用（进变更记录），不经草稿；范围与宽度是排版字段。
  Future<void> setChapterHeadImage(String? path) async {
    if (session == null) return;
    update(() => busy = true);
    try {
      await session!.apply(
        await session!.preview({'chapter_head_image': path}),
      );
      if (mounted) {
        update(() {
          chapterHeadImage = path;
          message = path == null ? '已移除章首图' : '已设置章首图';
        });
        unawaited(loadChapterHeadPixels());
      }
    } catch (error) {
      if (mounted) {
        update(() => message = deskErrorText(error, '章首图未能应用'));
      }
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  /// 读入章首图供小预览绘制；读不了时不画，不影响保存与成品。
  Future<void> loadChapterHeadPixels() async {
    final path = chapterHeadImage;
    if (path == _chapterHeadLoaded) return;
    _chapterHeadLoaded = path;
    dui.Image? image;
    if (path != null) {
      try {
        final codec = await dui.instantiateImageCodec(
          await File(path).readAsBytes(),
        );
        image = (await codec.getNextFrame()).image;
      } catch (_) {
        image = null;
      }
    }
    if (!mounted || _chapterHeadLoaded != path) {
      image?.dispose();
      return;
    }
    update(() {
      chapterHeadPixels?.dispose();
      chapterHeadPixels = image;
    });
  }

  Widget chapterHeadControls() {
    final d = context.desk;
    final name = chapterHeadImage?.replaceAll('\\', '/').split('/').last;
    final pick = widget.pickImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('章首图', style: ui(12, w: 600, c: d.ink2)),
            const DeskHelp(
              '选一张图，自动放在每章（或每卷）标题上方；花饰、分隔线这类小图最合适，满宽的大图会挤占章首页的正文。'
              '某章若在资源页把插图版式设为“章首图”，这一章用它代替统一的图。序言、后记不加。'
              '全书只存一份图片；原文不改，EPUB、AZW3、MOBI、KFX 都生效。',
              key: ValueKey('layout-help-chapter-head'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                name ?? '未设置',
                key: const ValueKey('layout-chapter-head-name'),
                overflow: TextOverflow.ellipsis,
                style: ui(12.5, c: name == null ? d.ink3 : d.ink),
              ),
            ),
            DeskButton(
              name == null ? '选择图片…' : '更换…',
              key: const ValueKey('layout-chapter-head-pick'),
              quiet: true,
              onPressed: busy || pick == null
                  ? null
                  : () async {
                      final path = await pick();
                      if (path != null && mounted) {
                        await setChapterHeadImage(path);
                      }
                    },
            ),
            if (name != null)
              DeskButton(
                '移除',
                key: const ValueKey('layout-chapter-head-remove'),
                quiet: true,
                onPressed: busy ? null : () => setChapterHeadImage(null),
              ),
          ],
        ),
        if (name != null ||
            (chapterStyle?['head_images'] as List?)?.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text('用于', style: ui(12, c: d.ink2)),
          const SizedBox(height: 4),
          KeyedSubtree(
            key: const ValueKey('layout-chapter_head_scope'),
            child: DeskSegmented<String>(
              value: chapterHeadScope,
              options: chapterHeadScopes,
              onChanged: busy
                  ? null
                  : (value) => edit(() => chapterHeadScope = value),
            ),
          ),
          const SizedBox(height: 8),
          Text('宽度', style: ui(12, c: d.ink2)),
          const SizedBox(height: 4),
          KeyedSubtree(
            key: const ValueKey('layout-chapter_head_width'),
            child: DeskSegmented<String>(
              value: chapterHeadWidth,
              options: chapterHeadWidths,
              onChanged: busy
                  ? null
                  : (value) => edit(() => chapterHeadWidth = value),
            ),
          ),
        ],
      ],
    );
  }

  /// 章节样式包（V74，LAY-130）：单独预览并应用（进变更记录），不经草稿。
  Future<void> setChapterStyle(Map<String, dynamic>? style, String done) async {
    if (session == null) return;
    update(() => busy = true);
    try {
      await session!.apply(await session!.preview({'chapter_style': style}));
      if (mounted) {
        update(() {
          chapterStyle = style;
          message = done;
        });
      }
    } catch (error) {
      if (mounted) {
        update(() => message = deskErrorText(error, '章节样式包未能应用'));
      }
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  Future<Map<String, dynamic>?> styleRequest(
    Map<String, Object?> request,
    String failed,
  ) async {
    final store = session;
    if (store is! ChapterStyleStore) return null;
    update(() => busy = true);
    try {
      return await (store as ChapterStyleStore).chapterStyleRequest(request);
    } catch (error) {
      if (mounted) update(() => message = deskErrorText(error, failed));
      return null;
    } finally {
      if (mounted) update(() => busy = false);
    }
  }

  Future<void> useBuiltinStyle(String id) async {
    final result = await styleRequest({
      'action': 'builtin',
      'id': id,
    }, '内置样式包未能生成');
    final style = (result?['style'] as Map?)?.cast<String, dynamic>();
    if (style != null && mounted) {
      await setChapterStyle(style, '已使用样式包“${style['name']}”');
      applyPackBlocks(result?['blocks']);
      applyPackInsets(result?['insets']);
    }
  }

  Future<void> importStyle() async {
    final path = await widget.pickStylePack?.call();
    if (path == null || !mounted) return;
    final result = await styleRequest({
      'action': 'import',
      'path': path,
    }, '样式包未能导入：请检查文件内容');
    final style = (result?['style'] as Map?)?.cast<String, dynamic>();
    if (style != null && mounted) {
      await setChapterStyle(style, '已导入并使用样式包“${style['name']}”');
      applyPackBlocks(result?['blocks']);
      applyPackInsets(result?['insets']);
    }
  }

  Future<void> exportStyle() async {
    final style = chapterStyle;
    if (style == null) return;
    final path = await widget.pickStylePackDestination?.call(
      style['name'] as String,
    );
    if (path == null || !mounted) return;
    final result = await styleRequest({
      'action': 'export',
      'style': style,
      'blocks': systemBlockStyle == 'styled'
          ? (systemStyles ?? defaultSystemStyles())
          : null,
      // 场景样式（V82）：聊天、书信样式与改过的各场景参数。
      'insets': {
        'chat_block_style': chatBlockStyle,
        'letter_block_style': letterBlockStyle,
        if (insetStyles != null && insetStyles!.isNotEmpty)
          'styles': insetStyles,
      },
      'path': path,
    }, '样式包未能导出：请选择新的文件名');
    if (result != null && mounted) {
      update(() => message = '已导出样式包');
    }
  }

  /// 去掉样式包里的某一项（再选一次样式包可以恢复）。
  Future<void> dropStyleItem(String key) async {
    final style = Map<String, dynamic>.from(chapterStyle!);
    style[key] = key == 'head_images' ? <String>[] : null;
    await setChapterStyle(style, '已更新样式包');
  }

  Widget chapterStyleControls() {
    final d = context.desk;
    final style = chapterStyle;
    final name = style?['name'] as String?;
    final heads = (style?['head_images'] as List?)?.length ?? 0;
    Widget choice(String label, bool selected, VoidCallback? onTap, Key key) =>
        Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 6),
          child: ChoiceChip(
            key: key,
            label: Text(label, style: ui(12.5, c: d.ink)),
            selected: selected,
            onSelected: busy || onTap == null ? null : (_) => onTap(),
          ),
        );
    Widget item(String key, String label, bool present) => Row(
      children: [
        Icon(
          present ? Icons.check_rounded : Icons.remove_rounded,
          size: 15,
          color: present ? d.ink : d.ink3,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label, style: ui(12.5, c: present ? d.ink : d.ink3)),
        ),
        if (present)
          DeskButton(
            '去掉',
            key: ValueKey('layout-chapter-style-drop-$key'),
            quiet: true,
            onPressed: busy ? null : () => dropStyleItem(key),
          ),
      ],
    );
    return Column(
      key: const ValueKey('layout-chapter-style'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('章节样式包', style: ui(12, w: 600, c: d.ink2)),
            const DeskHelp(
              '一套章节装饰：章头图（多张时按章轮换）、标题下装饰线、章末装饰、卷页边框。'
              '内置的“素雅”“古典”是程序画的线条与几何装饰；也可以导入别人做的样式包（.zip），或把本书的样式导出分享。'
              '已设“章首图”时以章首图为准。原文不改，EPUB、AZW3、MOBI、KFX 都生效。小预览里不显示样式包。',
              key: ValueKey('layout-help-chapter-style'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          children: [
            choice(
              '不使用',
              style == null,
              style == null ? null : () => setChapterStyle(null, '已停用样式包'),
              const ValueKey('layout-chapter-style-none'),
            ),
            for (final e in _LayoutPageState.builtinStyles.entries)
              choice(
                e.value,
                name == e.value &&
                    (style?['head_images'] as List?)?.every(
                          (p) => '$p'.contains('builtin-${e.key}-'),
                        ) ==
                        true,
                () => useBuiltinStyle(e.key),
                ValueKey('layout-chapter-style-${e.key}'),
              ),
            if (name != null &&
                !_LayoutPageState.builtinStyles.containsValue(name))
              choice(
                name,
                true,
                null,
                const ValueKey('layout-chapter-style-own'),
              ),
          ],
        ),
        Row(
          children: [
            DeskButton(
              '导入样式包…',
              key: const ValueKey('layout-chapter-style-import'),
              quiet: true,
              onPressed: busy || widget.pickStylePack == null
                  ? null
                  : importStyle,
            ),
            if (style != null)
              DeskButton(
                '导出…',
                key: const ValueKey('layout-chapter-style-export'),
                quiet: true,
                onPressed: busy || widget.pickStylePackDestination == null
                    ? null
                    : exportStyle,
              ),
          ],
        ),
        if (style != null) ...[
          const SizedBox(height: 6),
          item('head_images', heads > 0 ? '章头图 $heads 张' : '章头图', heads > 0),
          item('title_rule', '标题下装饰线', style['title_rule'] != null),
          item('chapter_end', '章末装饰', style['chapter_end'] != null),
          const SizedBox(height: 6),
          Text('卷页边框', style: ui(12, c: d.ink2)),
          const SizedBox(height: 4),
          KeyedSubtree(
            key: const ValueKey('layout-chapter-style-volume_frame'),
            child: DeskSegmented<String>(
              value: style['volume_frame'] as String? ?? 'none',
              options: volumeFrames,
              onChanged: busy
                  ? null
                  : (value) => setChapterStyle({
                      ...style,
                      'volume_frame': value,
                    }, '已更新卷页边框'),
            ),
          ),
        ],
      ],
    );
  }

  /// 章节标题样式（V36，LAY-117）：五个缩略图，点选即改；问号说明分页与适用格式。
  Widget headingControls() {
    final d = context.desk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('章节标题样式', style: ui(12, w: 600, c: d.ink2)),
            const DeskHelp(
              '样式取自市面成品书：EasyPub 经典（原版 EasyPub）、亚马逊官方、出版社、精排两行（网文精排）、日系轻小说。'
              '每章从新的一页开始；样式同时用于 EPUB、AZW3、MOBI、KFX。',
              key: ValueKey('layout-help-heading-style'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, box) {
            final columns = box.maxWidth < 300 ? 2 : 3;
            final width = (box.maxWidth - 8 * (columns - 1)) / columns;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in headingStyles.entries)
                  SizedBox(width: width, child: headingTile(e.key, e.value)),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 场景分隔（V46，LAY-118）：五个选项，问号说明识别规则。
  Widget sceneBreakControls() => foldRow(
    field: 'scene_break_style',
    label: '场景分隔',
    help: const DeskHelp(
      '章内换场的分隔行：整行都是 *、＊、※、◇、☆、＝、～、# 等符号（至少 3 个）时识别。'
      '“……”“——”单独成行仍当正文。原文不改，只改显示；样式同时用于 EPUB、AZW3、MOBI、KFX。',
      key: ValueKey('layout-help-scene-break'),
    ),
    current: sceneBreakStyles[sceneBreakStyle] ?? sceneBreakStyle,
    control: KeyedSubtree(
      key: const ValueKey('layout-scene_break_style'),
      child: DeskSegmented<String>(
        value: sceneBreakStyle,
        options: sceneBreakStyles,
        onChanged: busy ? null : (value) => edit(() => sceneBreakStyle = value),
      ),
    ),
  );

  /// 章首段落（V49，LAY-119）：标题后与场景分隔后的第一段。
  Widget firstParagraphControls() => foldRow(
    field: 'first_paragraph_style',
    label: '章首段落',
    help: const DeskHelp(
      '每章标题后、场景分隔后的第一段正文。“首字放大”同时取消缩进，第一个字放大加粗（不下沉）；'
      '段首是引号等标点时只取消缩进。原文不改；样式同时用于 EPUB、AZW3、MOBI、KFX。',
      key: ValueKey('layout-help-first-paragraph'),
    ),
    current: firstParagraphStyles[firstParagraphStyle] ?? firstParagraphStyle,
    control: KeyedSubtree(
      key: const ValueKey('layout-first_paragraph_style'),
      child: DeskSegmented<String>(
        value: firstParagraphStyle,
        options: firstParagraphStyles,
        onChanged: busy
            ? null
            : (value) => edit(() => firstParagraphStyle = value),
      ),
    ),
  );
}
