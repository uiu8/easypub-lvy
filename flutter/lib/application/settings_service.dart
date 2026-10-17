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
