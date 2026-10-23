import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;

import '../application/workspace_autosave_service.dart';
import '../prototype/project_io.dart' as projects;

/// Immutable recovery generations. A generation becomes visible only after its
/// project, source copies, resource sidecars and page drafts have been synced.
class LocalWorkspaceAutosave {
  LocalWorkspaceAutosave({
    required this.directory,
    required this.project,
    required this.restore,
    required this.projectPath,
    required this.restoreProjectPath,
    required this.busy,
    required this.saved,
    this.delay = const Duration(milliseconds: 700),
  });

  final String directory;
  final Map<String, dynamic> Function() project;
  final Future<bool> Function(String path) restore;
  final String Function() projectPath;
  final void Function(String path) restoreProjectPath;
  final bool Function() busy;
  final void Function(Map<String, dynamic> project) saved;
  final Duration delay;
  final status = ValueNotifier(
    const WorkspaceSaveStatus(WorkspaceSavePhase.saved, '已保存'),
  );
  final _drafts = <String, Map<String, dynamic>>{};
  Timer? _timer;
  RandomAccessFile? _lock;
  Future<bool>? _saving;
  bool _ready = false, _disposed = false, _changed = false;
  int _version = 0;
  bool _projectChanged = true;
  Map<String, dynamic>? _payload;
  String? _identity, _projectIdentity, _projectDirectory, _loadedDirectory;

  Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      _copyValue(value) as Map<String, dynamic>;

  Object? _copyValue(Object? value) => switch (value) {
    Map() => <String, dynamic>{
      for (final entry in value.entries)
        entry.key as String: _copyValue(entry.value),
    },
    List() => [for (final item in value) _copyValue(item)],
    _ => value,
  };

  Map<String, dynamic>? readDraft(String key) {
    final value = _drafts[key];
    return value == null ? null : _copy(value);
  }

  void writeDraft(String key, Map<String, dynamic>? value) {
    if (_disposed) return;
    if (value == null) {
      if (_drafts.remove(key) == null) return;
    } else {
      final copy = _copy(value);
      if (jsonEncode(_drafts[key]) == jsonEncode(copy)) return;
      _drafts[key] = copy;
    }
    changed(projectChanged: false);
  }

  void clearDrafts() {
    _drafts.clear();
    changed(projectChanged: false);
  }

  void changed({bool projectChanged = true}) {
    if (!_ready || _disposed) return;
    _version++;
    _projectChanged |= projectChanged;
    _changed = true;
    if (status.value.phase != WorkspaceSavePhase.error &&
        status.value.phase != WorkspaceSavePhase.saving) {
      _show(WorkspaceSavePhase.pending, '等待保存');
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (busy()) {
        _schedule();
      } else {
        unawaited(flush());
      }
    });
  }

  void _show(WorkspaceSavePhase phase, String message, {DateTime? at}) {
    if (_disposed) return;
    status.value = WorkspaceSaveStatus(
      phase,
      message,
      savedAt: at ?? status.value.savedAt,
    );
  }

  Future<List<Directory>> _generations() async {
    final root = Directory(directory);
    final result = <Directory>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory &&
          RegExp(r'^snapshot-\d+-\d+$').hasMatch(paths.basename(entity.path))) {
        result.add(entity);
      }
    }
    result.sort((a, b) => b.path.compareTo(a.path));
    return result;
  }

  Future<bool> initialize() async {
    if (_ready) return true;
    try {
      await Directory(directory).create(recursive: true);
      _lock = await File(paths.join(directory, 'workspace.lock'))
          .open(mode: FileMode.append);
      await _lock!.lock(FileLock.exclusive);
    } catch (_) {
      await _lock?.close();
      _lock = null;
      _show(WorkspaceSavePhase.error, '工作区暂时无法自动保存，可能已在另一窗口打开或数据目录不可写。');
      return false;
    }
    final snapshots = await _generations();
    var skipped = false;
    for (final snapshot in snapshots) {
      try {
        final data = (jsonDecode(
          await File(paths.join(snapshot.path, 'workspace.json'))
              .readAsString(),
        ) as Map).cast<String, dynamic>();
        if (data['schema'] != 1) throw const FormatException('未知工作区版本');
        final drafts = (data['drafts'] as Map).cast<String, dynamic>();
        final restoredDrafts = {
          for (final entry in drafts.entries)
            entry.key: (entry.value as Map).cast<String, dynamic>(),
        };
        final projectFolder =
            data['project_snapshot'] as String? ??
            paths.basename(snapshot.path);
        if (!RegExp(r'^snapshot-\d+-\d+$').hasMatch(projectFolder)) {
          throw const FormatException('无效的恢复位置');
        }
        final projectDirectory = paths.join(directory, projectFolder);
        if (!await restore(paths.join(projectDirectory, 'book.easypub.json'))) {
          throw const FormatException('工作区恢复失败');
        }
        _drafts.addAll(restoredDrafts);
        restoreProjectPath(data['project_path'] as String? ?? '');
        _loadedDirectory = projectDirectory;
        _projectDirectory = projectDirectory;
        final payload = project();
        _payload = _copy(payload);
        _projectChanged = false;
        _projectIdentity = jsonEncode(payload);
        _identity = '$_projectIdentity\n${jsonEncode(_document())}';
        _ready = true;
        _show(
          WorkspaceSavePhase.saved,
          skipped ? '已恢复上一份完整工作区' : '已恢复上次工作区',
          at: DateTime.tryParse(data['saved_at'] as String? ?? ''),
        );
        return true;
      } catch (_) {
        skipped = true;
      }
    }
    _ready = true;
    if (skipped) {
      _show(WorkspaceSavePhase.error, '上次工作区未能恢复，恢复文件仍保留。可从项目菜单打开项目。');
      // Do not silently replace recovery evidence with an empty workspace.
      _payload = _copy(project());
      _projectIdentity = jsonEncode(_payload);
      _identity = '$_projectIdentity\n${jsonEncode(_document())}';
      return false;
    }
    _payload = _copy(project());
    _projectIdentity = jsonEncode(_payload);
    _identity = '$_projectIdentity\n${jsonEncode(_document())}';
    return true;
  }

  Map<String, dynamic> _document() => {
    'project_path': projectPath(),
    'drafts': _drafts,
  };

  Future<bool> flush() async {
    _timer?.cancel();
    if (_disposed || !_ready || _lock == null) return false;
    final previous = _saving;
    if (previous != null) {
      if (!await previous) return false;
      return flush();
    }
    final operation = _flush();
    _saving = operation;
    try {
      return await operation;
    } finally {
      if (identical(_saving, operation)) _saving = null;
    }
  }

  Future<bool> _flush() async {
    do {
      if (busy()) {
        _show(WorkspaceSavePhase.pending, '当前操作完成后自动保存');
        _schedule();
        return false;
      }
      final version = _version;
      final projectChanged = _projectChanged || _payload == null;
      _projectChanged = false;
      try {
        final payload = projectChanged ? _copy(project()) : _payload!;
        final document = {
          'project_path': projectPath(),
          'drafts': _copyValue(_drafts),
        };
        final projectIdentity = projectChanged || _projectIdentity == null
            ? await compute(
                (Map<String, dynamic> value) => jsonEncode(value),
                payload,
              )
            : _projectIdentity!;
        final identity = '$projectIdentity\n${jsonEncode(document)}';
        if (identity == _identity) {
          if (version != _version) continue;
          _changed = false;
          if (status.value.phase != WorkspaceSavePhase.error) {
            _show(WorkspaceSavePhase.saved, '已保存');
          }
          return status.value.phase != WorkspaceSavePhase.error;
        }
        _show(WorkspaceSavePhase.saving, '正在保存…');
        final now = DateTime.now();
        final folder = Directory(
          paths.join(
            directory,
            'snapshot-${now.microsecondsSinceEpoch.toString().padLeft(20, '0')}-$pid',
          ),
        );
        await folder.create();
        var projectDirectory = _projectDirectory;
        if (projectIdentity != _projectIdentity || projectDirectory == null) {
          await projects.saveProject(
            paths.join(folder.path, 'book.easypub.json'),
            await _withCachedSources(payload),
          );
          projectDirectory = folder.path;
        }
        // This last file is the commit marker. Incomplete generations are not
        // restored, and older committed generations stay available on failure.
        await writeAtomicText(
          File(paths.join(folder.path, 'workspace.json')),
          jsonEncode({
            'schema': 1,
            'saved_at': now.toIso8601String(),
            'project_path': document['project_path'],
            'project_snapshot': paths.basename(projectDirectory),
            'drafts': document['drafts'],
          }),
        );
        _identity = identity;
        _payload = payload;
        _projectIdentity = projectIdentity;
        _projectDirectory = projectDirectory;
        _changed = version != _version;
        saved(payload);
        _show(WorkspaceSavePhase.saved, '已保存', at: now);
        try {
          await _prune();
        } on FileSystemException {
          // Cleanup is best-effort; the new recovery generation is committed.
        }
      } catch (error) {
        _projectChanged |= projectChanged;
        final detail = switch (error) {
          FormatException() => error.message,
          FileSystemException() => error.message,
          _ => '请检查磁盘空间或数据目录，稍后重试。',
        };
        _show(WorkspaceSavePhase.error, '自动保存失败，修改仍在当前窗口。$detail');
        return false;
      }
    } while (_changed && !_disposed);
    return !_disposed;
  }

  /// The resident source is captured once per source identity and original
  /// path. Editing metadata or entering a form never copies a large book again.
  Future<Map<String, dynamic>> _withCachedSources(
    Map<String, dynamic> payload,
  ) async {
    final result = _copy(payload);
    for (final book in (result['books'] as List).cast<Map>()) {
      final originalPath = book['origin_path'] ?? book['path'];
      final key = sha256
          .convert(utf8.encode('${book['source_id']}\u0000$originalPath'))
          .toString();
      final root = Directory(paths.join(directory, 'sources', key));
      final cachedProject = File(paths.join(root.path, 'source.easypub.json'));
      if (!await cachedProject.exists()) {
        await Directory(paths.dirname(root.path)).create(recursive: true);
        final pending = await Directory(paths.dirname(root.path))
            .createTemp('pending-');
        await projects.saveRecoveryProject(
          paths.join(pending.path, 'source.easypub.json'),
          {
            ...result,
            'current_path': book['path'],
            'books': [book],
          },
        );
        await pending.rename(root.path);
      }
      final captured = (jsonDecode(await cachedProject.readAsString()) as Map);
      final source = (captured['books'] as List).single as Map;
      final sourcePath = paths.join(root.path, source['path'] as String);
      if (result['current_path'] == book['path']) {
        result['current_path'] = sourcePath;
      }
      book['origin_path'] = originalPath;
      book['path'] = sourcePath;
    }
    return result;
  }

  Future<void> _prune() async {
    final generations = await _generations();
    final keep = <String>{?_loadedDirectory};
    var count = 0;
    for (final folder in generations) {
      final state = File(paths.join(folder.path, 'workspace.json'));
      if (await state.exists() && count < 3) {
        keep.add(folder.path);
        try {
          final data = jsonDecode(await state.readAsString()) as Map;
          final projectFolder = data['project_snapshot'] as String?;
          if (projectFolder != null) {
            keep.add(paths.join(directory, projectFolder));
          }
          count++;
        } catch (_) {
          // Retain unreadable recovery evidence without counting it as one of
          // the three usable generations or failing an already committed save.
        }
      }
    }
    for (final folder in generations) {
      if (keep.contains(folder.path)) continue;
      final root = paths.normalize(paths.absolute(directory));
      final target = paths.normalize(paths.absolute(folder.path));
      if (paths.dirname(target) != root ||
          !paths.basename(target).startsWith('snapshot-')) {
        continue;
      }
      try {
        await folder.delete(recursive: true);
      } on FileSystemException {
        // A retained snapshot may be open in a reader. Keeping it is harmless.
      }
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _timer?.cancel();
    _disposed = true;
    await _saving;
    await _lock?.close();
    _lock = null;
    status.dispose();
  }
}
