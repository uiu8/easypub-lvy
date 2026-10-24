// 启动救援（V104，SET-112）：读不出软件数据的位置记录时只显示这一页，不新建工作区，
// 以免空数据覆盖原来的书库。位置记录在固定位置 %LOCALAPPDATA%\EasyPub-RustFlutter\location.json。
import 'dart:io';

import 'package:flutter/material.dart';

import '../../application/storage_settings_service.dart';
import '../controls/controls.dart';
import '../tokens.dart';

class StorageRescueApp extends StatelessWidget {
  const StorageRescueApp({
    super.key,
    required this.error,
    required this.onExit,
    this.pointerFolder,
  });
  final Object error;
  final VoidCallback onExit;

  /// 位置记录所在的文件夹；读不出 LOCALAPPDATA 时为空。
  final String? pointerFolder;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: deskTheme(),
    home: Builder(
      builder: (context) {
        final d = context.desk;
        final folder = pointerFolder;
        return Scaffold(
          backgroundColor: d.canvas,
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  key: const ValueKey('storage-rescue'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.folder_off_outlined, size: 34, color: d.warn),
                    const SizedBox(height: 14),
                    Text('没能读到软件数据的位置', style: ui(20, w: 650, c: d.ink)),
                    const SizedBox(height: 10),
                    Text(
                      '${storageErrorText(error)}为了不让空数据覆盖原来的书库，这次没有打开工作区，也没有改动任何文件。',
                      style: ui(13.5, c: d.ink, h: 1.6),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '可以这样处理：\n'
                      '1. 如果之前把数据搬到过别的磁盘，确认那个磁盘已经接上，然后重新打开软件；\n'
                      '2. 如果确定数据还在默认位置，可以把下面文件夹里的 location.json 改名备份后重新打开软件，软件会回到默认位置；\n'
                      '3. 仍然不行时，把这个文件夹里的 location.json 发给开发者排查，里面不含书的内容和登录信息。',
                      style: ui(12.5, c: d.ink2, h: 1.7),
                    ),
                    if (folder != null) ...[
                      const SizedBox(height: 10),
                      SelectableText(folder, style: mono(12, c: d.ink)),
                    ],
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (folder != null)
                          DeskButton(
                            '打开这个文件夹',
                            icon: Icons.folder_open,
                            onPressed: () =>
                                Process.start('explorer.exe', [folder]),
                          ),
                        DeskButton('退出', primary: true, onPressed: onExit),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
