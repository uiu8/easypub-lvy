part of 'layout_page.dart';

extension _LayoutNavigation on _LayoutPageState {
  void changeNavigation(String key, Object value) =>
      edit(() => navigationOptions = {...navigationOptions, key: value});
  Widget navigationControls() {
    if (keepsOriginal) {
      final source = session;
      final enabled = navigationOptions['apply_to_original'] == true;
      if (originalNavigationBook != widget.bookId) {
        originalNavigationBook = widget.bookId;
        originalNavigationFuture = null;
      }
      if (enabled && source is OriginalNavigationSource) {
        originalNavigationFuture ??= (source as OriginalNavigationSource)
            .originalNavigation();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          group('目录与起始位置', [
            optionSwitch(
              '修改原书目录与起始位置',
              enabled,
              (v) => changeNavigation('apply_to_original', v),
              key: const ValueKey('layout-original-navigation'),
              note: '关闭时沿用原书；开启后重新生成目录页，正文不动。',
            ),
          ]),
          if (enabled)
            FutureBuilder<Map<String, dynamic>>(
              future: originalNavigationFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text('无法读取原书目录，请确认原 EPUB 文件仍可访问且包含有效目录。');
                }
                if (!snapshot.hasData) return const Text('正在读取原书目录…');
                final nodes = (snapshot.data!['entries'] as List)
                    .map((n) => Map<String, dynamic>.from(n as Map))
                    .toList();
                return navigationFields(nodes, original: true);
              },
            ),
        ],
      );
    }
    return navigationFields([
      for (final node in outline?.nodes ?? [])
        {'id': node.id, 'title': node.title},
    ]);
  }

  Widget navigationFields(
    List<Map<String, dynamic>> nodes, {
    bool original = false,
  }) {
    final startKey = original ? 'original_start' : 'start_chapter';
    final filter = navigationOptions['toc_filter'] as String;
    RegExp? regex;
    String? error;
    if (navigationOptions['filter_regex'] == true && filter.isNotEmpty) {
      try {
        regex = RegExp(filter);
      } catch (_) {
        error = '正则表达式不完整';
      }
    }
    final removed = filter.isEmpty
        ? 0
        : nodes
              .where(
                (n) =>
                    regex?.hasMatch(n['title'] as String) ??
                    (n['title'] as String).contains(filter),
              )
              .length;
    return group(original ? '原书目录' : '目录与起始位置', [
      optionText(
        '目录标题',
        navigationOptions['toc_title'] as String,
        (v) => changeNavigation('toc_title', v),
        key: ValueKey(('toc-title', widget.bookId, optionsRevision)),
      ),
      optionSegments<String>(
        '书内目录位置',
        navigationOptions['toc_position'] as String,
        const {'front': '书前', 'back': '书尾'},
        (v) => changeNavigation('toc_position', v),
        key: const ValueKey('layout-toc-position'),
      ),
      optionText(
        '目录过滤',
        filter,
        (v) => changeNavigation('toc_filter', v),
        key: ValueKey(('toc-filter', widget.bookId, optionsRevision)),
        error: error,
        note: error == null ? '移除 $removed 条目录项，正文保留' : null,
      ),
      optionSwitch(
        '使用正则表达式',
        navigationOptions['filter_regex'] == true,
        (v) => changeNavigation('filter_regex', v),
        key: const ValueKey('layout-toc-regex'),
      ),
      const SizedBox(height: 6),
      optionSegments<String>(
        '打开书时的起始位置',
        navigationOptions['start'] as String,
        const {
          'cover': '封面',
          'toc': '书内目录',
          'chapter': '第一章',
          'specific': '指定章节',
        },
        (v) {
          // 选“指定章节”时先定在第一章，免得没选章节就去转换。
          final picked = nodes.any(
            (n) => n['id'] == navigationOptions[startKey],
          );
          edit(
            () => navigationOptions = {
              ...navigationOptions,
              'start': v,
              if (v == 'specific' && !picked && nodes.isNotEmpty)
                startKey: nodes.first['id'],
            },
          );
        },
        key: const ValueKey('layout-start-position'),
      ),
      if (navigationOptions['start'] == 'specific')
        optionChoice<String>(
          '起始章节',
          nodes.any((n) => n['id'] == navigationOptions[startKey])
              ? navigationOptions[startKey] as String
              : null,
          {
            for (final node in nodes)
              node['id'] as String: node['title'] as String,
          },
          (v) => changeNavigation(startKey, v),
          key: const ValueKey('layout-start-chapter'),
          searchable: true,
        ),
    ]);
  }
}
