import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:go_router/go_router.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/application/library_service.dart';
import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_book_check_session.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/desk/app/rewrite_app.dart';
import 'package:easypub_desktop/desk/library/book_overview_page.dart';
import 'package:easypub_desktop/desk/catalog/source_dialog.dart';

class NoPicker extends Fake implements BookFilePicker {}
class ObservedChecks extends LegacyBookCheckSession {
  ObservedChecks(super.backend, super.bookId, this.calls);
  final List<String> calls;
  @override Future<BookCheckReport> inspect() { calls.add(bookId); return super.inspect(); }
}
class ObservedLibrary extends LegacyLibraryAdapter {
  ObservedLibrary(this.state) : super(backend: state);
  final PrototypeState state;
  final opened = <String>[], calls = <String>[];
  @override BookCheckSession openChecks(String id) { opened.add(id); return ObservedChecks(state, id, calls); }
}

void main() {
  testWidgets('audit real overview book switching and catalog input paths', (tester) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async => call.method == 'isMaximized' ? false : null);
    final out = Directory('../artifacts/audit-20261004/ui-catalog');
    final results = <String, dynamic>{'kind':'audit_observations_not_fix_acceptance','uses_real_native_library':true,'os_clipboard_used':false,'release_performance_claimed':false};
    late PrototypeState backend;
    late ObservedLibrary library;
    late String a, b, catalogId;
    final titles = List.generate(1834, (i) => '第${i+1}章 标题${i+1}');
    await tester.runAsync(() async {
      await out.create(recursive:true);
      await RustLib.init(externalLibrary:ExternalLibrary.open(File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path));
      for (final font in {'Microsoft YaHei':r'C:\Windows\Fonts\msyh.ttc','MaterialIcons':'D:/software/EasyPub-Toolchains/flutter-3.47.3/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'}.entries) {
        await (FontLoader(font.key)..addFont(File(font.value).readAsBytes().then((b)=>b.buffer.asByteData()))).load();
      }
      final tmp = await Directory.systemTemp.createTemp('easypub-ui-audit-');
      backend = PrototypeState(settingsDirectory:'${tmp.path}/settings');
      library = ObservedLibrary(backend);
      await library.load();
      for (final entry in {'甲书':'第一章 甲章\n甲正文\n第一章 甲章\n\n第二章 甲尾\n甲末\n','乙书':'第一章 乙章\n乙正文\n','目录大书':titles.map((s)=>'$s\n这里是当前章节正文。\n').join()}.entries) {
        final file=File('${tmp.path}/${entry.key}.txt');
        await file.writeAsString(entry.value);
        expect((await library.importFiles([file.path])).single.succeeded, true);
      }
      a=library.books.value.firstWhere((v)=>v.title=='甲书').id;
      b=library.books.value.firstWhere((v)=>v.title=='乙书').id;
      catalogId=library.books.value.firstWhere((v)=>v.title=='目录大书').id;
      results['book_ids']={'a':a,'b':b};
      library.opened.clear(); library.calls.clear();
    });
    Future<void> settle() async {
      for(var i=0;i<220;i++) {
        await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:15)));
        await tester.pump(const Duration(milliseconds:20));
        if(i>15 && find.byType(LinearProgressIndicator).evaluate().isEmpty && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
      expect(tester.takeException(),isNull);
    }
    final key=GlobalKey();
    library.selectBook(a);
    await tester.pumpWidget(RepaintBoundary(key:key,child:RewriteApp(library:library,picker:NoPicker(),initialLocation:'/books/${Uri.encodeComponent(a)}/overview')));
    await settle();
    final router=GoRouter.of(tester.element(find.byType(BookOverviewPage)));
    library.selectBook(b);
    router.go('/books/${Uri.encodeComponent(b)}/overview');
    await settle();
    expect(tester.widget<BookOverviewPage>(find.byType(BookOverviewPage)).bookId,b);
    await tester.ensureVisible(find.text('检查本书').last);
    await tester.tap(find.text('检查本书').last);
    await settle();
    results['overview_route_switch']={'visible_book':b,'opened_sessions':List.of(library.opened),'inspect_calls':List.of(library.calls),'wrong_book_inspected':library.calls.isNotEmpty&&library.calls.last!=b};
    await tester.runAsync(() async {
      final image=await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
      final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
      await File('${out.path}/overview-switched.png').writeAsBytes(bytes!.buffer.asUint8List()); image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final session=library.openCatalog(catalogId);
    await tester.runAsync(() async {
      final repeated=[...titles.take(2),...titles.skip(2),...titles.skip(2)].join('\n');
      var watch=Stopwatch()..start();
      final snapshot=await session.acquire('paste',repeated);
      final acquireMs=watch.elapsedMilliseconds;
      watch=Stopwatch()..start();
      final alignment=await session.preview(snapshot,identityConfirmed:true);
      results['duplicate_catalog']={'local_chapters':1834,'reference_entries':snapshot.entries.length,'matched':alignment.matched,'unresolved':alignment.unresolved,'rows':alignment.rows.length,'acquire_ms':acquireMs,'alignment_ms':watch.elapsedMilliseconds};
      expect(snapshot.entries.length,3666);
      expect(alignment.matched,2);
      expect(alignment.unresolved,5497,reason:'Audit locks down reproduced inflation, not acceptance of this behavior');
    });
    final sizes=<Map<String,dynamic>>[];
    for(final count in [3666,10000,30000]) {
      final value=List.generate(count,(i)=>'第${i+1}章 合成目录标题${i+1}').join('\n');
      final row=<String,dynamic>{'entries':count,'utf8_bytes':utf8.encode(value).length};
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:CatalogSourceDialog(key:ValueKey(count),session:session,pickFile:() async=>null))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('粘贴目录'));
      await tester.pumpAndSettle();
      final watch=Stopwatch()..start();
      await tester.enterText(find.byWidgetPredicate((w)=>w is TextField && w.decoration?.labelText=='粘贴目录文本'),value);
      await tester.pump();
      row['test_host_enter_and_layout_ms']=watch.elapsedMilliseconds;
      expect(tester.takeException(),isNull);
      await tester.runAsync(() async {
        final parse=Stopwatch()..start();
        try {final snapshot=await session.acquire('paste',value);row['parsed_entries']=snapshot.entries.length;}
        catch(e){row['parse_error']=e.toString();}
        row['native_request_roundtrip_ms']=parse.elapsedMilliseconds;
      });
      sizes.add(row);
      await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
    }
    results['large_catalog_measurements']=sizes;
    await tester.runAsync(() async {
      await File('${out.path}/observations.json').writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    });
    library.dispose(); backend.dispose();
  },timeout:const Timeout(Duration(minutes:5)));
}
