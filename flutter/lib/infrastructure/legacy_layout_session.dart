import '../application/layout_service.dart';
import '../application/book_information_service.dart';
import '../application/output_defaults.dart';
import '../application/conversion_snapshot.dart';
import 'legacy_book_information_session.dart';

import 'dart:convert';
import 'dart:io';

import '../src/rust/api.dart' as api;

/// Reuses only the nonvisual, Rust-backed confirmation transaction.
class LegacyLayoutSession extends LegacyBookInformationSession
    implements
        LayoutSession,
        LayoutPublicationPreviewSession,
        LayoutDraftPreviewSession,
        LayoutPreviewDeviceStore,
        ChapterStyleStore {
  LegacyLayoutSession(super.backend, super.bookId, {this.launchPreview});
  final Future<void> Function(String path)? launchPreview;
  LayoutPublicationPreview? _generatedPreview;

  File? get _deviceFile => backend.settingsDirectory == null
      ? null
      : File('${backend.settingsDirectory}/layout-preview-device.json');

  @override
  Future<String?> readPreviewDevice() async {
    final file = _deviceFile;
    if (file == null || !await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> savePreviewDevice(String value) async {
    final file = _deviceFile;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(value, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<LayoutPublicationPreview> renderPreview({String? entryId}) async {
    final data = await _render(entryId: entryId);
    return _generatedPreview = LayoutPublicationPreview(
      publicationId: data['publication_id'] as String,
      path: data['selected_path'] as String,
      documents: [
        for (final row in (data['documents'] as List).cast<Map>())
          (path: row['path'] as String, title: row['title'] as String),
      ],
    );
  }

  @override
  Future<LayoutDraftPreview> renderDraftPreview(
    Map<String, Object?> values, {
    String? entryId,
  }) async {
    if (values.keys.any((key) => !layoutFields.contains(key))) {
      throw const FormatException('预览只接受排版字段。');
    }
    final data = await _render(entryId: entryId, draft: values);
    final directory = data['directory'] as String;
    final content = (data['content_path'] as String)
        .substring(directory.length)
        .replaceAll('\\', '/')
        .replaceFirst(RegExp('^/+'), '');
    return LayoutDraftPreview(
      directory: directory,
      content: content,
      title: backend.production.settings(bookId)['title'] as String? ?? '',
      anchor: data['anchor'] as String?,
    );
  }

  /// 生成实际内容；[draft] 为还没保存的排版值（真机预览），只用于这一次生成。
  Future<Map> _render({String? entryId, Map<String, Object?>? draft}) async {
    fresh();
    final guard = backend.publicationContext(bookId);
    final publication = backend.publicationRequest(bookId);
    final settings = Map<String, dynamic>.from(publication['settings'] as Map);
    if (draft != null && draft.isNotEmpty) {
      // 设置来源记录的值必须与设置一致：改动的字段按“本书”记录，只用于这一次生成。
      final origins = Map<String, dynamic>.from(
        settings['layout_origins'] as Map? ?? const {},
      );
      for (final entry in draft.entries) {
        if (entry.value == settings[entry.key]) continue;
        settings[entry.key] = entry.value;
        if (origins.containsKey(entry.key)) {
          origins[entry.key] = {'source': 'book', 'value': entry.value};
        }
      }
      settings['layout_origins'] = origins;
    }
    publication['settings'] = conversionSettings(settings, {
      'language': resolveOutputLanguage(
        book: settings['language'] as String?,
        fallback: backend.globalConfiguration['default_language'] as String?,
      ),
    });
    late Map data;
    try {
      data = jsonDecode(
        await api.epubExportText(
          requestJson: jsonEncode({
            'op': 'render_preview',
            'publication': publication,
            'entry_id': ?entryId,
          }),
        ),
      ) as Map;
    } on api.ApiError catch (error) {
      final detail =
          jsonDecode(await api.describeApiError(error: error)) as Map;
      throw FormatException(
        detail['error'] == 'Io'
            ? '无法读取预览所需的文件，请检查本书图片与字体资源。'
            : '实际预览未生成，请检查本书排版设置与资源。',
      );
    }
    fresh();
    if (guard != backend.publicationContext(bookId)) {
      throw const FormatException('书稿已变化，请重新生成预览。');
    }
    return data;
  }

  @override
  Future<void> openPreview(LayoutPublicationPreview preview) async {
    fresh();
    if (!identical(preview, _generatedPreview) ||
        !await File(preview.path).exists()) {
      throw const FormatException('预览已失效，请重新生成。');
    }
    if (launchPreview != null) {
      await launchPreview!(preview.path);
    } else {
      await Process.start('explorer.exe', [preview.path], runInShell: false);
    }
  }

  /// 统一章首图的图片路径与封面一样属于本书（V54，LAY-124）：可读写，但不进草稿、预设与批量。
  @override
  Set<String> get allowedFields => {
    ...layoutFields,
    'chapter_head_image',
    'chapter_style',
  };

  @override
  Future<Map<String, dynamic>> chapterStyleRequest(
    Map<String, Object?> request,
  ) async {
    final base = backend.settingsDirectory ?? Directory.systemTemp.path;
    final dir = Directory('$base/style_packs')..createSync(recursive: true);
    return backend.production.productionRequest(
      jsonEncode({'op': 'chapter_style', 'dir': dir.absolute.path, ...request}),
    );
  }

  String? _globalToken;
  List<Map<String, dynamic>>? _globals;
  CssPreview? _cssPreview;

  @override
  Map<String, Object?> get savedCss {
    fresh();
    final values = backend.production.settings(bookId);
    return Map.unmodifiable({
      'text': values['additional_css'],
      'base': values['additional_css_base'],
      'offline': values['additional_css_bundle'] != null,
    });
  }

  @override
  Future<CssPreview> previewCss(String text, String base) async {
    _cssPreview = null;
    final change = await previewChange({
      'op': 'patch',
      'fields': {
        'additional_css': {'op': 'set', 'value': text},
        'additional_css_base': {'op': 'set', 'value': base.trim()},
      },
    });
    final report =
        ((pending!.result['items'] as List).single as Map)['css_dependencies']
            as Map;
    return _cssPreview = CssPreview(
      change,
      (report['issues'] as List).cast<String>(),
      (report['files'] as List).map((file) => file['path'] as String).toList(),
      report['total_bytes'] as int,
    );
  }

  @override
  Future<void> applyCss(CssPreview preview) async {
    if (!identical(preview, _cssPreview) || preview.issues.isNotEmpty) {
      throw const FormatException('请解决依赖问题并重新检查。');
    }
    await apply(preview.change);
    _cssPreview = null;
  }

  @override
  Future<List<LayoutPreset>> readPresetFile(String path) async {
    fresh();
    final data = jsonDecode(
      await api.layoutPresetFileText(
        requestJson: jsonEncode({'op': 'read', 'path': path}),
      ),
    ) as Map;
    fresh();
    return List.unmodifiable(
      (data['presets'] as List).map(
        (value) => LayoutPreset(
          value['name'] as String,
          Map<String, Object?>.from(value['values'] as Map),
        ),
      ),
    );
  }

  @override
  Future<void> exportPresetFile(String name, String path) async {
    fresh();
    final preset = copyPreset(
      backend.layoutPresets.firstWhere((value) => value['name'] == name),
    );
    await api.layoutPresetFileText(
      requestJson: jsonEncode({
        'op': 'write',
        'path': path,
        'bundle': {
          'schema_version': 1,
          'kind': 'easypub_layout_presets',
          'presets': [preset],
        },
      }),
    );
  }

  @override
  Future<void> importPreset(LayoutPreset preset) async {
    fresh();
    if (backend.layoutPresets.length >= 64 ||
        backend.layoutPresets.any(
          (value) =>
              (value['name'] as String).trim().toLowerCase() ==
              preset.name.trim().toLowerCase(),
        )) {
      throw const FormatException('项目已有同名预设或达到上限，不会覆盖。');
    }
    final copy = <String, dynamic>{
      'name': preset.name,
      'values': Map.of(preset.values),
    };
    await previewChange({'op': 'apply_layout_preset', 'preset': copy});
    fresh();
    backend.change(
      () => backend.layoutPresets = [...backend.layoutPresets, copy],
    );
    super.saved;
  }

  @override
  Future<LayoutPreset> builtinPreset() async {
    fresh();
    final values = await backend.resolvedFactoryLayout();
    fresh();
    return LayoutPreset('出厂默认', values);
  }

  Map<String, dynamic> copyPreset(Map value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

  @override
  Future<void> renamePreset(String name, String replacement) async {
    fresh();
    replacement = replacement.trim();
    if (backend.layoutPresets.any(
      (value) =>
          value['name'] != name &&
          (value['name'] as String).trim().toLowerCase() ==
              replacement.toLowerCase(),
    )) {
      throw const FormatException('已有同名预设。');
    }
    final renamed = copyPreset(
      backend.layoutPresets.firstWhere((value) => value['name'] == name),
    )..['name'] = replacement;
    await previewChange({'op': 'apply_layout_preset', 'preset': renamed});
    fresh();
    backend.change(
      () => backend.layoutPresets = [
        for (final preset in backend.layoutPresets)
          preset['name'] == name ? renamed : preset,
      ],
    );
    super.saved;
  }

  @override
  Future<List<LayoutPreset>> readGlobalPresets() async {
    fresh();
    if (!await backend.loadGlobalSettings()) {
      throw const FormatException('无法读取全局预设。');
    }
    fresh();
    _globalToken = backend.globalSettingsToken;
    _globals = (backend.globalConfiguration['layout_presets'] as List)
        .map((value) => copyPreset(value as Map))
        .toList();
    return List.unmodifiable(
      _globals!.map(
        (value) => LayoutPreset(
          value['name'] as String,
          Map<String, Object?>.from(value['values'] as Map),
        ),
      ),
    );
  }

  void globalsFresh() {
    fresh();
    if (_globals == null || _globalToken != backend.globalSettingsToken) {
      throw const FormatException('请重新读取全局预设后重试。');
    }
  }

  @override
  Future<void> publishPreset(String name) async {
    globalsFresh();
    final preset = copyPreset(
      backend.layoutPresets.firstWhere((value) => value['name'] == name),
    );
    if (_globals!.any(
      (value) =>
          (value['name'] as String).trim().toLowerCase() ==
          name.trim().toLowerCase(),
    )) {
      throw const FormatException('全局已有同名预设，不会覆盖。');
    }
    if (!await backend.saveGlobalPresets([
      ..._globals!,
      preset,
    ], _globalToken)) {
      throw const FormatException('保存全局预设失败或配置已变化，请重新读取。');
    }
    _globals = null;
  }

  @override
  Future<void> copyGlobalPreset(String name) async {
    globalsFresh();
    if (backend.layoutPresets.length >= 64 ||
        backend.layoutPresets.any(
          (value) =>
              (value['name'] as String).trim().toLowerCase() ==
              name.trim().toLowerCase(),
        )) {
      throw const FormatException('项目已有同名预设或达到上限，不会覆盖。');
    }
    final preset = copyPreset(
      _globals!.firstWhere((value) => value['name'] == name),
    );
    await previewChange({'op': 'apply_layout_preset', 'preset': preset});
    globalsFresh();
    backend.change(
      () => backend.layoutPresets = [...backend.layoutPresets, preset],
    );
    super.saved;
  }

  @override
  Future<void> deleteGlobalPreset(String name) async {
    globalsFresh();
    if (!_globals!.any((value) => value['name'] == name)) {
      throw const FormatException('预设已不存在。');
    }
    if (!await backend.saveGlobalPresets(
      _globals!.where((value) => value['name'] != name).toList(),
      _globalToken,
    )) {
      throw const FormatException('删除全局预设失败或配置已变化，请重新读取。');
    }
    _globals = null;
  }

  @override
  String guard() => jsonEncode([super.guard(), backend.layoutPresets]);

  @override
  List<LayoutPreset> get presets {
    fresh();
    return List.unmodifiable(
      backend.layoutPresets.map(
        (preset) => LayoutPreset(
          preset['name'] as String,
          Map<String, Object?>.from(preset['values'] as Map),
        ),
      ),
    );
  }

  @override
  Future<void> savePreset(String name, Map<String, Object?> values) async {
    fresh();
    name = name.trim();
    if (name.isEmpty ||
        utf8.encode(name).length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        backend.layoutPresets.length >= 64 ||
        backend.layoutPresets.any(
          (preset) =>
              (preset['name'] as String).trim().toLowerCase() ==
              name.toLowerCase(),
        )) {
      throw const FormatException('名称无效、重复或已达64项上限。');
    }
    if (values.keys.any((key) => !layoutFields.contains(key))) {
      throw const FormatException('预设包含不支持的字段。');
    }
    final preset = <String, dynamic>{
      'name': name,
      'values': Map<String, Object?>.from(values),
    };
    await previewChange({'op': 'apply_layout_preset', 'preset': preset});
    fresh();
    backend.change(
      () => backend.layoutPresets = [...backend.layoutPresets, preset],
    );
    super.saved; // Refresh guard and invalidate validation-only preview.
  }

  @override
  void deletePreset(String name) {
    fresh();
    if (!backend.layoutPresets.any((preset) => preset['name'] == name)) {
      throw const FormatException('预设已不存在。');
    }
    backend.change(
      () => backend.layoutPresets = backend.layoutPresets
          .where((preset) => preset['name'] != name)
          .toList(),
    );
    super.saved;
  }

  @override
  Future<BookInformationPreview> previewPreset(String name) {
    fresh();
    final preset = backend.layoutPresets.firstWhere(
      (value) => value['name'] == name,
    );
    return previewChange({
      'op': 'apply_layout_preset',
      'preset': jsonDecode(jsonEncode(preset)),
    });
  }

  @override
  Map<String, Object?> get origins {
    fresh();
    return Map<String, Object?>.from(
      backend.production.settings(bookId)['layout_origins'] as Map? ?? {},
    );
  }

  @override
  Future<BookInformationPreview> restoreFields(
    Set<String> fields, {
    required bool global,
  }) async {
    fresh();
    fields = Set.unmodifiable(fields);
    if (fields.isEmpty ||
        fields.length > 13 ||
        fields.any((key) => !layoutFields.contains(key))) {
      throw const FormatException('请选择1至13项排版字段。');
    }
    if (global && !await backend.loadGlobalSettings()) {
      throw const FormatException('全局默认设置读取失败。');
    }
    final defaults = global
        ? await backend.resolvedGlobalLayout()
        : await backend.resolvedFactoryLayout();
    fresh();
    return previewChange({
      'op': 'restore_layout',
      'source': global ? 'global' : 'factory',
      'defaults': defaults,
      'fields': fields.toList(),
    });
  }
}
