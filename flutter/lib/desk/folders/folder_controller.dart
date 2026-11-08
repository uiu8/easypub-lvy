import 'package:flutter/foundation.dart';

import '../../application/library_service.dart';
import '../../application/folder_import_batch.dart';
import '../../application/settings_service.dart';

/// Page state contains scan summaries and choices, never decoded book text.
class FolderController extends ChangeNotifier {
  FolderController(this.library);
  final LibraryService library;
  String path = '', message = '';
  bool recursive = false, scanning = false, importing = false;
  bool defaultsLoaded = false;
  FolderListing? listing;
  List<ImportOutcome> outcomes = const [];
  final selected = <String>{};
  int _generation = 0;
  bool _disposed = false;
  bool _cancelScan = false, _cancelImport = false;
  bool get busy => scanning || importing;
  bool get canImport => !busy && listing != null && selected.isNotEmpty;

  Future<void> scan(String folder, {bool? includeSubfolders}) async {
    if (importing || _disposed) return;
    final ticket = ++_generation;
    path = folder;
    recursive = includeSubfolders ?? recursive;
    listing?.close?.call();
    listing = null;
    outcomes = const [];
    selected.clear();
    scanning = true;
    _cancelScan = false;
    message = '正在扫描…';
    notifyListeners();
    try {
      if (!defaultsLoaded && library is SettingsService) {
        final prefs = library as SettingsService;
        await prefs.load();
        if (_disposed || ticket != _generation) return;
        recursive =
            includeSubfolders ??
            (prefs.snapshot.value.configuration['import_recursive'] == true);
        defaultsLoaded = true;
      }
      if (_cancelScan) {
        message = '已取消扫描。';
        return;
      }
      final result = await library.scanFolder(
        folder,
        recursive: recursive,
        cancelled: () => _disposed || _cancelScan || ticket != _generation,
      );
      if (_disposed || ticket != _generation) {
        result.close?.call();
        return;
      }
      listing = result;
      message = result.message;
      if (result.books.isNotEmpty) {
        selected.addAll(
          result.books.where((b) => !b.alreadyImported).map((b) => b.path),
        );
      }
    } catch (e) {
      if (!_disposed && ticket == _generation) message = '扫描失败：$e';
    } finally {
      if (!_disposed && ticket == _generation) {
        scanning = false;
        notifyListeners();
      }
    }
  }

  void toggle(String path, bool value) {
    if (busy ||
        listing?.books.any((b) => b.path == path && !b.alreadyImported) !=
            true) {
      return;
    }
    value ? selected.add(path) : selected.remove(path);
    notifyListeners();
  }

  /// 一次设置多本（全选、清空、Shift 选一段；G-067）；书库已有的书跳过。
  void setMany(Iterable<String> paths, bool value) {
    if (busy) return;
    final allowed = {
      for (final b in listing?.books ?? const <FolderBook>[])
        if (!b.alreadyImported) b.path,
    };
    final targets = paths.where(allowed.contains);
    value ? selected.addAll(targets) : selected.removeAll(targets);
    notifyListeners();
  }

  Future<void> resumeScan() async {
    final previous = listing;
    if (busy || _disposed || previous?.resume == null) return;
    final ticket = ++_generation;
    final existing = previous!.books.map((b) => b.path).toSet();
    scanning = true;
    _cancelScan = false;
    notifyListeners();
    try {
      final result = await previous.resume!(
        () => _disposed || _cancelScan || ticket != _generation,
      );
      if (_disposed || ticket != _generation) {
        result.close?.call();
        return;
      }
      listing = result;
      message = result.message;
      selected.removeAll(
        result.books.where((b) => b.alreadyImported).map((b) => b.path),
      );
      selected.addAll(
        result.books
            .where((b) => !b.alreadyImported && !existing.contains(b.path))
            .map((b) => b.path),
      );
    } catch (e) {
      if (!_disposed && ticket == _generation) message = '继续扫描失败：$e';
    } finally {
      if (!_disposed && ticket == _generation) {
        scanning = false;
        notifyListeners();
      }
    }
  }

  Future<void> importSelected() async {
    if (!canImport) return;
    final paths = listing!.books
        .where((b) => selected.contains(b.path))
        .map((b) => b.path)
        .toList();
    importing = true;
    _cancelImport = false;
    message = '正在导入所选书稿…';
    notifyListeners();
    try {
      final results = await importFolderSelection(
        library,
        paths,
        cancelled: () => _disposed || _cancelImport,
      );
      if (_disposed) return;
      outcomes = results;
      selected.removeAll(results.where((r) => r.succeeded).map((r) => r.path));
      listing = markFolderBooksHandled(listing!, results);
      message =
          '导入 ${results.where((r) => r.succeeded && !r.skipped).length} 本，'
          '跳过 ${results.where((r) => r.skipped).length} 本，'
          '失败 ${results.where((r) => !r.succeeded).length} 本，'
          '未处理 ${paths.length - results.length} 本。';
    } catch (e) {
      if (!_disposed) message = '导入未完成：$e';
    } finally {
      if (!_disposed) {
        importing = false;
        notifyListeners();
      }
    }
  }

  void cancel() {
    if (importing) {
      _cancelImport = true;
      library.cancelImport();
      return;
    }
    _cancelScan = true;
    message = '正在停止扫描并保留已找到的书稿…';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    listing?.close?.call();
    _generation++;
    super.dispose();
  }
}
