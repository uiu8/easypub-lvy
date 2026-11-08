/// An opaque, source-bound refresh proposal. Reading it does not replace a book.
class SourceRefreshPreview {
  SourceRefreshPreview({
    required this.bookId,
    required this.path,
    required this.bodyChanged,
    required this.oldLines,
    required this.newLines,
    this.imagesChanged = false,
    this.imageUpdateSummary = '',
    required Map<String, dynamic> current,
    required Map<String, dynamic> incoming,
  }) : current = Map.unmodifiable(current),
       incoming = Map.unmodifiable(incoming);
  final String bookId, path;
  final bool bodyChanged;
  final int oldLines, newLines;
  final bool imagesChanged;
  final String imageUpdateSummary;
  final Map<String, dynamic> current, incoming;
}

class SourceRefreshResult {
  const SourceRefreshResult(this.message, {this.recoveryPath});
  final String message;
  final String? recoveryPath;
}

abstract interface class SourceRefreshService {
  String? sourceRecoveryPath(String bookId);
  Future<SourceRefreshPreview> previewSourceRefresh(String bookId);
  Future<SourceRefreshResult> applySourceRefresh(
    SourceRefreshPreview preview, {
    required Set<String> fields,
    required bool replaceBody,
    bool replaceImages = false,
  });
}
