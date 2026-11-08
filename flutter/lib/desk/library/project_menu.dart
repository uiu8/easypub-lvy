// 迁入 desk（library，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import '../shell/workspace_leave.dart';
import '../../application/workspace_leave_service.dart';

import 'package:flutter/material.dart';

import '../dialogs.dart' show DeskAlert, deskSnackBar;

import 'package:go_router/go_router.dart';

import '../../application/library_service.dart';
import '../tokens.dart';
import '../controls/controls.dart';
import '../folders/favorites_dialog.dart';

class ProjectMenu extends StatefulWidget {
  const ProjectMenu({
    super.key,
    required this.library,
    required this.picker,
    this.anchored = false,
  });
  final LibraryService library;
  final BookFilePicker picker;
  final bool anchored;
  @override
  State<ProjectMenu> createState() => _ProjectMenuState();
}

class _ProjectMenuState extends State<ProjectMenu> {
  bool busy = false, working = false;
  String message = '';
  Future<void> chooseAction(String action) async {
    if (busy) return;
    message = '';
    switch (action) {
      case 'open':
        await execute(false);
      case 'save':
        await execute(true);
      case 'clear':
        await clearWorkspace();
      case 'favorites':
        final path = await showDialog<String>(
          context: context,
          builder: (_) =>
              FavoritesDialog(library: widget.library, picker: widget.picker),
        );
        if (mounted && path != null) {
          context.go(
            Uri(path: '/folders', queryParameters: {'path': path}).toString(),
          );
        }
    }
    if (mounted && message.isNotEmpty) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        deskSnackBar(
          content: Text(message),
          showCloseIcon: true,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> clearWorkspace() async {
    if (busy || widget.library is! WorkspaceResetService) return;
    setState(() => busy = true);
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => DeskAlert(
          title: const Text('清空当前工作区？'),
          content: const Text(
            '将移除本次载入的书稿、当前编辑状态和书库勾选，回到空书库。原始书稿、已另存的项目和成品文件都会保留。需要长期保留本次工作时，请先另存项目。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('清空工作区'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      setState(() => working = true);
      if (!await confirmWorkspaceLeave(
        context,
        widget.library,
        widget.picker,
        action: '清空当前工作区',
      )) {
        return;
      }
      if (!mounted) return;
      final result = await (widget.library as WorkspaceResetService)
          .clearWorkspace();
      if (mounted) setState(() => message = result.message);
    } catch (e) {
      if (mounted) setState(() => message = '工作区未清空：$e');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          working = false;
        });
      }
    }
  }

  Future<void> execute(bool save) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final path = save
          ? await widget.picker.chooseProjectDestination()
          : await widget.picker.chooseProject();
      if (path == null || !mounted) return;
      setState(() => working = true);
      if (!save &&
          !await confirmWorkspaceLeave(
            context,
            widget.library,
            widget.picker,
            action: '打开另一个项目',
          )) {
        return;
      }
      if (!mounted) return;
      final result = save
          ? await widget.library.saveProject(path)
          : await widget.library.openProject(path);
      if (!mounted) return;
      setState(() => message = result.message);
    } catch (error) {
      if (mounted) setState(() => message = '项目操作未完成：$error');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          working = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.anchored
      ? DeskCommandMenu<String>(
          tooltip: busy ? '项目处理中' : '项目',
          enabled: !busy,
          onSelected: chooseAction,
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'open',
              height: 36,
              child: Text('打开项目…'),
            ),
            const PopupMenuItem(
              value: 'save',
              height: 36,
              child: Text('另存项目…'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'favorites',
              height: 36,
              child: Text('收藏文件夹'),
            ),
            if (widget.library is WorkspaceResetService) ...[
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'clear',
                height: 36,
                child: Text(
                  '清空当前工作区…',
                  style: TextStyle(color: context.desk.pen),
                ),
              ),
            ],
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('项目', style: ui(12.5, w: 520, c: context.desk.ink2)),
                const SizedBox(width: 2),
                if (busy)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  )
                else
                  Icon(
                    Icons.expand_more_rounded,
                    size: 16,
                    color: context.desk.ink2,
                  ),
              ],
            ),
          ),
        )
      : PopScope(
          canPop: !busy,
          child: Dialog(
            backgroundColor: context.desk.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              width: 680,
              child: Padding(
                padding: const EdgeInsets.all(26),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: DeskText('项目菜单', size: 22, bold: true),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: busy ? null : () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 8,
                      runSpacing: 12,
                      children: [
                        DeskButton(
                          '打开项目…',
                          icon: Icons.folder_open,
                          onPressed: busy ? null : () => execute(false),
                        ),
                        DeskButton(
                          '另存项目…',
                          icon: Icons.save_outlined,
                          onPressed: busy ? null : () => execute(true),
                        ),
                        if (widget.library is WorkspaceResetService)
                          DeskButton(
                            '清空当前工作区…',
                            icon: Icons.playlist_remove,
                            onPressed: busy ? null : clearWorkspace,
                          ),
                        DeskButton(
                          '收藏文件夹',
                          icon: Icons.star_outline,
                          onPressed: busy
                              ? null
                              : () async {
                                  final router = GoRouter.of(context);
                                  final path = await showDialog<String>(
                                    context: context,
                                    builder: (_) => FavoritesDialog(
                                      library: widget.library,
                                      picker: widget.picker,
                                    ),
                                  );
                                  if (path != null && context.mounted) {
                                    Navigator.pop(context);
                                    router.go(
                                      Uri(
                                        path: '/folders',
                                        queryParameters: {'path': path},
                                      ).toString(),
                                    );
                                  }
                                },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    if (working) const LinearProgressIndicator(),
                    DeskText(
                      message.isEmpty
                          ? '编辑进度自动保存。另存项目用于备份或迁移，包含书稿草稿与资源引用；原始书稿和已有项目文件保留。'
                          : message,
                      size: 13,
                      color: context.desk.ink2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
}
