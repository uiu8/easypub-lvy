import 'package:flutter/material.dart';

import '../dialogs.dart' show DeskAlert;

import '../../application/library_service.dart';
import '../../application/workspace_leave_service.dart';
import '../../application/workspace_autosave_service.dart';

/// Flushes mounted editors' input before navigation or workspace replacement.
/// Saving unfinished input never applies a repair or confirms a modal action.
class WorkspaceDraftGuard {
  WorkspaceDraftGuard(this.check);
  final Future<bool> Function() check;
  bool _pending = false;
  Future<bool> run(Future<bool> Function() operation) async {
    if (_pending) return false;
    _pending = true;
    try {
      if (!await check()) return false;
      return await operation();
    } finally {
      _pending = false;
    }
  }
}

class WorkspaceDraftScope extends InheritedWidget {
  const WorkspaceDraftScope({
    super.key,
    required this.guard,
    required super.child,
  });
  final WorkspaceDraftGuard guard;
  static WorkspaceDraftGuard? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WorkspaceDraftScope>()?.guard;
  @override
  bool updateShouldNotify(WorkspaceDraftScope oldWidget) =>
      guard != oldWidget.guard;
}

Future<bool> confirmWorkspaceLeave(
  BuildContext context,
  LibraryService library,
  BookFilePicker picker, {
  required String action,
}) async {
  Future<bool> confirm() async {
    if (!context.mounted) return false;
    return _confirmWorkspaceLeave(context, library, picker, action: action);
  }

  final guard = WorkspaceDraftScope.of(context);
  return guard == null ? confirm() : guard.run(confirm);
}

/// Saving and choosing a destination are asynchronous. Recheck the live state
/// before granting permission; a saved older snapshot is not a clean workspace.
Future<bool> _confirmWorkspaceLeave(
  BuildContext context,
  LibraryService library,
  BookFilePicker picker, {
  required String action,
}) async {
  final service = library is WorkspaceLeaveService
      ? library as WorkspaceLeaveService
      : null;
  bool busy() =>
      service?.hasPendingWork ??
      (library.importing.value || library.projectBusy.value);
  bool dirty() => service?.hasUnsavedChanges ?? library.books.value.isNotEmpty;
  Future<void> explain(String message) => showDialog<void>(
    context: context,
    builder: (context) => DeskAlert(
      title: const Text('暂不能离开工作区'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回工作区'),
        ),
      ],
    ),
  );
  final requiresExplicitChoice = action.contains('恢复项目');
  if (busy()) {
    await explain('仍有导入、检查、编辑或转换任务运行。请等待完成，或在任务页面取消后再$action。');
    return false;
  }
  if (!requiresExplicitChoice && library is WorkspaceAutosaveService) {
    final autosave = library as WorkspaceAutosaveService;
    if (await autosave.flushWorkspace()) {
      if (!busy()) return true;
      if (context.mounted) await explain('保存期间有新任务开始，请等待完成后再$action。');
      return false;
    }
    if (context.mounted) {
      await explain(
        '自动保存没有完成：${autosave.workspaceSave.value.message}\n请检查保存位置后重试。',
      );
    }
    return false;
  }
  if (!dirty() && !requiresExplicitChoice) return true;
  final identity = service?.workspaceIdentity;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => DeskAlert(
      title: Text('$action前保存更改？'),
      content: Text(
        requiresExplicitChoice
            ? '打开恢复项目会替换当前工作区。请确认后继续。'
            : '当前工作区有未保存更改。另存项目后继续，或放弃这些更改。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'discard'),
          child: const Text('放弃更改'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'save'),
          child: const Text('保存并继续'),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return false;
  if (busy()) {
    await explain('工作区有新任务开始，请等待完成。');
    return false;
  }
  if (choice == 'discard') {
    if (service != null && service.workspaceIdentity != identity) {
      await explain('确认期间工作区又有修改，请重新确认。');
      return false;
    }
    return true;
  }
  try {
    final path = await picker.chooseProjectDestination();
    if (!context.mounted || path == null) return false;
    if (busy()) {
      await explain('工作区有新任务开始，请等待完成。');
      return false;
    }
    final result = await library.saveProject(path);
    if (!context.mounted) return false;
    if (!result.succeeded) {
      await explain(result.message);
      return false;
    }
    if (busy() || (service != null && dirty())) {
      await explain('保存期间又有修改或任务开始，当前工作区仍需处理；请重新保存。');
      return false;
    }
    return true;
  } catch (error) {
    if (context.mounted) await explain('保存未完成：$error');
    return false;
  }
}
