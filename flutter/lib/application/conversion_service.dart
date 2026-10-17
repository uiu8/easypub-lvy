import 'package:flutter/foundation.dart';

class ConversionRequest {
  ConversionRequest({
    required List<String> books,
    required this.directory,
    required this.format,
    this.engine = '',
    this.language = '',
    this.generateCover = false,
    this.runChecks = true,
    Set<String> keepOriginalEpub = const {},
  }) : books = List.unmodifiable(books),
       keepOriginalEpub = Set.unmodifiable(keepOriginalEpub);
  final List<String> books;

  /// 保持原格式转换的 EPUB 书（V27，OUT-079）：用修补后的原 EPUB，不用软件排版。
  final Set<String> keepOriginalEpub;
  final String directory, format, engine;
  final bool generateCover;
  final bool runChecks;
  final String language;
}

class ConversionFinding {
  const ConversionFinding(
    this.bookId,
    this.title,
    this.level,
    this.detail,
    this.repairPage, {
    this.category = 'general',
    this.isCoverIssue = false,
  });
  final String bookId, title, level, detail;
  final String? repairPage;
  final String category;
  final bool isCoverIssue;
}

class ConversionCheckGroup {
  ConversionCheckGroup(this.key, this.title, List<ConversionFinding> items)
    : items = List.unmodifiable(items);
  final String key, title;
  final List<ConversionFinding> items;
  static const severity = {'pass': 0, 'info': 1, 'warning': 2, 'blocking': 3};
  ConversionFinding get primary => items.reduce(
    (a, b) => (severity[a.level] ?? 1) >= (severity[b.level] ?? 1) ? a : b,
  );
  String get level => primary.level;
}

class ConversionOutput {
  const ConversionOutput(
    this.bookId,
    this.title,
    this.path,
    this.status, {
    this.phase = 'waiting',
    this.format = '',
    this.detail = '',
    this.taskId,
    this.batchId,
    this.coverPath,
    this.coverCrop,
    this.statusAvailable = true,
    this.cancelRequested = false,
    this.stopRequested = false,
    this.historical = false,
    this.checksEnabled,
    this.coverThumbnail,
  });
  final String bookId, title, path, status;
  final String phase, format, detail;
  final String? taskId, batchId;
  final bool statusAvailable, cancelRequested;

  /// Queue stop request, separate from native acceptance of cancellation.
  final bool stopRequested;
  bool get waitingForCurrentFile =>
      running && stopRequested && !cancelRequested;
  final bool historical;
  final bool? checksEnabled;
  final Uint8List? coverThumbnail;

  /// Cover reference captured in this batch's publication request, not proof
  /// of the cover embedded in the finished output.
  final String? coverPath;
  final Map<String, dynamic>? coverCrop;
  bool get complete => phase == 'complete';
  bool get failed => phase == 'failed' || phase == 'interrupted';
  bool get running => const {
    'preparing',
    'prepared',
    'converting',
    'checking',
    'publishing',
  }.contains(phase);
}

class ConversionPreview {
  ConversionPreview(
    List<ConversionFinding> findings,
    List<ConversionOutput> outputs, {
    required this.previewed,
    Map<String, String> bookTitles = const {},
  }) : findings = List.unmodifiable(findings),
       bookTitles = Map.unmodifiable(bookTitles),
       outputs = List.unmodifiable(outputs);
  final Map<String, String> bookTitles;
  String bookTitle(String id) =>
      bookTitles[id] ??
      outputs.where((o) => o.bookId == id).firstOrNull?.title ??
      id;
  final List<ConversionFinding> findings;
  final List<ConversionOutput> outputs;
  final bool previewed;
  List<ConversionCheckGroup> get groups {
    const labels = {
      'source': '源文件与编码',
      'chapters': '章节与目录',
      'cleanup': '文本清理',
      'resources': '封面与插图',
      'metadata': '书目信息',
      'destination': '输出位置与同名文件',
      'converter': '转换器与目标格式',
    };
    final buckets = <String, List<ConversionFinding>>{};
    for (final finding in findings) {
      final key = finding.category == 'general'
          ? finding.title
          : finding.category;
      (buckets[key] ??= []).add(finding);
    }
    return List.unmodifiable([
      for (final key in {...labels.keys, ...buckets.keys})
        if (buckets.containsKey(key))
          ConversionCheckGroup(key, labels[key] ?? key, buckets[key]!),
    ]);
  }

  bool get blocked => findings.any((f) => f.level == 'blocking');
  bool get needsAcknowledgement => findings.any((f) => f.level == 'warning');
}

abstract class ConversionSession {
  Listenable get changes;
  bool get busy;
  ConversionRequest? get request;
  List<ConversionOutput> get outputs;
  bool isCurrent(ConversionPreview preview);
  Future<ConversionPreview> preview(ConversionRequest request);
  Future<List<ConversionOutput>> commit(
    ConversionPreview preview, {
    required bool acknowledgeWarnings,
  });
  Future<void> cancel();
  void dispose();
}

/// Current batch plus a bounded recent-history window. Complete history remains
/// available through OutputHistoryService; it never changes commit results.
abstract interface class ConversionTaskFeed {
  Future<void> loadTaskFeed();
  List<ConversionOutput> get taskFeed;
  String get taskFeedStatus;
}

/// 按与实际转换相同的命名规则给出将生成的文件名（不含同名时追加的序号），
/// 供转换页列出“本次将生成”的文件（OUT-073）。
abstract interface class ConversionNaming {
  String plannedFileName(String bookId, String format);
}

/// Restores only explicit terminal task identities from one original batch.
/// The returned preview must still be confirmed through ConversionSession.commit.
abstract interface class ConversionRetryService {
  Future<ConversionPreview> previewRetry(List<String> taskIds);
}
