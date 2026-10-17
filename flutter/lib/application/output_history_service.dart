import 'package:flutter/foundation.dart';

/// 输出记录与书库中的书的对应关系（V18，OUT-076/077）。
/// 记录自 schema 1 起保存书的标识（原稿路径）与原稿内容标识。
enum OutputBookMatch {
  /// 书库中有这本书，原稿与成品所用的相同。
  current,

  /// 书库中有这本书，但原稿已重新导入且内容不同：成品来自旧版原稿。
  olderSource,

  /// 书库中没有这本书（已移出书库，或原稿换了位置）。
  missing,
}

class OutputRecord {
  const OutputRecord({
    required this.id,
    required this.title,
    required this.format,
    required this.path,
    required this.directory,
    required this.status,
    required this.detail,
    required this.verification,
    required this.startedAt,
    required this.restored,
    required this.busy,
    required this.terminal,
    required this.interrupted,
    this.bytes,
    this.sourcePreserved = false,
    this.verificationCode = '',
    this.bookId = '',
    this.bookTitle = '',
    this.bookMatch = OutputBookMatch.missing,
  });
  final String id, title, format, path, directory, status, detail, verification;
  final DateTime startedAt;
  final bool restored, busy, terminal, interrupted;
  final int? bytes;
  final bool sourcePreserved;
  final String verificationCode;

  /// 书的标识；[bookTitle] 为书库中这本书当前的书名，对应不上时为空。
  final String bookId, bookTitle;
  final OutputBookMatch bookMatch;
}

class OutputRecoveryPreview {
  const OutputRecoveryPreview(
    this.taskId,
    this.outputPath,
    this.transactionDirectory,
    this.publishesStaged,
  );
  final String taskId, outputPath, transactionDirectory;
  final bool publishesStaged;
}

class OutputPackageInspection {
  const OutputPackageInspection({
    required this.status,
    this.detail = '',
    this.title = '',
    this.author = '',
    this.language = '',
    this.metadataStatus = 'unavailable',
    this.expectedMetadata = const {},
    this.metadataMismatches = const [],
    this.spineDocuments = 0,
    this.checkedLinks = 0,
    this.bodyBytes = 0,
    this.headingCount = 0,
    this.imageReferences = 0,
    this.imageResources = 0,
    this.coverInSpine = false,
    this.coverMetadataPresent = false,
    this.cover,
  });
  final String status, detail, title, author, language;
  final String metadataStatus;
  final Map<String, String> expectedMetadata;
  final List<String> metadataMismatches;
  String get metadataComparisonDetail {
    if (metadataStatus == 'matches') return '书名、作者、语言与本次转换回执中的预期一致。';
    if (metadataStatus == 'mismatch') {
      const labels = {'title': '书名', 'author': '作者', 'language': '语言'};
      final actual = {'title': title, 'author': author, 'language': language};
      return metadataMismatches
          .map(
            (key) =>
                '${labels[key] ?? key}：预期“${expectedMetadata[key]}”，实际“${actual[key]}”',
          )
          .join('；');
    }
    return metadataStatus == 'invalid'
        ? '回执中的预期元信息不完整，无法对照。'
        : '此回执缺少预期快照；仅显示实际读取值。';
  }

  final int spineDocuments,
      checkedLinks,
      bodyBytes,
      headingCount,
      imageReferences,
      imageResources;
  final bool coverInSpine;
  final bool coverMetadataPresent;
  final Uint8List? cover;
  bool get inspected => status == 'inspected';
  bool get metadataAvailable =>
      inspected || title.isNotEmpty || author.isNotEmpty || language.isNotEmpty;
}

abstract class OutputHistoryService {
  Listenable get changes;
  String get status;
  int get count;
  List<OutputRecord> page(int offset, {int limit = 50});
  OutputRecord? find(String id);
  Future<void> load();
  Future<void> verify(String id);
  Future<OutputPackageInspection> inspectPackage(String id);
  Future<OutputRecoveryPreview> previewRecovery(String id);
  void cancelRecovery(OutputRecoveryPreview preview);
  Future<void> recover(OutputRecoveryPreview preview);
}

extension OutputHistoryForBook on OutputHistoryService {
  /// 这本书最近的输出，新的在前（LIB-113）。
  List<OutputRecord> recentForBook(String bookId, {int limit = 3}) {
    final result = <OutputRecord>[];
    for (
      var offset = 0;
      offset < count && result.length < limit;
      offset += 50
    ) {
      for (final record in page(offset)) {
        if (record.bookId == bookId &&
            record.bookMatch != OutputBookMatch.missing) {
          result.add(record);
          if (result.length == limit) break;
        }
      }
    }
    return result;
  }
}
