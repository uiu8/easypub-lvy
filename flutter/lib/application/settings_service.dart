import 'package:flutter/foundation.dart';

@immutable
class SettingsSnapshot {
  const SettingsSnapshot({
    required this.configuration,
    required this.status,
    required this.busy,
    required this.loaded,
    required this.theme,
    required this.reducedMotion,
  });
  final Map<String, dynamic> configuration;
  final String status;
  final bool busy, loaded, reducedMotion;
  final String theme;
}

/// 左栏可以收起的页面（V109，设置“外观与交互”）：键 → 名称与说明。主流程页面不能收起。
const navOptionalPages = {
  'overview': ('概览', '本书的统计与状态汇总'),
  'folders': ('文件夹', '常用文件夹与自动入库'),
  'booksource': ('书源', '书源下载插件启用后才出现'),
  'plugins': ('插件', '安装、启用与管理插件'),
};

/// 设置里收起的页面；没设置过时只收起概览。
Set<String> navHiddenPages(Map<String, dynamic> configuration) =>
    switch (configuration['nav_hidden_pages']) {
      final List list => {
        for (final v in list)
          if (v is String && navOptionalPages.containsKey(v)) v,
      },
      _ => const {'overview'},
    };

abstract class SettingsService {
  ValueListenable<SettingsSnapshot> get snapshot;
  Future<bool> load();
  Future<bool> savePatch(Map<String, dynamic> patch);
  Future<Map<String, dynamic>> inspectLegacy(String path);
  void dispose();
}

/// Optional capability for settings implementations that own an on-disk
/// immutable generation store. The returned path is a new backup snapshot.
abstract class SettingsBackupService {
  Future<String?> createBackup(String destination);
  Future<Map<String, dynamic>?> inspectBackup(String path);
  Future<bool> restoreBackup(String path);
}

abstract interface class CleanupPresetCatalog {
  Future<List<Map<String, dynamic>>> cleanupPresets();
}
