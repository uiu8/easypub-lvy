// 书源下载为 EPUB（LIB-215）：下载好的 TXT 加入书库后，按全局默认排版（含自动规则）转换为 EPUB，
// 放在 TXT 同一文件夹，TXT 保留。不弹窗、不切页面；不能转换时返回原因，书仍留在书库。
// 书库里已有这本书而下载内容变了（追更、重新整理）时不生成：草稿还是旧的，要先“刷新来源”（V111）。
import 'dart:io';

import '../../application/conversion_defaults.dart';
import '../../application/conversion_service.dart';
import '../../application/library_service.dart';
import '../../application/settings_service.dart';
import '../errors.dart';
import '../metadata/cover_drop.dart' show bindSidecarCover;

typedef DownloadEpubResult = ({bool imported, String? error});

/// 书库里的这本书还是下载变化前的版本（V111）。
const downloadOutdatedInLibrary =
    '书库里的这本书还是之前的版本，下载的新内容没有采用，所以没有生成 EPUB。请点“刷新来源”确认采用，之后会自动生成。';

Future<DownloadEpubResult> exportDownloadAsEpub({
  required LibraryService library,
  required ConversionSession session,
  required String path,
  bool conversionBusy = false,
  void Function(List<ImportOutcome> outcomes)? onImported,
}) async {
  try {
    final out = await library.importFiles([path]);
    final failed = out.where((o) => !o.succeeded && !o.skipped);
    if (failed.isNotEmpty) {
      return (imported: false, error: '加入书库失败：${failed.first.message}');
    }
    onImported?.call(out);
    if (out.any((o) => o.sourceChanged)) {
      return (imported: true, error: downloadOutdatedInLibrary);
    }
    // 插件下载的封面存为 TXT 同名图片：书还没有封面时自动设为封面。
    await bindSidecarCover(library, path);
  } catch (e) {
    return (
      imported: false,
      error: deskErrorText(e, '加入书库未完成：请确认下载的 TXT 文件仍在且未被占用，可在下载队列点“加入书库”重试。'),
    );
  }
  String key(String p) => p.replaceAll('/', r'\').toLowerCase();
  final book = library.books.value
      .where((b) => key(b.path) == key(path))
      .firstOrNull;
  if (book == null) {
    return (imported: true, error: '已加入书库，但没有找到这本书；请在书库里转换为 EPUB。');
  }
  if (conversionBusy || session.busy) {
    return (imported: true, error: '另一项转换正在进行。书已加入书库，稍后可在这里重新生成 EPUB。');
  }
  try {
    Map<String, dynamic> config = {};
    if (library is SettingsService) {
      final settings = library as SettingsService;
      if (await settings.load()) {
        config = Map.of(settings.snapshot.value.configuration);
      }
    }
    final defaults = readConversionDefaults(config);
    final plan = await session.preview(
      ConversionRequest(
        books: [book.id],
        directory: File(path).parent.path,
        format: 'EPUB',
        generateCover: defaults['generate_cover'] as bool,
        runChecks: defaults['check_before_conversion'] as bool,
      ),
    );
    if (plan.blocked) {
      return (imported: true, error: '转换前检查发现必须先处理的问题。书已加入书库，请在书库打开这本书处理后再转换。');
    }
    if (!session.isCurrent(plan)) {
      return (imported: true, error: '书稿在准备期间变化了，请重新生成 EPUB。');
    }
    // 提醒级检查（如缺封面）自动确认：下载即生成是用户选定的流程，阻断级问题仍不转换。
    final outputs = await session.commit(
      plan,
      acknowledgeWarnings: plan.needsAcknowledgement,
    );
    if (outputs.any((o) => o.complete)) return (imported: true, error: null);
    final detail = outputs
        .map((o) => o.detail)
        .where((d) => d.isNotEmpty)
        .firstOrNull;
    return (imported: true, error: detail ?? 'EPUB 没有生成，请到任务页查看原因。');
  } catch (e) {
    return (imported: true, error: deskErrorText(e, 'EPUB 没有生成，请到任务页查看原因。'));
  }
}
