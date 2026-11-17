import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/desk/conversion/conversion_form_draft.dart';
import 'package:easypub_desktop/desk/conversion/conversion_draft_persistence.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';

void main() {
  test('仅排版页选择原格式时，未初始化的转换草稿也能从磁盘恢复', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = await Directory('../artifacts')
        .createTemp('conversion-recovery-');
    final settings = '${root.absolute.path}/settings';
    final library = LegacyLibraryAdapter(settingsDirectory: settings);
    final draft = ConversionFormDraft();
    try {
      await library.load();
      expect(await library.initializeWorkspace(), true);
      // 排版页改变选择时不会初始化转换页表单；同时保留 true 和 false。
      draft.epubOriginal.addAll({'book-a': true, 'book-b': false});
      expect(draft.initialized, false);
      ConversionDraftPersistence.save(library, draft);
      expect(await library.flushWorkspace(), true);
    } finally {
      await library.closeWorkspaceStorage();
      library.dispose();
      draft.dispose();
    }
    final reopened = LegacyLibraryAdapter(settingsDirectory: settings);
    final restored = ConversionFormDraft();
    try {
      await reopened.load();
      expect(await reopened.initializeWorkspace(), true);
      ConversionDraftPersistence.restore(reopened, restored);
      expect(restored.initialized, false);
      expect(restored.epubOriginal, {'book-a': true, 'book-b': false});
      // 旧版本草稿没有逐书选择时，继续使用原来的默认值。
      reopened.writeDraft(ConversionDraftPersistence.key, {'format': 'EPUB'});
      ConversionDraftPersistence.restore(reopened, restored);
      expect(restored.epubOriginal, isEmpty);
    } finally {
      await reopened.closeWorkspaceStorage();
      reopened.dispose();
      restored.dispose();
    }
  });
}
