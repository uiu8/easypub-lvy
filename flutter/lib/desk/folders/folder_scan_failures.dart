// 读取失败路径（D4-D，V8 按设计重写视图）：只读列出，路径可选择复制。
import 'package:flutter/material.dart';

import '../dialogs.dart';
import '../controls/controls.dart';
import '../tokens.dart';

class FolderScanFailures extends StatelessWidget {
  const FolderScanFailures({super.key, required this.paths});
  final List<String> paths;
  @override
  Widget build(BuildContext context) => DeskButton(
    '查看读取失败路径（${paths.length}）',
    quiet: true,
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) {
        final d = context.desk;
        return DeskDialog(
          title: '读取失败的路径',
          closeTooltip: '返回扫描',
          width: 600,
          footerLeft: Text('路径可选择复制。', style: ui(12, c: d.ink3)),
          actions: [
            DeskButton(
              '返回扫描',
              primary: true,
              onPressed: () => Navigator.pop(context),
            ),
          ],
          scrollBody: false,
          child: SizedBox(
            height: 260,
            child: ListView.builder(
              itemCount: paths.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SelectableText(paths[i], style: mono(11.5, c: d.ink2)),
              ),
            ),
          ),
        );
      },
    ),
  );
}
