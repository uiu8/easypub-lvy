import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../application/conversion_service.dart';
import '../../application/library_service.dart';
import '../../application/settings_service.dart';

/// 设置里 EPUB 的默认转换路径是否为“保持原格式”（V27，OUT-080）。
bool epubOriginalDefault(LibraryService library) =>
    library is SettingsService &&
    (library as SettingsService)
            .snapshot
            .value
            .configuration['epub_conversion_mode'] ==
        'original';

bool isEpubBook(BookSummary book) => book.format.toUpperCase() == 'EPUB';

/// 本次要保持原格式的书：EPUB 书按单独的选择，没选过的按设置默认。
Set<String> keepOriginalEpubFor(
  ConversionFormDraft draft,
  LibraryService library,
  Iterable<String> ids,
) {
  final fallback = epubOriginalDefault(library);
  final epub = {
    for (final b in library.books.value)
      if (isEpubBook(b)) b.id,
  };
  return {
    for (final id in ids)
      if (epub.contains(id) && (draft.epubOriginal[id] ?? fallback)) id,
  };
}

class ConversionFormDraft extends ChangeNotifier {
  final reviewing = ValueNotifier<bool>(false);
  bool initialized = false, openWhenDone = false;
  bool selectionInitialized = false;
  String directory = '', engine = '', format = 'EPUB', language = '';
  bool generateCover = true;
  bool autoCheck = false;
  Set<String> selected = {};

  /// 每本 EPUB 书单独选的转换路径：true 保持原格式，false 使用软件排版；没选过的按设置默认（V27，OUT-079）。
  final Map<String, bool> epubOriginal = {};
  final Set<String> manualDefaults = {};
  Map<String, Object>? defaultValues;
  static const defaultLabels = {
    'output_directory': '输出目录',
    'output_format': '输出格式',
    'kindle_converter': '转换器',
    'generate_cover': '缺少封面时生成',
    'check_before_conversion': '转换前检查',
  };
  ConversionPreview? pendingPreview;
  Future<void> Function(String)? changeFormat;
  void Function(String)? changeDirectory;
  Future<void> Function()? startConversion;
  Future<void> Function()? checkConversion;
  bool actionEnabled = false;
  bool confirming = false;
  Object? activeForm;
  bool _notificationPending = false;
  bool _disposed = false;

  bool get hasActiveForm => activeForm != null;

  /// 绑定当前挂载的转换页表单处理器（V105，P0-06）：收口页面与顶层壳层/底栏的生命周期契约。
  void bindActiveForm(
    Object owner, {
    required Future<void> Function(String) onChangeFormat,
    required void Function(String) onChangeDirectory,
    required Future<void> Function() onCheckConversion,
    required Future<void> Function() onStartConversion,
  }) {
    activeForm = owner;
    changeFormat = onChangeFormat;
    changeDirectory = onChangeDirectory;
    checkConversion = onCheckConversion;
    startConversion = onStartConversion;
  }

  /// 卸载当前转换页时解绑处理器；仅当持有者一致时清空，防止新旧路由切换竞态。
  void unbindActiveForm(Object owner) {
    if (!identical(activeForm, owner)) return;
    activeForm = null;
    changeFormat = null;
    changeDirectory = null;
    startConversion = null;
    checkConversion = null;
    actionEnabled = false;
    changed();
  }

  void changed() {
    if (_notificationPending || _disposed) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  ConversionRequest requestFor(
    List<String> books, {
    Set<String> keepOriginalEpub = const {},
  }) => ConversionRequest(
    keepOriginalEpub: keepOriginalEpub,
    books: books,
    directory: directory,
    format: format,
    engine: engine,
    language: language,
    generateCover: generateCover,
    runChecks: autoCheck,
  );

  @override
  void dispose() {
    _disposed = true;
    reviewing.dispose();
    super.dispose();
  }

  void adoptRequest(
    ConversionRequest request,
    ConversionPreview? preview, {
    bool preserveDefaults = false,
  }) {
    final previousManual = Set<String>.of(manualDefaults);
    final previousDefaults = defaultValues;
    final previousOpenWhenDone = openWhenDone;
    reset();
    initialized = true;
    directory = request.directory;
    engine = request.engine;
    format = request.format;
    language = request.language;
    generateCover = request.generateCover;
    autoCheck = request.runChecks;
    selected = request.books.toSet();
    selectionInitialized = true;
    for (final id in request.keepOriginalEpub) {
      epubOriginal[id] = true;
    }
    manualDefaults.addAll(
      preserveDefaults ? previousManual : defaultLabels.keys,
    );
    if (preserveDefaults) {
      defaultValues = previousDefaults;
      openWhenDone = previousOpenWhenDone;
    }
    pendingPreview = preview;
    reviewing.value = preview != null;
    changed();
  }

  void reset() {
    pendingPreview = null;
    initialized = false;
    openWhenDone = autoCheck = false;
    directory = engine = language = '';
    format = 'EPUB';
    generateCover = true;
    selected = {};
    selectionInitialized = false;
    epubOriginal.clear();
    manualDefaults.clear();
    defaultValues = null;
    changed();
  }
}
