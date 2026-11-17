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
        note: '正则使用转换引擎的规则，不支持环视和反向引用。',
      ),
      _NavigationFilterStatus(
        source: session is NavigationFilterSource
            ? session as NavigationFilterSource
            : null,
        filter: filter,
        regex: navigationOptions['filter_regex'] == true,
        titles: [for (final node in nodes) node['title'] as String],
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

class _NavigationFilterStatus extends StatefulWidget {
  const _NavigationFilterStatus({
    required this.source,
    required this.filter,
    required this.regex,
    required this.titles,
  });
  final NavigationFilterSource? source;
  final String filter;
  final bool regex;
  final List<String> titles;
  @override
  State<_NavigationFilterStatus> createState() =>
      _NavigationFilterStatusState();
}

class _NavigationFilterStatusState extends State<_NavigationFilterStatus> {
  Future<int>? result;
  String signature = '';
  Timer? debounce;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void didUpdateWidget(covariant _NavigationFilterStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) signature = '';
    refresh();
  }

  void refresh() {
    final next = jsonEncode([widget.filter, widget.regex, widget.titles]);
    if (next == signature) return;
    signature = next;
    debounce?.cancel();
    final ticket = ++generation;
    result = null;
    if (widget.source == null) return;
    debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || ticket != generation) return;
      final pending = widget.source!.previewNavigationFilter(
        widget.filter,
        widget.regex,
        widget.titles,
      );
      setState(() {
        result = pending;
      });
    });
  }

  @override
  void dispose() {
    debounce?.cancel();
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.source == null) return const Text('过滤结果将在转换时计算。');
    if (result == null) return const Text('正在核对过滤规则…');
    return FutureBuilder<int>(
      key: ValueKey(signature),
      future: result,
      builder: (_, snapshot) => Text(
        snapshot.hasError
            ? '过滤规则未通过转换引擎检查，请修改后重试。'
            : snapshot.hasData
            ? '移除 ${snapshot.data} 条目录项，正文保留'
            : '正在核对过滤规则…',
      ),
    );
  }
}
