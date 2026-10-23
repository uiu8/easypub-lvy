import '../application/resource_service.dart';
import '../application/book_information_service.dart';
import '../application/chapter_service.dart';
import 'legacy_book_information_session.dart';
import '../src/rust/api.dart' as api;

import 'dart:io';
import 'dart:convert';

class LegacyResourceSession extends LegacyBookInformationSession
    implements ResourceSession, ResourcePlacementSession, ResourceLocator {
  LegacyResourceSession(super.backend, super.bookId);
  @override
  String guard() => backend.publicationContext(bookId);

  @override
  Future<List<ChapterNode>> placementChapters() async {
    fresh();
    final tree = await backend.manuscript.effectiveTree(
      bookId,
      0,
      outline: true,
    );
    fresh();
    return [
      chapterPrefixNode,
      for (final node in (tree['nodes'] as List).cast<Map>())
        ChapterNode(
          node['entry_id'] as String,
          node['title'] as String,
          node['role'] as String,
          node['depth'] as int,
          node['source_line'] as int,
          node['include_toc'] == true,
        ),
    ];
  }

  @override
  Future<ResourceParagraphPage> placementParagraphs(
    String nodeId,
    int offset,
  ) async {
    fresh();
    final tree = await backend.manuscript.effectiveTree(
      bookId,
      0,
      previewNodeId: nodeId,
      previewOffset: offset,
    );
    fresh();
    final body = tree['body_preview'] as Map;
    return ResourceParagraphPage(
      [
        for (final row in (body['rows'] as List).cast<Map>())
          ResourceParagraph(
            '${row['text']}${row['truncated'] == true ? '…' : ''}',
            row['original_source_line'] as int?,
            row['line_offset'] as int,
          ),
      ],
      offset,
      body['total'] as int,
    );
  }

  @override
  Future<Map<int, CoverImageEvidence?>> inspectRelink(
    Map<int, String> paths,
  ) async {
    fresh();
    final result = <int, CoverImageEvidence?>{};
    final cached = <String, CoverImageEvidence?>{};
    for (final entry in Map<int, String>.unmodifiable(paths).entries) {
      final path = entry.value.trim();
      if (!cached.containsKey(path)) {
        try {
          cached[path] = await inspectImage(path);
        } catch (_) {
          fresh();
          cached[path] = null;
        }
      }
      fresh();
      result[entry.key] = cached[path];
    }
    return Map.unmodifiable(result);
  }

  @override
  Future<BookInformationPreview> relink(Map<int, String> replacements) async {
    fresh();
    final paths = Map<int, String>.unmodifiable(replacements);
    if (paths.isEmpty) throw const FormatException('请选择需要重新定位的图片。');
    final settings = backend.production.settings(bookId);
    final images = (settings['illustrations'] as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final fields = <String, Object?>{};
    final checked = <String>{};
    for (final entry in paths.entries) {
      if (entry.key < -1 ||
          entry.key >= images.length ||
          (entry.key == -1 && settings['cover_path'] == null) ||
          entry.value.trim().isEmpty) {
        throw const FormatException('引用或路径无效，请重新读取资源。');
      }
      final path = entry.value.trim();
      if (checked.add(path)) await inspectImage(path);
      if (entry.key == -1) {
        fields['cover_path'] = {'op': 'set', 'value': path};
      } else {
        images[entry.key]['path'] = path;
      }
    }
    if (paths.keys.any((key) => key >= 0)) {
      fields['illustrations'] = {'op': 'set', 'value': images};
    }
    return previewChange({'op': 'patch', 'fields': fields});
  }

  @override
  Future<ResourceLocation> locate(int index) async {
    fresh();
    final positions = await backend.production.illustrationPositions(bookId);
    fresh();
    if (index < 0 || index >= positions.length) {
      throw const FormatException('插图已改变，请重新检查。');
    }
    return _location(positions[index]);
  }

  @override
  Future<List<ResourceLocation>> locateAll() async {
    fresh();
    final positions = await backend.production.illustrationPositions(bookId);
    fresh();
    return [for (final row in positions) _location(row)];
  }

  ResourceLocation _location(Map row) {
    final placed =
        row['status'] != 'needs_relocation' && row['status'] != 'unplaced';
    return ResourceLocation(
      row['entry_id'] as String?,
      row['node_offset'] as int?,
      row['heading'] as String? ?? '',
      switch (row['status']) {
        'needs_relocation' => '原插入行已在编辑中移除，需要重新定位。',
        'unplaced' => '此插图尚未设置插入位置。',
        _ =>
          row['entry_id'] == null
              ? '插图位于首个章节之前。'
              : '编辑后第 ${row['output_line']} 行之后',
      },
      outputLine: placed ? row['output_line'] as int? : null,
    );
  }

  @override
  Future<List<BookResource>> read() async {
    // Explicit refresh adopts the latest book revision and cancels old previews.
    super.saved;
    fresh();
    final settings = backend.production.settings(bookId);
    final records = <Map>[];
    if (settings['cover_path'] != null) {
      records.add({'index': -1, 'path': settings['cover_path']});
    }
    final illustrations = settings['illustrations'] as List;
    for (var i = 0; i < illustrations.length; i++) {
      records.add({...illustrations[i] as Map, 'index': i});
    }
    final result = <BookResource>[];
    final inspected = <String, CoverImageEvidence?>{};
    for (final record in records) {
      final path = record['path'] as String;
      if (!inspected.containsKey(path)) {
        try {
          inspected[path] = await inspectImage(path);
        } catch (_) {
          inspected[path] = null;
        }
      }
      fresh();
      final evidence = inspected[path];
      result.add(
        BookResource(
          index: record['index'] as int,
          path: path,
          caption: record['caption'] as String? ?? '',
          alt: record['alt'] as String? ?? '',
          sourceLine: record['source_line'] as int?,
          layout: record['layout'] as String? ?? 'inline',
          image: evidence,
          error: evidence == null ? '无法读取或格式不受支持' : '',
        ),
      );
    }
    var extraIndex = -2;
    final css = settings['additional_css'] as String? ?? '';
    if (css.isNotEmpty) {
      result.add(
        BookResource(
          index: extraIndex--,
          path: 'book-custom.css',
          caption: '',
          alt: '',
          sourceLine: null,
          kind: 'css',
          usage: '全书附加样式',
          status: '已保存',
          byteLength: utf8.encode(css).length,
        ),
      );
      try {
        await previewChange({'op': 'inspect'});
        final report =
            ((pending!.result['items'] as List).single
                    as Map)['css_dependencies']
                as Map;
        final issues = (report['issues'] as List).cast<String>();
        for (final file in report['files'] as List) {
          result.add(
            BookResource(
              index: extraIndex--,
              path: file['path'] as String,
              caption: '',
              alt: '',
              sourceLine: null,
              kind: 'css-dependency',
              usage: 'CSS 依赖',
              status: issues.isEmpty ? '可收集' : '已读取 · 待处理',
              byteLength: file['byte_length'] as int,
            ),
          );
        }
        for (final issue in issues) {
          result.add(
            BookResource(
              index: extraIndex--,
              path: 'CSS 依赖问题',
              caption: issue,
              alt: '',
              sourceLine: null,
              kind: 'css-issue',
              usage: 'CSS 依赖',
              error: issue,
              status: '需处理',
            ),
          );
        }
      } catch (_) {
        fresh();
        result.add(
          BookResource(
            index: extraIndex--,
            path: 'CSS 依赖检查失败',
            caption: '请在附加 CSS 中重新检查依赖。',
            alt: '',
            sourceLine: null,
            kind: 'css-issue',
            usage: 'CSS 依赖',
            error: '检查未完成',
            status: '未验证',
          ),
        );
      }
    }
    final imported = backend.production.importedResourcesFor(bookId);
    for (final group in ['images', 'css', 'fonts']) {
      for (final entry in (imported?[group] as List? ?? const [])) {
        final value = entry as Map;
        final path = value['path'] as String? ?? '';
        FileStat? stat;
        try {
          if (path.isNotEmpty) stat = await File(path).stat();
        } on FileSystemException {
          // Keep the inventory row even if its extracted file is inaccessible.
        }
        fresh();
        final exists = stat?.type == FileSystemEntityType.file;
        result.add(
          BookResource(
            index: extraIndex--,
            path: path.isEmpty ? '${value['href'] ?? '未提取资源'}' : path,
            caption: '原书资源清单；列出不代表已用于当前成品。',
            alt: '',
            sourceLine: null,
            kind: 'epub-$group',
            alreadyIllustrated: illustrations.any(
              (item) =>
                  (item['path'] as String)
                      .replaceAll('\\', '/')
                      .toLowerCase() ==
                  path.replaceAll('\\', '/').toLowerCase(),
            ),
            usage:
                'EPUB 原${group == 'images'
                    ? '图片'
                    : group == 'css'
                    ? '样式'
                    : '字体'}',
            status: exists ? '已提取 · 待复核' : '文件不可用',
            error: exists ? '' : '原书提取资源不可用',
            byteLength: exists ? stat!.size : null,
          ),
        );
      }
    }
    for (final entry in imported?['pending_images'] as List? ?? const []) {
      final value = entry as Map;
      result.add(
        BookResource(
          index: extraIndex--,
          path: '${value['path'] ?? value['href'] ?? '未定位图片'}',
          caption: '${value['reason'] ?? '导入时需人工复核'}',
          alt: '',
          sourceLine: null,
          kind: 'epub-pending',
          usage: 'EPUB 待处理图片',
          error: '${value['reason'] ?? '未完成导入定位'}',
          status: '需处理',
        ),
      );
    }
    fresh();
    return List.unmodifiable(result);
  }

  @override
  Future<BookInformationPreview> change({
    required int? index,
    required String? path,
    String caption = '',
    String alt = '',
    int? sourceLine,
    String layout = 'inline',
  }) async {
    fresh();
    if (path != null) await _checkImage(path);
    if (index == -1) {
      return previewChange({
        'op': 'patch',
        'fields': {
          'cover_path': path == null
              ? {'op': 'clear'}
              : {'op': 'set', 'value': path},
        },
      });
    }
    final illustrations =
        (backend.production.settings(bookId)['illustrations'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    if (index == null &&
        path != null &&
        illustrations.any(
          (item) =>
              (item['path'] as String).replaceAll('\\', '/').toLowerCase() ==
              path.replaceAll('\\', '/').toLowerCase(),
        )) {
      throw const FormatException('此图片已在当前插图列表中，请选择已有引用进行编辑。');
    }
    if (index != null && (index < 0 || index >= illustrations.length)) {
      throw const FormatException('资源已改变，请重新检查。');
    }
    if (path == null) {
      if (index == null) throw const FormatException('请选择要移除的引用。');
      illustrations.removeAt(index);
    } else {
      final value = {
        'path': path,
        'caption': caption,
        'alt': alt,
        'source_line': sourceLine,
        if (layout != 'inline') 'layout': layout,
      };
      if (index == null) {
        illustrations.add(value);
      } else {
        illustrations[index] = value;
      }
    }
    try {
      return await previewChange({
        'op': 'patch',
        'fields': {
          'illustrations': {'op': 'set', 'value': illustrations},
        },
      });
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      if (detail['next_action'] == 'review_production_fields') {
        throw const FormatException(
          '插入位置或说明文字无效：位置必须在原稿范围内，替代文本和图注不能换行，同一张图片不能引用两次。',
        );
      }
      rethrow;
    }
  }

  /// 预检图片并把后端的通用错误换成具体原因（RES-045）。
  Future<void> _checkImage(String path) async {
    if (path.trim().isEmpty) {
      throw const FormatException(
        '还没有选择图片。请点“浏览图片…”选择 PNG、JPG、WebP、GIF 或 BMP 文件。',
      );
    }
    final ext = path.split('.').last.toLowerCase();
    if (!path.contains('.') ||
        !['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'].contains(ext)) {
      throw FormatException('只支持 PNG、JPG、WebP、GIF、BMP 图片；所选文件的扩展名是“.$ext”。');
    }
    if (!File(path).isAbsolute) {
      throw const FormatException('图片路径必须是完整路径。请用“浏览图片…”选择文件。');
    }
    if (!await File(path).exists()) {
      throw FormatException('找不到这张图片：$path');
    }
    try {
      await inspectImage(path);
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      throw FormatException(switch (detail['next_action']) {
        'reduce_image_dimensions_or_size' =>
          '图片太大：文件须小于 32 MB，长边不超过 16384 像素，总像素不超过 1600 万。请缩小后再选。',
        'choose_readable_supported_image' =>
          '无法读取这张图片：文件可能已损坏，或内容格式与扩展名不符（例如改了扩展名的 GIF）。',
        _ => '无法读取这张图片，请换一张后重试。',
      });
    }
  }
}
