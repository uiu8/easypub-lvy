part of '../booksource_page.dart';

/// 与插件进程通信（测试里换成假的）。
abstract class BookSourceApi {
  Future<dynamic> call(String method, [Map<String, dynamic> params = const {}]);
  Stream<Map<String, dynamic>> get events;
}

class PluginBookSourceApi implements BookSourceApi {
  PluginBookSourceApi(this.client);
  final PluginClient client;
  static Future<PluginBookSourceApi> open(PluginRegistry registry) async =>
      PluginBookSourceApi(await registry.client('booksource'));
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => client.call(method, params);
  @override
  Stream<Map<String, dynamic>> get events => client.events;
}

class BookSourceSettings {
  BookSourceSettings({
    this.folder = '',
    this.threads = 8,
    this.autoImport = false,
    this.fill = true,
  });
  String folder;
  int threads;
  bool autoImport;

  /// 失败的章节自动从同一本书的其他书源补全。
  bool fill;
  int maxBooks = 2,
      searchConcurrency = 24,
      quickLimit = 60,
      checkConcurrency = 8;
  bool skipUnhealthy = true,
      includeWebView = false,
      quick = false,
      filterTitle = true,
      removePagePrompts = true;
  String groupBy = 'file';

  /// 下载格式（LIB-215）：txt 只存 TXT；epub 另按全局默认排版生成 EPUB。
  String downloadFormat = 'txt';
  String resultSort = 'overall';
  bool onlyPriority = false, multiSource = true;
  int maxAlternates = 2;

  /// 书架检查更新时同时检查几本；换源补章时同时尝试几个书源。
  int updateConcurrency = 2, alternateConcurrency = 2;
  final Set<String> collapsed = {};

  /// 最近搜索（R1c）：最近的在前，最多 8 条，空的搜索页上可以点着再搜。
  final List<String> recentSearches = [];

  /// 收藏的书源 ID（LIB-219）；只存在书源页设置里。
  final Set<String> favoriteSources = {};

  void rememberSearch(String query) {
    recentSearches
      ..remove(query)
      ..insert(0, query);
    if (recentSearches.length > 8) {
      recentSearches.removeRange(8, recentSearches.length);
    }
  }

  static BookSourceSettings load(String path) {
    try {
      final j =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final settings = BookSourceSettings(
        folder: '${j['folder'] ?? ''}',
        threads: ((j['threads'] as num?) ?? 8).toInt().clamp(1, 32),
        autoImport: j['autoImport'] == true,
        fill: j['fill'] != false,
      );
      settings
        ..resultSort =
            [
              'overall',
              'chapters',
              'latest',
              'sources',
              'speed',
            ].contains(j['resultSort'])
            ? j['resultSort'] as String
            : 'overall'
        ..onlyPriority = j['onlyPriority'] == true
        ..multiSource = j['multiSource'] != false
        ..maxAlternates = ((j['maxAlternates'] as num?) ?? 2).toInt().clamp(
          0,
          4,
        )
        ..updateConcurrency = ((j['updateConcurrency'] as num?) ?? 2)
            .toInt()
            .clamp(1, 8)
        ..alternateConcurrency = ((j['alternateConcurrency'] as num?) ?? 2)
            .toInt()
            .clamp(1, 4)
        ..maxBooks = ((j['maxBooks'] as num?) ?? 2).toInt().clamp(1, 4)
        ..searchConcurrency = ((j['searchConcurrency'] as num?) ?? 24)
            .toInt()
            .clamp(1, 64)
        ..quickLimit = ((j['quickLimit'] as num?) ?? 60).toInt().clamp(1, 500)
        ..checkConcurrency = ((j['checkConcurrency'] as num?) ?? 8)
            .toInt()
            .clamp(1, 64)
        ..skipUnhealthy = j['skipUnhealthy'] != false
        ..includeWebView = j['includeWebView'] == true
        ..quick = j['quick'] == true
        ..filterTitle = j['filterTitle'] != false
        ..removePagePrompts = j['removePagePrompts'] != false
        ..groupBy = j['groupBy'] == 'group' ? 'group' : 'file'
        ..downloadFormat = j['downloadFormat'] == 'epub' ? 'epub' : 'txt';
      settings.collapsed.addAll(
        (j['collapsed'] as List? ?? []).map((e) => '$e'),
      );
      settings.favoriteSources.addAll(
        (j['favoriteSources'] as List? ?? []).map((e) => '$e'),
      );
      settings.recentSearches.addAll(
        (j['recentSearches'] as List? ?? []).map((e) => '$e').take(8),
      );
      return settings;
    } catch (_) {
      return BookSourceSettings();
    }
  }

  void save(String path) {
    try {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'folder': folder,
            'resultSort': resultSort,
            'onlyPriority': onlyPriority,
            'multiSource': multiSource,
            'maxAlternates': maxAlternates,
            'updateConcurrency': updateConcurrency,
            'alternateConcurrency': alternateConcurrency,
            'threads': threads,
            'autoImport': autoImport,
            'downloadFormat': downloadFormat,
            'favoriteSources': favoriteSources.toList(),
            'fill': fill,
            'maxBooks': maxBooks,
            'searchConcurrency': searchConcurrency,
            'quickLimit': quickLimit,
            'checkConcurrency': checkConcurrency,
            'skipUnhealthy': skipUnhealthy,
            'includeWebView': includeWebView,
            'quick': quick,
            'filterTitle': filterTitle,
            'removePagePrompts': removePagePrompts,
            'groupBy': groupBy,
            'collapsed': collapsed.toList(),
            'recentSearches': recentSearches,
          }),
        );
    } catch (_) {}
  }
}

class DownloadTask {
  DownloadTask(this.id, this.title, this.sourceName);
  final String id, title, sourceName;
  String stage = '准备中';
  int done = 0, total = 0, failed = 0;
  String? path, error;
  List<Map<String, dynamic>> failures = [];
  bool finished = false, cancelled = false, imported = false;

  /// 生成 EPUB（LIB-215）：进行中、已生成、失败原因。
  bool epubBusy = false, epubDone = false;
  String? epubError;
  bool outputPreserved = false;
  String status = 'running';
  double speed = 0;
  int? eta;
  int concurrency = 0, retrying = 0, duplicateHeadings = 0;
  bool throttled = false;
  String? libraryKey;
  int sourceCount = 1;
  List<Map<String, dynamic>> chapters = [];

  /// 速度采样（章/秒，R1c）：每次进度记一个，最多 40 个，下载卡片画速度曲线用。
  final List<double> speeds = [];

  void applyProgress(Map p) {
    sourceCount = (p['sourceCount'] as num? ?? 1).toInt();
    if (p['chapter'] is Map) {
      final c = Map<String, dynamic>.from(p['chapter'] as Map);
      chapters.removeWhere((old) => old['index'] == c['index']);
      chapters.add(c);
      chapters.sort((a, b) => _num(a['index']).compareTo(_num(b['index'])));
    }
    done = (p['done'] as num? ?? 0).toInt();
    total = (p['total'] as num? ?? 0).toInt();
    failed = (p['failed'] as num? ?? 0).toInt();
    speed = (p['speed'] as num? ?? 0).toDouble();
    if (speed > 0) {
      speeds.add(speed);
      if (speeds.length > 40) speeds.removeAt(0);
    }
    eta = (p['eta'] as num?)?.toInt();
    concurrency = (p['concurrency'] as num? ?? 0).toInt();
    retrying = (p['retrying'] as num? ?? 0).toInt();
    throttled = p['throttled'] == true;
  }

  void applyResult(Map result) {
    final o = result['outcome'] as Map?;
    if (o == null) return;
    path = o['path']?.toString();
    cancelled = o['cancelled'] == true;
    outputPreserved = o['outputPreserved'] == true;
    failures = [
      for (final f in o['failures'] as List? ?? [])
        Map<String, dynamic>.from(f as Map),
    ];
    done = (o['downloaded'] as num? ?? 0).toInt();
    total = (o['chapters'] as num? ?? 0).toInt();
    duplicateHeadings =
        ((o['quality'] as Map?)?['duplicateHeadings'] as num? ?? 0).toInt();
    libraryKey = result['libraryKey']?.toString();
    finished = true;
    status = cancelled
        ? 'cancelled'
        : failures.isEmpty
        ? 'done'
        : 'failed';
    stage = cancelled
        ? '已取消（已取到的章节保留）'
        : outputPreserved
        ? '更新未完成，原 TXT 已保留；${failures.length} 章待重试'
        : failures.isEmpty
        ? '完成'
        : '完成，${failures.length} 章未取到';
  }
}
