// 书源下载插件的页面（PLG-010–022）：搜索 / 书源 / 下载。插件进程不可用时整页给出原因。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../application/plugin_host.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../page_parts.dart';
import '../tokens.dart';
import '../widgets.dart';

part 'booksource/models.dart';
part 'booksource/search.dart';
part 'booksource/sources.dart';
part 'booksource/shelf.dart';
part 'booksource/queue.dart';
part 'booksource/settings.dart';
part 'booksource/management.dart';
part 'booksource/network.dart';
part 'booksource/subscriptions.dart';
part 'booksource/result_order.dart';

class BookSourcePage extends StatefulWidget {
  const BookSourcePage({
    super.key,
    required this.openApi,
    required this.settingsPath,
    required this.chooseFolder,
    required this.chooseSourceFile,
    required this.importToLibrary,
    this.openFolder,
    this.openPlugins,
  });
  final Future<BookSourceApi> Function() openApi;
  final String settingsPath;
  final Future<String?> Function() chooseFolder;
  final Future<String?> Function() chooseSourceFile;

  /// 把下载好的 TXT 加入书库，返回失败原因（成功为 null）。
  final Future<String?> Function(String path) importToLibrary;
  final void Function(String path)? openFolder;
  final VoidCallback? openPlugins;

  @override
  State<BookSourcePage> createState() => _BookSourcePageState();
}

class _BookSourcePageState extends State<BookSourcePage> {
  void update(VoidCallback action) {
    if (mounted) setState(action);
  }

  BookSourceApi? api;
  String? fatal;
  String tab = 'search';
  late final BookSourceSettings settings = BookSourceSettings.load(
    widget.settingsPath,
  );
  StreamSubscription<Map<String, dynamic>>? sub;

  // 搜索
  final query = TextEditingController();
  bool searching = false;
  String searchStatus = '';
  String? activeSearchId, sourceOnly;
  String searchScope = '';
  bool includeSkippedOnce = false, batchBusy = false;
  final Set<String> selectedBooks = {};
  List<Map<String, dynamic>> results = [];
  final Map<String, Map<String, dynamic>> resultIndex = {};
  final Map<String, Map<String, dynamic>> searchPages = {};
  final List<Map<String, dynamic>> pendingSearchResults = [];
  Map<String, dynamic>? pendingSearchProgress;
  Timer? searchRefresh;
  int? selected;
  int selectedSource = 0;
  List<dynamic>? toc;
  bool loadingToc = false;
  String? detailError;
  final from = TextEditingController(), to = TextEditingController();

  // 书源
  List<Map<String, dynamic>> sources = [];
  final sourceFilter = TextEditingController();
  String? sourceMessage;
  final checkKeyword = TextEditingController();
  final Set<String> selectedSources = {};
  String sourceStatusFilter = 'all', sourceSort = 'manual';
  bool pinging = false;
  bool importingSource = false;
  final Set<String> sourceTags = {};
  bool recommendedOnly = false, enriching = false;

  // 下载
  final List<DownloadTask> tasks = [];
  final Set<String> importing = {};

  // 书源校验与书架
  String? checkStatus;
  bool checking = false;
  List<Map<String, dynamic>> shelf = [];
  bool shelfBusy = false;
  String? shelfMessage;

  // 插件端保存的偏好：导入书源方式、书架定时检查（小时，0 为关闭）。
  Map<String, dynamic> importOptions = const {
    'position': 'bottom',
    'overrideName': true,
    'overrideGroup': false,
  };
  int autoCheckHours = 0;

  /// 上次定时检查的时间（秒）；0 表示还没检查过。
  int autoCheckLast = 0;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final a = await widget.openApi();
      sub = a.events.listen(_onEvent);
      api = a;
      await _loadSources();
      await _loadQueue();
      await _loadPluginPreferences();
    } catch (e) {
      fatal = '$e';
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    sub?.cancel();
    searchRefresh?.cancel();
    query.dispose();
    from.dispose();
    to.dispose();
    sourceFilter.dispose();
    checkKeyword.dispose();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['event']) {
      case 'search.progress':
      case 'search.result':
        if (e['searchId'] != null && e['searchId'] != activeSearchId) return;
        _queueSearchEvent(e);
      case 'search.enrich':
        if (e['searchId'] != null && e['searchId'] != activeSearchId) return;
        setState(() => _applyEnrichment(e));
      case 'queue.changed':
        setState(() => _applyQueue(e['queue']));
      case 'ping.result':
      case 'check.result':
        setState(() {
          for (final source in sources) {
            if (source['id'] == e['id']) {
              source['health'] = e['health'];
              source[e['event'] == 'ping.result' ? 'ping' : 'check'] = {
                'ok': e['ok'],
                'ms': e['ms'],
                'error': e['error'],
                'stage': e['stage'],
                'chapters': e['chapters'],
                'sampled': e['sampled'],
                'chars': e['chars'],
                'cause': e['cause'],
                'unsupported': e['unsupported'],
              };
              source['cause'] = e['cause'];
            }
          }
        });
      case 'library.autoChecked':
        setState(() {
          autoCheckLast = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          shelfMessage = (e['newChapters'] as num? ?? 0) > 0
              ? '定时检查：发现 ${e['newChapters']} 个新章节，可在书架里追更。'
              : '定时检查完成，没有新章节。';
        });
        // 书架列表跟着刷新，让新章节标记立即可见。
        _loadShelf();
      case 'subscriptions.changed':
        setState(() => sourceMessage = '订阅检查已完成，可在“订阅与更新”查看差异后确认。');
      case 'ping.progress':
        setState(
          () =>
              checkStatus = '已测速 ${e['done']}/${e['total']} 个，可连接 ${e['ok']} 个',
        );
      case 'check.progress':
        setState(
          () =>
              checkStatus = '已校验 ${e['done']}/${e['total']} 个，可用 ${e['ok']} 个',
        );
      case 'download.progress':
        final t = _task(e['taskId']);
        if (t == null) return;
        setState(() {
          if (e['stage'] == 'fill') {
            t.stage = '从其他书源补全失败的章节';
          } else if (e['stage'] == 'switch') {
            t.stage = '这个书源读不到目录，换下一个书源';
          } else if (e['stage'] == 'toc') {
            t.stage = '读取目录';
          } else {
            final p = e['progress'] as Map<String, dynamic>;
            t.stage = '下载章节';
            t.applyProgress(p);
          }
        });
      case 'download.done':
        final t = _task(e['taskId']);
        if (t == null) return;
        setState(() {
          t.finished = true;
          if (e['error'] != null) {
            t.error = '${e['error']}';
            t.stage = '失败';
            t.status = 'failed';
          } else {
            t.applyResult(e['result'] as Map);
          }
        });
        if (t.path != null && settings.autoImport && !t.cancelled) _import(t);
    }
  }

  DownloadTask? _task(dynamic id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _loadSources() async {
    final list = await api!.call('sources.list') as List;
    sources = [for (final s in list) Map<String, dynamic>.from(s as Map)];
  }

  // ---------- 搜索 ----------

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final body = fatal != null
        ? Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DeskNote('书源下载插件没有运行：$fatal', tone: Tone.warn),
                if (widget.openPlugins != null) ...[
                  const SizedBox(height: 12),
                  DeskButton('打开插件管理', onPressed: widget.openPlugins),
                ],
              ],
            ),
          )
        : api == null
        ? const Center(child: CircularProgressIndicator())
        : switch (tab) {
            'sources' => _sourcesTab(context),
            'shelf' => _shelfTab(context),
            'downloads' => _downloadsTab(context),
            'settings' => _settingsTab(context),
            _ => _searchTab(context),
          };
    return DeskPageFrame(
      header: DeskPageHeader(
        title: '书源下载',
        subtitle: '按你导入的书源搜索并下载，内容版权归原网站与作者。',
        actions: [
          DeskSegmented<String>(
            key: const ValueKey('booksource-tabs'),
            value: tab,
            options: {
              'search': '搜索',
              'shelf': '书架',
              'sources':
                  '书源 ${sources.where((s) => s['enabled'] == true).length}/${sources.length}',
              'downloads': tasks.isEmpty
                  ? '下载'
                  : '下载 ${tasks.where((t) => !t.finished).length}',
              'settings': '设置',
            },
            onChanged: api == null
                ? null
                : (v) {
                    setState(() => tab = v);
                    if (v == 'shelf') _loadShelf();
                  },
          ),
        ],
      ),
      child: body,
    );
  }
}
