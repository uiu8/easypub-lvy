// 检查结果缓存的统计与手动清理（V19，CHK-061 / SET-065）。
// 只删缓存文件，不碰书稿；先预览将删除的份数，确认后才删除。

/// 一次统计的结果；[CheckCacheService.cleanCheckCache] 只删除其中列出的文件。
class CheckCachePreview {
  const CheckCachePreview({
    required this.total,
    required this.totalBytes,
    required this.unattributed,
    required this.unattributedBytes,
    required this.older,
    required this.olderBytes,
    required this.kept,
    required this.files,
    this.lastCleanup,
  });

  /// 缓存文件总数与大小。
  final int total, totalBytes;

  /// 无法归属到书的旧报告（V19 前写入、或无法读取），且不是书库中某本书当前稿的结果。
  final int unattributed, unattributedBytes;

  /// 各书当前稿与上一稿以外更早的报告。
  final int older, olderBytes;

  /// 保留的份数。
  final int kept;

  /// 将删除的文件：路径、预览时的大小与修改时间。删除前逐个核对未变。
  final List<({String path, int bytes, DateTime modified})> files;

  /// 上次清理：时间、删除份数与大小；没有清理过时为 null。
  final ({DateTime at, int deleted, int bytes})? lastCleanup;

  int get removable => unattributed + older;
  int get removableBytes => unattributedBytes + olderBytes;
}

class CheckCacheCleanupResult {
  const CheckCacheCleanupResult(this.deleted, this.bytes, this.skipped);

  /// 实际删除的份数与大小。
  final int deleted, bytes;

  /// 预览后发生变化而没有删除的份数（文件已变、已不存在，或又成了当前稿的结果）。
  final int skipped;
}

abstract interface class CheckCacheService {
  Future<CheckCachePreview> previewCheckCacheCleanup();
  Future<CheckCacheCleanupResult> cleanCheckCache(CheckCachePreview preview);
}
