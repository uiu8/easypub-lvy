import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/application/conversion_service.dart';
import 'package:easypub_desktop/infrastructure/native_conversion_desktop.dart';

void main() {
  testWidgets('import checks selected cleanup rules and retains reports across pages', (tester) async {
    await tester.runAsync(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path));
      final root = await Directory.systemTemp.createTemp('easypub-auto-check-');
      final backend = PrototypeState(settingsDirectory: '${root.path}/settings');
      final library = LegacyLibraryAdapter(backend: backend);
      try {
        expect(await library.load(), true);
        expect(await library.savePatch({'automatic_cleanup_rules':['trim_trailing_spaces']}), true);
        final file = File('${root.path}/sample.txt');
        const original = '第一章 开始\n正文尾部有空格  \n\n\n第二章 接续\n正文。\n';
        await file.writeAsString(original);
        final imported = await library.importFiles([file.path]);
        expect(imported.single.succeeded, true);
        final id = library.books.value.single.id;
        expect(library.books.value.single.status, contains('检查完成'));
        final checks = library.openChecks(id);
        final report = (checks as CachedBookCheckSession).latest!;
        expect(report.domains.firstWhere((d) => d.id == 'cleanup').items, hasLength(1));
        checks.dispose();
        final reopened = library.openChecks(id);
        expect((reopened as CachedBookCheckSession).latest, same(report));
        expect(await library.savePatch({'automatic_cleanup_rules':[]}), true);
        expect(reopened.isCurrent(report), false);
        final disabled = await reopened.inspect();
        expect(disabled.domains.firstWhere((d) => d.id == 'cleanup').items, isEmpty);
        reopened.dispose();
        final conversion = library.openConversion();
        final plan = await conversion.preview(ConversionRequest(
          books:[id], directory:'${root.path}/output', format:'EPUB',
          generateCover:true, runChecks:false,
        ));
        expect(plan.blocked, false, reason: plan.findings.map((f)=>f.detail).join('\n'));
        final outputs = await conversion.commit(plan, acknowledgeWarnings:true);
        expect(outputs.single.complete, true);
        final outputEntries = await Directory('${root.path}/output').list().toList();
        expect(outputEntries, hasLength(1));
        expect(outputEntries.single.path, endsWith('.epub'));
        expect(await file.readAsString(), original);
        final desktop = await NativeConversionDesktop().defaultOutputDirectory();
        expect(Directory(desktop).isAbsolute, true);
        expect(await Directory(desktop).exists(), true);
        conversion.dispose();
      } finally {
        library.dispose();
        backend.dispose();
      }
    });
  });
}
