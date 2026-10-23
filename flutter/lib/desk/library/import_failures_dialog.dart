import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/library_service.dart';
import '../dialogs.dart';
import '../tokens.dart';
import '../controls/controls.dart';

/// 批量导入的失败清单（R2-02）：每个没导入的文件写明原因，可整份复制。
class ImportFailuresDialog extends StatelessWidget {
  const ImportFailuresDialog(this.failures, {super.key});
  final List<ImportOutcome> failures;

  static String fileName(String path) =>
      path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ??
      path;

  String get report =>
      [for (final f in failures) '${fileName(f.path)}\t${f.message}\t${f.path}']
          .join('\n');

  @override
  Widget build(BuildContext context) {
    final d = context.desk;
    return DeskDialog(
      key: const ValueKey('library-import-failures'),
      title: '${failures.length} 个文件没有导入',
      subtitle: '其余书稿已正常加入书库。按原因处理后，可以只把这些文件再导入一次。',
      closeTooltip: '关闭',
      width: 620,
      height: (160 + failures.length * 52).clamp(260, 560).toDouble(),
      scrollBody: false,
      footerLeft: DeskButton(
        '复制清单',
        key: const ValueKey('library-import-failures-copy'),
        icon: Icons.copy_rounded,
        quiet: true,
        onPressed: () => Clipboard.setData(ClipboardData(text: report)),
      ),
      actions: [
        DeskButton(
          '知道了',
          primary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: DeskListBox(
        child: ListView.separated(
          itemCount: failures.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: d.line),
          itemBuilder: (context, i) {
            final f = failures[i];
            return Padding(
              key: ValueKey('library-import-failure-$i'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.error_outline_rounded,
                      size: 16,
                      color: d.pen,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: f.path,
                          child: Text(
                            fileName(f.path),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ui(13, w: 600, c: d.ink),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(f.message, style: ui(12, c: d.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
