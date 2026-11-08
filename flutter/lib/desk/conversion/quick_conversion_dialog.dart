// 迁入 desk（conversion，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import 'package:flutter/material.dart';

import '../errors.dart';

import '../dialogs.dart' show DeskAlert;

import '../../application/conversion_defaults.dart';
import '../../application/conversion_desktop.dart';
import '../../application/conversion_service.dart';
import '../../application/library_service.dart';
import '../../application/settings_service.dart';
import '../controls/controls.dart';

class QuickConversionChoice {
  const QuickConversionChoice(
    this.action,
    this.request,
    this.plan, {
    this.bookId,
    this.page,
  });
  final String action;
  final ConversionRequest? request;
  final ConversionPreview? plan;
  final String? bookId, page;
}

class QuickConversionDialog extends StatefulWidget {
  const QuickConversionDialog({
    super.key,
    required this.library,
    required this.desktop,
    required this.session,
    required this.books,
    this.outputRequest,
  });
  final LibraryService library;
  final ConversionDesktop desktop;
  final ConversionSession session;
  final List<String> books;
  final ConversionRequest? outputRequest;
  @override
  State<QuickConversionDialog> createState() => _QuickConversionDialogState();
}

class _QuickConversionDialogState extends State<QuickConversionDialog> {
  ConversionRequest? request;
  ConversionPreview? plan;
  String? error;
  bool preparing = true, startedPreview = false;
  @override
  void initState() {
    super.initState();
    prepare();
  }

  Future<void> prepare() async {
    final ids = List<String>.unmodifiable(widget.books);
    final versions = {
      for (final b in widget.library.books.value.where(
        (b) => ids.contains(b.id),
      ))
        b.id: b.contentVersion,
    };
    try {
      final service = widget.library;
      Map<String, dynamic> config = {};
      if (widget.outputRequest == null && service is SettingsService) {
        final settings = service as SettingsService;
        if (!await settings.load()) {
          throw const FormatException(
            '默认转换设置没有读出来：设置文件可能损坏或被占用。打开“转换”页核对设置后再试。',
          );
        }
        config = Map.of(settings.snapshot.value.configuration);
      }
      final defaults = widget.outputRequest == null
          ? await resolveConversionDefaults(
              readConversionDefaults(config),
              widget.desktop,
            )
          : null;
      if (!mounted) return;
      if (ids.isEmpty ||
          versions.length != ids.length ||
          !ids.every(
            (id) => widget.library.books.value.any(
              (b) => b.id == id && b.contentVersion == versions[id],
            ),
          )) {
        throw const FormatException('准备期间书稿已变化，请重新选择后转换。');
      }
      request =
          widget.outputRequest ??
          ConversionRequest(
            books: ids,
            directory: defaults!['output_directory'] as String,
            format: defaults['output_format'] as String,
            engine: defaults['kindle_converter'] as String,
            generateCover: defaults['generate_cover'] as bool,
            runChecks: defaults['check_before_conversion'] as bool,
          );
      startedPreview = true;
      final result = await widget.session.preview(request!);
      if (!mounted) return;
      plan = result;
      if (result.previewed &&
          !result.blocked &&
          !result.needsAcknowledgement &&
          widget.session.isCurrent(result)) {
        Navigator.pop(context, QuickConversionChoice('start', request, result));
        return;
      }
    } catch (e) {
      if (!mounted) return;
      error = deskErrorText(e, '无法准备转换，请打开转换设置查看并重试。');
    }
    if (mounted) setState(() => preparing = false);
  }

  void finish(String action, {String? id, String? page}) => Navigator.pop(
    context,
    QuickConversionChoice(action, request, plan, bookId: id, page: page),
  );
  @override
  Widget build(BuildContext context) {
    final issues =
        plan?.findings
            .where((f) => f.level == 'warning' || f.level == 'blocking')
            .toList() ??
        <ConversionFinding>[];
    return PopScope(
      canPop: !preparing,
      child: DeskAlert(
        title: Text(preparing ? '正在准备转换' : '转换问题摘要'),
        content: SizedBox(
          width: 660,
          child: preparing
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(),
                    SizedBox(height: 18),
                    Text('按本次输出设置准备所选书籍…'),
                  ],
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 430),
                  child: DeskScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (error != null) Text(error!),
                        if (request != null)
                          Text(
                            '${request!.books.length} 本 · ${request!.format} · ${request!.directory}',
                          ),
                        for (final issue in issues)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${plan!.bookTitle(issue.bookId)} · ${issue.title}',
                            ),
                            subtitle: Text(issue.detail),
                            leading: Icon(
                              issue.level == 'blocking'
                                  ? Icons.error_outline
                                  : Icons.info_outline,
                            ),
                            trailing: issue.repairPage == null
                                ? null
                                : TextButton(
                                    onPressed: () => finish(
                                      'repair',
                                      id: issue.bookId,
                                      page: issue.repairPage,
                                    ),
                                    child: const Text('前往处理'),
                                  ),
                          ),
                        if (plan != null && !plan!.previewed && issues.isEmpty)
                          const Text('输出计划未生成，请打开转换设置重新检查。'),
                      ],
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                if (startedPreview && preparing) await widget.session.cancel();
                if (context.mounted) Navigator.pop(context);
              } catch (_) {
                if (mounted) {
                  setState(() {
                    error = '停止请求未完成，请重试。';
                    preparing = false;
                  });
                }
              }
            },
            child: const Text('取消'),
          ),
          if (!preparing)
            TextButton(
              onPressed: () => finish('settings'),
              child: const Text('转换设置'),
            ),
          if (!preparing && plan != null && plan!.previewed && !plan!.blocked)
            TextButton(
              onPressed: () => finish('start'),
              child: const Text('继续转换'),
            ),
        ],
      ),
    );
  }
}
