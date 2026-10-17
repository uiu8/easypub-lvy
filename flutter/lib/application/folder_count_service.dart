class FolderCount {
  const FolderCount(this.count, this.complete, this.detail);
  final int count;
  final bool complete;
  final String detail;
}

/// Counts immediate ebook files, not imported books or validated publications.
abstract interface class FolderCountService {
  Future<FolderCount> countFolder(
    String path, {
    required bool Function() cancelled,
  });
}
