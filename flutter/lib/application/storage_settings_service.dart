// 存储位置（V104，SET-108–112 界面）：设置页“存储位置”一组用的服务。后端与协议见
// docs/evidence/v104-storage-locations-20261024.md（SET-103–107）。
import 'storage_locations.dart';

/// 书库提供的存储位置操作。只有生产入口初始化过存储布局时可用；测试与未初始化时不显示这一组。
abstract interface class StorageSettingsService {
  bool get storageAvailable;

  /// 布局：data_root、cache_layout、cache_root、suggested_cache_root、paths、image_mode、
  /// pending_restart、pending_data_root、startup_error。
  Future<Map<String, dynamic>> storageStatus();

  /// 各类占用：cache（kind、path、bytes）与 data（kind、path、bytes）；同一类可能有多个位置。
  Future<Map<String, dynamic>> storageStats();

  /// 开始搬家，返回 job_id；之后用 [storageMoveProgress] 轮询或取消。
  Future<Map<String, dynamic>> moveStorage(String target);
  Future<Map<String, dynamic>> storageMoveProgress(
    String jobId, {
    bool cancel = false,
  });
  Future<void> setCacheRoot(String path);
  Future<void> setImageMode(String mode);

  /// 按类清理，返回各类各位置的 deleted_bytes、skipped 等。
  Future<Map<String, dynamic>> cleanCache(List<String> kinds);

  /// 把已有书引用的外部图片复制进软件：copied 为更新的引用数，missing 逐项列出找不到的。
  Future<Map<String, dynamic>> copyReferencedImages();
}

/// 缓存类别的名称；[protectedCacheKinds] 里的这一版不清理。
const cacheKindLabels = {
  'content_preview': '实际生成预览',
  'conversion_work': '转换中间文件',
  'catalog': '参考目录缓存',
  'conversion_covers': '转换时生成的封面',
  'imports': 'EPUB 解包',
  'generated_covers': '生成的文字封面',
  'kindle_preview': '真机预览',
};

/// 书库或外部浏览器可能还在引用，后端一律保留。
const protectedCacheKinds = {'imports', 'generated_covers'};

const dataKindLabels = {
  'settings': '工作区与设置',
  'assets': '复制进来的图片',
  'plugins': '插件程序',
  'plugin_data': '插件数据',
  'book_sources': '书源',
  'credentials': '登录凭据',
};

/// 后端固定错误码的说明（不含路径与原文）。
String storageErrorText(Object error) {
  final code = error is StorageException ? error.code : '$error';
  return switch (code) {
    'storage_invalid_path' => '这个位置不可用，请换一个本机文件夹。',
    'storage_link_rejected' => '不能选快捷方式或链接文件夹，请选真实的文件夹。',
    'storage_target_not_empty' => '目标文件夹不是空的。请新建一个空文件夹再选。',
    'storage_overlapping_roots' => '新位置不能放在原数据或缓存文件夹里面，也不能包含它们。',
    'storage_target_not_writable' => '这个文件夹不能写入，请换一个位置或检查权限。',
    'storage_space_unknown' => '读不出目标磁盘的剩余空间，请换一个本机磁盘。',
    'storage_no_space' => '目标磁盘空间不够。',
    'storage_io_error' => '读写文件时出错，原位置没有改动。',
    'storage_verify_failed' => '复制后核对不一致，已放弃这次搬家，原位置没有改动。',
    'storage_source_changed' => '复制期间数据有变化，已放弃这次搬家。请先停下手上的操作再试。',
    'storage_pointer_write_failed' => '记录新位置时出错，原位置没有改动。',
    'storage_not_initialized' => '存储位置还没有准备好，请重启软件后再试。',
    'storage_busy' => '有任务或搬家正在进行，等它结束再试。',
    'storage_restart_required' => '上一次的更改要重启后才生效，请先重启。',
    'storage_plugins_running' => '插件没能停下来，请在插件页停用后再试。',
    'storage_flush_failed' => '保存当前工作区失败，没有开始搬家。',
    'storage_cancelled' => '已取消，原位置没有改动。',
    'storage_job_missing' => '找不到这次搬家任务，请重新开始。',
    'storage_migration_stale' => '上次搬家后又继续编辑过，新位置的副本已过期，所以仍在使用原位置。可以重新搬一次。',
    'storage_invalid_config' => '记录数据位置的文件损坏了。',
    _ => '操作没有完成（$code），原位置没有改动。',
  };
}

String formatStorageBytes(num bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// 把同一类的多个位置合并：返回类别 → (总字节, 位置列表)；同一路径只算一次。
Map<String, (int, List<String>)> groupStorageRows(List rows) {
  final result = <String, (int, List<String>)>{};
  for (final r in rows.whereType<Map>()) {
    final kind = '${r['kind']}';
    final path = '${r['path']}';
    final (bytes, places) = result[kind] ?? (0, <String>[]);
    if (places.contains(path)) continue;
    result[kind] = (
      bytes + ((r['bytes'] as num?)?.toInt() ?? 0),
      [...places, path],
    );
  }
  return result;
}
