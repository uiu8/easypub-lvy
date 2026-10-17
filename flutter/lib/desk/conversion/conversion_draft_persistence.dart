// 迁入 desk（conversion，V5/V6）：逻辑与布局沿用 V5 前的同名文件；公共弹窗框架样式在 V7 统一。
import '../../application/library_service.dart';
import '../../application/workspace_autosave_service.dart';
import 'conversion_page.dart';

/// Owns the JSON boundary for the conversion form's workspace draft.
/// The app shell only decides when to restore or save; conversion fields stay
/// versioned in the conversion feature.
abstract final class ConversionDraftPersistence {
  static const key = 'workspace/output';

  static void restore(LibraryService library, ConversionFormDraft draft) {
    if (library is! WorkspaceAutosaveService) return;
    final workspace = library as WorkspaceAutosaveService;
    final value = workspace.readDraft(key);
    if (value == null) return;
    draft
      ..initialized = value['initialized'] == true
      ..directory = value['directory'] as String? ?? ''
      ..format = value['format'] as String? ?? 'EPUB'
      ..engine = value['engine'] as String? ?? ''
      ..language = value['language'] as String? ?? ''
      ..generateCover = value['generateCover'] != false
      ..autoCheck = value['autoCheck'] == true
      ..openWhenDone = value['openWhenDone'] == true
      ..selectionInitialized = value['selectionInitialized'] == true
      ..selected = (value['selected'] as List? ?? []).cast<String>().toSet();
    draft.manualDefaults.addAll(
      (value['manualDefaults'] as List? ?? []).cast<String>(),
    );
    if (value['defaultValues'] case final Map values) {
      draft.defaultValues = Map<String, Object>.from(values);
    }
  }

  static void save(LibraryService library, ConversionFormDraft draft) {
    if (library is! WorkspaceAutosaveService || !draft.initialized) return;
    final workspace = library as WorkspaceAutosaveService;
    workspace.writeDraft(key, {
      'initialized': draft.initialized,
      'directory': draft.directory,
      'format': draft.format,
      'engine': draft.engine,
      'language': draft.language,
      'generateCover': draft.generateCover,
      'autoCheck': draft.autoCheck,
      'openWhenDone': draft.openWhenDone,
      'selected': draft.selected.toList(),
      'selectionInitialized': draft.selectionInitialized,
      'manualDefaults': draft.manualDefaults.toList(),
      'defaultValues': draft.defaultValues,
    });
  }
}
