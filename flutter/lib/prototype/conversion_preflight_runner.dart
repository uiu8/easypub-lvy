import '../application/conversion_snapshot.dart';

import 'dart:convert';
import 'dart:io';

import '../application/parallel_books.dart';
import '../src/rust/api.dart' as api;
import 'conversion_preflight.dart';
import 'prototype_state.dart';
import '../infrastructure/legacy_chapter_session.dart';
import '../infrastructure/legacy_cleanup_session.dart';

/// Runs the same source-bound checks for the single-book and batch conversion
/// entry points.  The returned reports are facts about one source revision;
/// callers must still re-run them after a project or output setting changes.
class ConversionPreflightRunner {
  ConversionPreflightRunner({
    required this.state,
    required this.format,
    required this.enginePath,
    this.languageFallback,
    this.generateCover = true,
    this.languages = const {},
    this.covers = const {},
    this.publicationOverrides = const {},
    this.parallel = 1,
  });

  /// 同时检查的本数（V38，OUT-083）；1 与原来的逐本检查相同。
  final int parallel;

  final PrototypeState state;
  final String format;
  final String enginePath;
  final String? languageFallback;
  final bool generateCover;
  final Map<String, String> languages;
  final Map<String, String> covers;
  final Map<String, Map<String, dynamic>> publicationOverrides;

  String _language(SampleBook book) {
    final override = languages[book.id]?.trim();
    if (override != null && override.isNotEmpty) return override;
    final value = (state.production.settings(book.id)['language'] as String?)
        ?.trim();
    return value?.isNotEmpty == true ? value! : (languageFallback ?? '');
  }

  String _cover(SampleBook book) {
    final override = covers[book.id]?.trim();
    if (override != null && override.isNotEmpty) return override;
    return (state.production.settings(book.id)['cover_path'] as String?)
            ?.trim() ??
        state.production.coverPathFor(book)?.trim() ??
        '';
  }

  Future<List<ConversionPreflightReport>> run(
    Iterable<SampleBook> books, {
    bool Function()? isCancelled,
    void Function(List<ConversionPreflightReport> reports)? onProgress,
  }) async {
    // 几本同时检查（V38）；进度与结果始终按所选书的顺序排列。
    final list = books.toList(growable: false);
    final done = List<ConversionPreflightReport?>.filled(list.length, null);
    await runLimited(list, parallel, (book, index) async {
      if (isCancelled?.call() == true) {
        throw const FormatException('检查已取消。');
      }
      done[index] = await checkBook(book);
      onProgress?.call(
        List.unmodifiable(done.whereType<ConversionPreflightReport>()),
      );
    });
    return List.unmodifiable(done.whereType<ConversionPreflightReport>());
  }

  Future<ConversionPreflightReport> checkBook(SampleBook book) async {
    final source = book.source;
    final issues = <ConversionPreflightIssue>[];
    if (source == null || book.isDemo) {
      return ConversionPreflightReport(
        bookId: book.id,
        title: state.displayTitle(book),
        issues: const [
          ConversionPreflightIssue(
            category: 'source',
            level: ConversionPreflightLevel.blocking,
            title: '不是可转换的真实书稿',
            detail: '样书或未完成导入的条目不能进入输出批次。',
          ),
        ],
      );
    }

    final guard = state.publicationContext(book.id);
    final settings = state.production.settings(book.id);
    final workingPathExists = File(source.path).existsSync();
    final originPath = source.originPath;
    final originPathExists =
        originPath == null || File(originPath).existsSync();
    if (!workingPathExists) {
      issues.add(
        ConversionPreflightIssue(
          category: 'source',
          level: ConversionPreflightLevel.blocking,
          title: '源文件或工作副本不可读',
          detail: '当前导入文件不存在；请恢复原文件位置或重新导入书稿后再转换。',
          canOpenRepair: true,
          action: ConversionPreflightAction.resources,
        ),
      );
    } else if (!originPathExists) {
      issues.add(
        const ConversionPreflightIssue(
          category: 'source',
          level: ConversionPreflightLevel.warning,
          title: '原始 EPUB 路径不可读',
          detail: '将继续使用已缓存的 UTF-8 工作副本和资源清单；如需重新扫描原 EPUB，请恢复原文件位置或重新导入。',
          canOpenRepair: true,
          action: ConversionPreflightAction.resources,
        ),
      );
    } else {
      issues.add(
        ConversionPreflightIssue(
          category: 'source',
          level: ConversionPreflightLevel.pass,
          title: '源文件与版本',
          detail: originPath == null
              ? '源文件存在，转换会继续使用当前指纹和版本保护。'
              : '原始 EPUB 与工作副本均可读取，转换会继续使用当前指纹和版本保护。',
        ),
      );
    }

    final language = _language(book);
    if (language.isEmpty || language == 'und') {
      issues.add(
        ConversionPreflightIssue(
          ruleId: 'preflight.language',
          category: 'metadata',
          level: languageFallback == null
              ? ConversionPreflightLevel.blocking
              : ConversionPreflightLevel.info,
          title: languageFallback == null ? '缺少书籍语言' : '语言尚未明确',
          detail: languageFallback == null
              ? '批量输出不会替每本书猜测语言，请在书籍信息页填写后重新检查。'
              : '转换设置会按当前默认补为 zh-CN；不会修改源文件。',
          canOpenRepair: languageFallback == null,
          action: ConversionPreflightAction.metadata,
        ),
      );
    } else {
      issues.add(
        ConversionPreflightIssue(
          ruleId: 'preflight.language',
          category: 'metadata',
          level: ConversionPreflightLevel.pass,
          title: '语言：$language',
          detail: '语言值可用于 EPUB 和 Kindle 成品元信息。',
        ),
      );
    }

    final title = (settings['title'] as String? ?? '').trim();
    if (title.isEmpty) {
      issues.add(
        const ConversionPreflightIssue(
          ruleId: 'preflight.title',
          category: 'metadata',
          level: ConversionPreflightLevel.blocking,
          title: '缺少书名',
          detail: '请在元信息页填写书名后再生成成品。',
          canOpenRepair: true,
          action: ConversionPreflightAction.metadata,
        ),
      );
    }

    final cover = _cover(book);
    if (cover.isNotEmpty && !await File(cover).exists()) {
      issues.add(
        ConversionPreflightIssue(
          ruleId: 'preflight.cover',
          category: 'resources',
          level: ConversionPreflightLevel.blocking,
          title: '封面文件不可访问',
          detail: cover,
          isCoverIssue: true,
          canOpenRepair: true,
          action: ConversionPreflightAction.metadata,
        ),
      );
    }
    if (format != 'EPUB' && cover.isEmpty && !generateCover) {
      issues.add(
        const ConversionPreflightIssue(
          ruleId: 'preflight.cover',
          category: 'resources',
          level: ConversionPreflightLevel.blocking,
          title: 'Kindle 成品缺少封面',
          isCoverIssue: true,
          detail: '请选择封面或启用文字封面；不会使用隐含占位图。',
          canOpenRepair: true,
          action: ConversionPreflightAction.metadata,
        ),
      );
    } else if (cover.isEmpty && generateCover) {
      issues.add(
        const ConversionPreflightIssue(
          ruleId: 'preflight.cover',
          category: 'resources',
          level: ConversionPreflightLevel.info,
          title: '将生成文字封面',
          detail: '预览阶段会生成封面副本并写入制作设置，原稿不变。',
        ),
      );
    }

    if (format != 'EPUB' && !await File(enginePath.trim()).exists()) {
      issues.add(
        ConversionPreflightIssue(
          ruleId: 'preflight.converter',
          category: 'converter',
          level: ConversionPreflightLevel.blocking,
          title: format == 'KFX' ? '缺少 KFX / Bokai 转换器' : '缺少 Kindle 转换器',
          detail: format == 'KFX'
              ? '请选择便携包内的 Bokai，或先完整解压软件包。'
              : '请选择便携包内的 Kindling，或先完整解压软件包。',
        ),
      );
    } else if (format != 'EPUB') {
      issues.add(
        ConversionPreflightIssue(
          category: 'converter',
          level: ConversionPreflightLevel.pass,
          title: format == 'KFX' ? 'KFX / Bokai 转换器' : 'Kindle 转换器',
          detail: format == 'KFX'
              ? '已找到 Bokai；开始前仍会再次核对路径和版本。'
              : '已找到受控转换器；开始前仍会再次核对路径和版本。',
        ),
      );
    }

    try {
      final chapters = LegacyChapterSession(state, book.id);
      final structure = await chapters.read(0);
      final report = await chapters.issues(structure, 0, effective: true);
      final findings = [
        for (final item in report.items) {'id': item.category},
      ];
      final unresolved = report.total > 0;
      if (findings.isEmpty) {
        issues.add(
          const ConversionPreflightIssue(
            category: 'chapters',
            level: ConversionPreflightLevel.pass,
            title: '章节问题检查通过',
            detail: '当前规则没有发现待处理的结构问题。',
          ),
        );
      } else if (unresolved) {
        final ids = findings
            .map((finding) => finding['id']?.toString())
            .whereType<String>()
            .toList();
        issues.add(
          ConversionPreflightIssue(
            category: 'chapters',
            level: ConversionPreflightLevel.blocking,
            title: '章节问题待审阅（${findings.length} 类）',
            detail: ids.contains('number-gap')
                ? '包含 number-gap：编号跳跃不能直接推断缺章，请逐项查看源行证据并选择修复或保留。'
                : '可打开检查与修复进行审阅；也可保留当前内容直接转换。',
            canOpenRepair: true,
            action: ConversionPreflightAction.chapters,
          ),
        );
      } else {
        issues.add(
          const ConversionPreflightIssue(
            category: 'chapters',
            level: ConversionPreflightLevel.pass,
            title: '章节问题已审阅',
            detail: '现有问题均已有明确的核实或忽略结论；转换不会自动补章或改号。',
          ),
        );
      }
    } catch (_) {
      issues.add(
        const ConversionPreflightIssue(
          category: 'chapters',
          level: ConversionPreflightLevel.blocking,
          title: '章节检查失败',
          detail: '未能取得当前诊断结果；可重试检查，或直接转换。',
          canOpenRepair: true,
          action: ConversionPreflightAction.chapters,
        ),
      );
    }

    // Text cleanup has its own automatic detection loop.  Keep it in the
    // same source-bound preflight as chapter review so a conversion cannot
    // silently skip visible cleanup candidates.  The default pipeline is a
    // detection-only suggestion when the user has not enabled saved cleanup
    // settings; it never changes the source or the production request.
    final savedCleanup = state.cleanup.drafts[book.id];
    final cleanup = LegacyCleanupSession(state, book.id);
    try {
      final report = await cleanup.recheck();
      final changes = report.changes;
      final candidates = report.candidates;
      const stages = 0;
      if (changes == 0 && candidates == 0) {
        issues.add(
          ConversionPreflightIssue(
            category: 'cleanup',
            level: ConversionPreflightLevel.pass,
            title: savedCleanup == null ? '文本清理自动检查通过' : '文本清理设置检查通过',
            detail: savedCleanup == null
                ? '内置安全检测没有发现空白或段落清理候选；未自动修改正文。'
                : '当前已保存的清理设置没有产生差异；原稿仍保持只读。',
          ),
        );
      } else {
        issues.add(
          ConversionPreflightIssue(
            category: 'cleanup',
            level: ConversionPreflightLevel.warning,
            title: savedCleanup == null
                ? '文本清理发现 ${changes + candidates} 项候选'
                : '文本清理仍有 ${changes + candidates} 项差异',
            detail: savedCleanup == null
                ? '检测到尾随空白、空行或其他可审阅候选；请打开文本清理面板决定是否应用，不会自动改写原稿。'
                : '已保存的清理设置产生 $changes 项最终差异、$candidates 项候选和 $stages 项步骤记录；请在文本清理面板查看逐步预览，转换不会自动删除候选正文。',
            canOpenRepair: true,
            action: ConversionPreflightAction.cleanup,
          ),
        );
      }
    } catch (_) {
      issues.add(
        const ConversionPreflightIssue(
          category: 'cleanup',
          level: ConversionPreflightLevel.blocking,
          title: '文本清理检查失败',
          detail: '未能取得清理检查结果；可打开文本清理面板重试，或直接转换。',
          canOpenRepair: true,
          action: ConversionPreflightAction.cleanup,
        ),
      );
    } finally {
      cleanup.dispose();
    }

    try {
      final publication = state.publicationRequest(book.id);
      publication['settings'] = conversionSettings(
        publication['settings'] as Map,
        publicationOverrides[book.id],
      );
      final resources = (jsonDecode(
        await api.publicationResourcesText(
          requestJson: jsonEncode(publication),
        ),
      ) as Map).cast<String, dynamic>();
      final manifest = (resources['manifest'] as Map?)?.cast<String, dynamic>();
      final pending =
          (state.production.importedResourcesFor(book.id)?['pending_images']
                      as List? ??
                  const [])
              .whereType<Map>()
              .toList();
      if (pending.isEmpty) {
        issues.add(
          const ConversionPreflightIssue(
            category: 'resources',
            level: ConversionPreflightLevel.pass,
            title: '资源准备通过',
            detail: '封面、插图、CSS 和字体引用可以进入当前制作计划。',
          ),
        );
      } else {
        issues.add(
          ConversionPreflightIssue(
            ruleId: 'preflight.imported_images',
            category: 'resources',
            level: ConversionPreflightLevel.warning,
            title: '有 ${pending.length} 项导入图片待确认',
            detail: '当前成品只会使用已确认且可解码的资源；请在图片与资源页查看待处理项。',
            canOpenRepair: true,
            action: ConversionPreflightAction.resources,
          ),
        );
      }
      // V24（OUT-078）：为 Kindle 转换的封面与插图，逐张列出转换前后的格式与尺寸。
      final conversions = (manifest?['image_conversions'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      if (conversions.isNotEmpty) {
        issues.add(
          ConversionPreflightIssue(
            category: 'resources',
            level: ConversionPreflightLevel.info,
            title: '将转换 ${conversions.length} 张图片',
            detail: [
              '为 Kindle 转成可用的 JPEG 或 PNG，原图不变：',
              for (final c in conversions) imageConversionLine(c),
            ].join('\n'),
          ),
        );
      }
      if (manifest == null) {
        issues.add(
          const ConversionPreflightIssue(
            category: 'resources',
            level: ConversionPreflightLevel.blocking,
            title: '资源清单缺失',
            detail: '制作清单没有返回，不能把资源状态当作已检查。',
          ),
        );
      }
    } catch (_) {
      // Diagnose only failed preparation. Valid covers do not get decoded twice.
      var invalidCover = false;
      if (cover.isNotEmpty && !issues.any((issue) => issue.isCoverIssue)) {
        try {
          await api.inspectImageText(path: cover);
        } catch (_) {
          invalidCover = true;
        }
      }
      issues.add(
        ConversionPreflightIssue(
          category: 'resources',
          level: ConversionPreflightLevel.blocking,
          title: invalidCover ? '封面图片未通过校验' : '资源准备未通过',
          detail: invalidCover
              ? '当前封面未能通过读取与解码校验：$cover'
              : '至少一项封面、插图、CSS、字体或目录资源不可用；请在资源页处理后重新检查。',
          isCoverIssue: invalidCover,
          canOpenRepair: true,
          action: invalidCover
              ? ConversionPreflightAction.metadata
              : ConversionPreflightAction.resources,
        ),
      );
    }
    if (guard != state.publicationContext(book.id)) {
      throw const FormatException('书稿设置已变化，请重新检查。');
    }
    final disabled =
        (settings['rule_options'] as Map?)?['disabled'] as List? ?? const [];
    issues.removeWhere(
      (issue) =>
          issue.ruleId != null &&
          disabled.contains(issue.ruleId) &&
          !const [
            'preflight.title',
            'preflight.converter',
          ].contains(issue.ruleId),
    );
    return ConversionPreflightReport(
      bookId: book.id,
      title: state.displayTitle(book),
      issues: List.unmodifiable(issues),
    );
  }
}

/// 一张图片的转换说明（OUT-078），如“cover.webp：WebP 1200×1800 → JPEG 1200×1800（格式）”。
String imageConversionLine(Map c) {
  String name(Object? f) => switch ('$f') {
    'jpg' || 'jpeg' => 'JPEG',
    'webp' => 'WebP',
    final other => other.toUpperCase(),
  };
  const reasons = {
    'format': 'Kindle 不支持该格式',
    'cmyk': 'CMYK 转 RGB',
    'progressive': '渐进式改为普通 JPEG',
    'oversize': '缩小到 2560×1600 以内',
    'animation': '动图只取第一帧',
  };
  final file = '${c['path'] ?? ''}'.split(RegExp(r'[\\/]')).last;
  final why = [
    for (final r in (c['reasons'] as List? ?? const [])) reasons['$r'] ?? '$r',
  ].join('、');
  return '$file：${name(c['from_format'])} ${c['from_width']}×${c['from_height']} → '
      '${name(c['to_format'])} ${c['to_width']}×${c['to_height']}（$why）';
}
