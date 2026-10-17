// 书库中的书、勾选与收藏文件夹（V20 从 PrototypeState 拆出）。移出与恢复要协调所有领域，仍在 PrototypeState。
// 只通过 PrototypeState 的公开接口读写全局设置；行为与拆分前相同。
import 'dart:convert';
import 'dart:io';

import '../prototype/folder_scan.dart';
import '../prototype/prototype_state.dart';

class ShelfStore {
  ShelfStore(this._core);
  final PrototypeState _core;

  final List<String> favoriteFolders = [];

  Future<bool> addFavoriteFolder(String path) async {
    final normalized = PrototypeState.normalizeFolderPath(path);
    if (normalized.isEmpty || !Directory(normalized).existsSync()) return false;
    if (favoriteFolders.any(
      (item) => item.toLowerCase() == normalized.toLowerCase(),
    )) {
      return true;
    }
    final next = [...favoriteFolders, normalized];
    return saveFavoriteFolders(next);
  }

  Future<bool> removeFavoriteFolder(String path) async {
    final normalized = PrototypeState.normalizeFolderPath(path);
    final next = favoriteFolders
        .where((item) => item.toLowerCase() != normalized.toLowerCase())
        .toList();
    if (next.length == favoriteFolders.length) return true;
    return saveFavoriteFolders(next);
  }

  Future<bool> relocateFavoriteFolder(String oldPath, String newPath) async {
    final normalized = PrototypeState.normalizeFolderPath(newPath);
    if (normalized.isEmpty || !await Directory(normalized).exists()) {
      return false;
    }
    final oldKey = folderImportPathKey(oldPath);
    final newKey = folderImportPathKey(normalized);
    if (!favoriteFolders.any((item) => folderImportPathKey(item) == oldKey)) {
      return false;
    }
    final seen = <String>{};
    final next = <String>[];
    for (final folder in favoriteFolders) {
      final value = folderImportPathKey(folder) == oldKey ? normalized : folder;
      if (seen.add(folderImportPathKey(value))) next.add(value);
    }
    final aliases = favoriteFolderNames;
    final oldAlias = aliases.remove(oldKey);
    if (oldAlias != null) aliases.putIfAbsent(newKey, () => oldAlias);
    return saveFavoriteFolders(next, names: aliases);
  }

  Map<String, String> get favoriteFolderNames => {
    for (final entry
        in ((_core.globalConfiguration['favorite_folder_names'] as Map?) ?? {})
            .entries)
      folderImportPathKey(entry.key as String): entry.value as String,
  };

  Future<bool> renameFavoriteFolder(String path, String name) async {
    final key = folderImportPathKey(path);
    final value = name.trim();
    if (value.isEmpty ||
        utf8.encode(value).length > 512 ||
        value.contains('\u0000') ||
        !favoriteFolders.any((p) => folderImportPathKey(p) == key)) {
      return false;
    }
    return saveFavoriteFolders(
      [...favoriteFolders],
      names: {...favoriteFolderNames, key: value},
    );
  }

  Future<bool> saveFavoriteFolders(
    List<String> folders, {
    Map<String, String>? names,
  }) async {
    final keys = folders.map(folderImportPathKey).toSet();
    final aliases = Map<String, String>.from(names ?? favoriteFolderNames)
      ..removeWhere((key, _) => !keys.contains(key));
    if (_core.settingsDirectory == null) {
      _core.change(() {
        _core.globalConfiguration['favorite_folder_names'] = aliases;
        favoriteFolders
          ..clear()
          ..addAll(folders);
      });
      return true;
    }
    if (!_core.globalSettingsLoaded && !await _core.loadGlobalSettings()) {
      return false;
    }
    final ok = await _core.saveGlobalConfiguration(
      Map<String, dynamic>.from(_core.globalConfiguration)
        ..['favorite_folders'] = folders
        ..['favorite_folder_names'] = aliases,
      _core.globalSettingsToken,
    );
    if (ok) {
      _core.change(() {
        favoriteFolders
          ..clear()
          ..addAll(folders);
      });
    }
    return ok;
  }

  final selected = <String>{'river', 'mountain'};

  final books = <SampleBook>[...sampleBooks];
}
