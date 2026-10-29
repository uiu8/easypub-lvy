// 书源下载插件的页面（PLG-010–022）：搜索 / 书源 / 下载。插件进程不可用时整页给出原因。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/plugin_host.dart';
import '../controls/controls.dart';
import '../dialogs.dart';
import '../errors.dart';
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
part 'booksource/source_panes.dart';
part 'booksource/interactions.dart';
part 'booksource/fqnovel.dart';
part 'booksource/favorites.dart';

class BookSourcePage extends StatefulWidget {
  const BookSourcePage({
    super.key,
    required this.openApi,
    required this.settingsPath,
    required this.chooseFolder,
    required this.chooseSourceFile,
    required this.importToLibrary,
    this.exportEpub,
    this.outdatedInLibrary,
    this.refreshInLibrary,
    this.openFolder,
    this.openPlugins,
  });
  final Future<BookSourceApi> Function() openApi;
  final String settingsPath;
  final Future<String?> Function() chooseFolder;
  final Future<String?> Function() chooseSourceFile;

  /// 把下载好的 TXT 加入书库，返回失败原因（成功为 null）。
  final Future<String?> Function(String path) importToLibrary;

  /// 把下载好的 TXT 加入书库并按全局默认排版生成 EPUB（LIB-215）；不提供时不显示 EPUB 选项。
  final Future<({bool imported, String? error})> Function(String path)?
  exportEpub;

  /// 加入书库后，书库里已有这本书、下载内容却变了（追更、重新整理），草稿保留没采用（V111）。
  final bool Function(String path)? outdatedInLibrary;

  /// 打开“刷新来源”对比确认；返回书库里是否已是新版本。
  final Future<bool> Function(String path)? refreshInLibrary;
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
  String? activeSearchId;

  /// 搜索范围：'' 全部；'f:文件'；'g:分组'；'fav' 收藏的书源；'pick' 选中的书源（pickedSources）。
  String searchScope = '';
  final Set<String> pickedSources = {};
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

  // 书源页的标签筛选是否展开。
  bool showSourceFilters = false;

  // 书源页三栏（R1c）：树选中的节点、树里展开的文件、检查面板里的书源、检查面板是否显示。
  String sourceNode = '';
  final Set<String> treeOpen = {};
  String? focusedSource;
  bool sourceInspectorShown = false;

  // 书架上展开了多条下载记录的书（书名 + 作者）。
  final Set<String> shelfExpanded = {};

  // 下载
  final List<DownloadTask> tasks = [];
  final Set<String> importing = {};

  // 书源校验与书架
  String? checkStatus;
  bool checking = false;

  /// 正在“去验证”（单源交互式校验）的书源：书源 ID → 本轮 checkId（LIB-279）。
  final Map<String, String> verifying = {};
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

  /// 章节缓存位置（V107）：路径、默认路径、是否自选、占用字节与书数；旧版插件没有时为空。
  Map<String, dynamic>? cacheLocation;
  bool cacheMoving = false;
  String? cacheMessage;

  /// 上次定时检查的时间（秒）；0 表示还没检查过。
  int autoCheckLast = 0;

  // 书源交互（V97）：已启用交互的书源、等待回复的弹窗、后端已关闭的请求、登录中提交的字段。
  final Set<String> interactionSources = {};
  final Map<String, BuildContext> interactionDialogs = {};
  final Set<String> interactionClosed = {};
  final Map<String, Map<String, String>> loginDrafts = {};

  // 登录框打开时，书源脚本的提示（如切换模式后的 longToast）显示在登录框里。
  String? loginDialogSource;
  final loginNotice = ValueNotifier<String?>(null);

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
      fatal = bookSourceErrorText(e, '书源插件启动未完成，请检查插件文件是否完整。');
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _disableInteractions();
    loginNotice.dispose();
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
      case 'source.interaction':
        _onInteraction(e);
      case 'source.interaction.closed':
        _onInteractionClosed(e);
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
        if (t.path == null || t.cancelled) return;
        if (settings.downloadFormat == 'epub' && widget.exportEpub != null) {
          _exportEpub(t);
        } else if (settings.autoImport) {
          _import(t);
        }
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
    // R1c：页签改为左侧竖排导航（带数量与书源健康概况），内容区占满右侧。
    return DeskPageFrame(
      header: const DeskPageHeader(
        title: '书源下载',
        subtitle: '按你导入的书源搜索并下载，内容版权归原网站与作者。',
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _nav(context),
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _nav(BuildContext context) {
    final d = context.desk;
    final running = tasks.where((t) => !t.finished).length;
    final ok = sources.where((s) => (s['check'] as Map?)?['ok'] == true).length;
    final failed = sources
        .where((s) => (s['check'] as Map?)?['ok'] == false)
        .length;
    final entries = [
      ('search', '搜索', Icons.search_rounded, null),
      ('shelf', '书架', Icons.auto_stories_outlined, null),
      (
        'sources',
        '书源 ${sources.where((s) => s['enabled'] == true).length}/${sources.length}',
        Icons.extension_outlined,
        null,
      ),
      (
        'downloads',
        tasks.isEmpty ? '下载' : '下载 $running',
        Icons.download_rounded,
        running > 0 ? d.accent : null,
      ),
      ('settings', '设置', Icons.tune_rounded, null),
    ];
    return Container(
      key: const ValueKey('booksource-tabs'),
      width: 148,
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: d.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (id, label, icon, badge) in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: tab == id ? d.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: ValueKey('booksource-tab-$id'),
                  onTap: api == null
                      ? null
                      : () {
                          setState(() => tab = id);
                          if (id == 'shelf') _loadShelf();
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          icon,
                          size: 18,
                          color: tab == id ? d.accent : d.ink2,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(
                              13,
                              w: tab == id ? 650 : 500,
                              c: badge ?? (tab == id ? d.ink : d.ink2),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          if (sources.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('书源健康', style: ui(11, w: 600, c: d.ink3)),
                  const SizedBox(height: 6),
                  for (final (label, count, color) in [
                    ('可用', ok, d.add),
                    ('未通过', failed, d.pen),
                    ('未测', sources.length - ok - failed, d.ink3),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('$label $count', style: ui(11.5, c: d.ink2)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
