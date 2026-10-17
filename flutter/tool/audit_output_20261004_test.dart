import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/folder_scan.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/infrastructure/legacy_conversion_session.dart';
import 'package:easypub_desktop/application/conversion_service.dart';

void main() {
  testWidgets('audit output reimport and cancellation boundaries', (tester) async {
    await tester.runAsync(() async {
      final dll = Platform.environment['EASYPUB_TEST_DLL']!;
      await RustLib.init(externalLibrary: ExternalLibrary.open(dll));
      final base = Directory('../artifacts/audit-20261004-output');
      await base.create(recursive: true);
      final root = await base.createTemp('run-');
      final state = PrototypeState(settingsDirectory: '${root.absolute.path}/settings');
      final library = LegacyLibraryAdapter(backend: state);
      final evidence = <String, dynamic>{'dll': dll, 'root': root.absolute.path, 'tests': <dynamic>[]};
      final observations = evidence['tests'] as List;
      Future<Map<String, dynamic>> export(Map<String, dynamic> request) async => (jsonDecode(await api.epubExportText(requestJson: jsonEncode(request))) as Map).cast<String, dynamic>();
      try {
        await library.load();
        expect(await library.savePatch({'check_after_import': false}), true);
        final source = File('${root.absolute.path}/审计原书.txt');
        const original = '第一章 开始\n合成正文，用于功能审计。\n第二章 结尾\n这是正文结尾。\n';
        await source.writeAsString(original);
        expect((await library.importFiles([source.path])).single.succeeded, true);
        final id = library.books.value.single.id;
        final info = library.openBookInformation(id);
        await info.apply(await info.preview({'description': 'EPUB 原始简介', 'publisher': 'EPUB 原出版社', 'language': 'zh-CN'}));
        info.dispose();
        final initial = LegacyConversionSession(state);
        final request = ConversionRequest(books: [id], directory: '${root.absolute.path}/initial', format: 'EPUB', runChecks: false);
        final plan = await initial.preview(request);
        expect(plan.previewed, true);
        final out = (await initial.commit(plan, acknowledgeWarnings: true)).single;
        expect(out.complete, true);
        final cacheFixture=File('${root.absolute.path}/cache-fixture.epub');
        const repackScript = '''
import sys,zipfile,hashlib,json,os
source,target,mode=sys.argv[1:]
with zipfile.ZipFile(source) as archive:
    entries=[(info,archive.read(info)) for info in archive.infolist()]
changed=0
with zipfile.ZipFile(target+'.stage','w') as archive:
    for info,data in entries:
        if mode=='edit':
            before=data
            data=data.replace('合成正文'.encode(),'全新内容'.encode())
            changed+=before!=data
        archive.writestr(info,data,compress_type=zipfile.ZIP_STORED)
os.replace(target+'.stage',target)
print(json.dumps({'changed_entries':changed,'sha256':hashlib.sha256(open(target,'rb').read()).hexdigest()}))
''';
        final python=Platform.environment['EASYPUB_TEST_PYTHON']!;
        final makeCache=await Process.run(python,['-X','utf8','-c',repackScript,out.path,cacheFixture.path,'copy']);
        expect(makeCache.exitCode,0,reason:'${makeCache.stderr}');
        expect((await library.importFiles([cacheFixture.path])).single.succeeded,true);
        final cacheBook=state.currentId;
        final beforeCacheSource=state.current.source!.sourceId;
        final cacheStat=await cacheFixture.stat();
        final editCache=await Process.run(python,['-X','utf8','-c',repackScript,cacheFixture.path,cacheFixture.path,'edit']);
        expect(editCache.exitCode,0,reason:'${editCache.stderr}');
        await cacheFixture.setLastModified(cacheStat.modified);
        expect(await cacheFixture.length(),cacheStat.size);
        expect((await library.importFiles([cacheFixture.path])).single.succeeded,true);
        expect(state.currentId,cacheBook);
        final cachedBody=await File(state.current.source!.path).readAsString();
        final staleCache=beforeCacheSource==state.current.source!.sourceId && cachedBody.contains('合成正文') && !cachedBody.contains('全新内容');
        observations.add({'id':'epub_cache_same_stat','before_archive':jsonDecode(makeCache.stdout as String),'after_archive':jsonDecode(editCache.stdout as String),'same_size':await cacheFixture.length()==cacheStat.size,'same_mtime':(await cacheFixture.stat()).modified==cacheStat.modified,'stale_body_reused':staleCache,'cached_working_path':state.current.source!.path});
        expect(staleCache,true,reason:'Audit confirms EPUB cache ignores changed content with stable file size and timestamp');
        expect((await library.importFiles([out.path])).single.succeeded, true);
        final epubId = state.currentId;
        final edit = library.openBookInformation(epubId);
        await edit.apply(await edit.preview({'description': '用户手工简介', 'publisher': '用户手工出版社', 'language': 'en'}));
        edit.dispose();
        final before = Map<String, dynamic>.from(state.production.settings(epubId));
        expect((await library.importFiles([out.path])).single.succeeded, true);
        final after = state.production.settings(epubId);
        observations.add({'id': 'reimport_epub_metadata', 'before': {for(final key in ['description', 'publisher', 'language']) key: before[key]}, 'after': {for(final key in ['description', 'publisher', 'language']) key: after[key]}, 'manual_values_preserved': before['description']==after['description'] && before['publisher']==after['publisher'] && before['language']==after['language']});
        expect(after['description'], 'EPUB 原始简介', reason: 'Audit confirms reimport overwrites manual metadata');
        initial.dispose();

        final reached = Completer<void>();
        final release = Completer<void>();
        final cancelling = LegacyConversionSession(state, epubCall: (request) async {
          if (request['op'] == 'commit') {
            reached.complete();
            await release.future;
          }
          return export(request);
        });
        final cancelPlan = await cancelling.preview(ConversionRequest(books: [id], directory: '${root.absolute.path}/cancel', format: 'EPUB', runChecks: false));
        final pending = cancelling.commit(cancelPlan, acknowledgeWarnings: true);
        await reached.future;
        final clock = Stopwatch()..start();
        await cancelling.cancel();
        final cancelReturnMs = clock.elapsedMilliseconds;
        final busyWhenCancelReturned = cancelling.busy;
        release.complete();
        final cancelledResult = (await pending).single;
        observations.add({'id':'epub_cancel_boundary','controlled_delay':'ExportCall commit entry held before native invocation','cancel_return_ms':cancelReturnMs,'busy_when_cancel_returned':busyWhenCancelReturned,'final_phase':cancelledResult.phase,'final_file_exists':await File(cancelledResult.path).exists(),'path':cancelledResult.path});
        expect(cancelledResult.complete, true, reason: 'Audit confirms cancel cannot prevent in-flight EPUB call from publishing');
        cancelling.dispose();

        final raced = LegacyConversionSession(state);
        final racePlan = await raced.preview(ConversionRequest(books: [id, epubId], directory: '${root.absolute.path}/partial', format: 'EPUB', runChecks: false));
        final occupied = File(racePlan.outputs.first.path);
        await occupied.writeAsString('keep-existing');
        final mixed = await raced.commit(racePlan, acknowledgeWarnings: true);
        observations.add({'id':'partial_failure_isolation','results':[for(final row in mixed) {'phase':row.phase,'detail':row.detail,'path':row.path}], 'existing_preserved':await occupied.readAsString() == 'keep-existing'});
        expect(mixed.first.failed, true);
        expect(mixed.last.complete, true);
        expect(await occupied.readAsString(), 'keep-existing');
        raced.dispose();
        final folder = Directory('${root.absolute.path}/many-books');
        await folder.create();
        for (var index = 0; index < 129; index++) {
          await File('${folder.path}/book-$index.txt').writeAsString('第一章 开始\n合成正文。\n');
        }
        final listing = await scanBookFolder(folder.path, recursive: false, cancelled: () => false);
        observations.add({'id':'folder_129', 'input_files':129, 'complete':listing.complete, 'visible_entries':listing.entries.length, 'message':listing.message});
        expect(listing.complete, false);
        expect(listing.entries, isEmpty, reason:'Audit confirms 129 books hides the entire otherwise readable scan');

        final engine = Platform.environment['EASYPUB_TEST_KINDLING']!;
        evidence['kindling'] = engine;
        final mobi = LegacyConversionSession(state);
        final mobiPlan = await mobi.preview(ConversionRequest(books:[id],directory:'${root.absolute.path}/mobi-complete',format:'MOBI',engine:engine,generateCover:true,runChecks:false));
        expect(mobiPlan.previewed,true,reason:mobiPlan.findings.map((v)=>v.detail).join('\n'));
        final metadataOutput = (await mobi.commit(mobiPlan,acknowledgeWarnings:true)).single;
        observations.add({'id':'real_mobi_extended_metadata','expected':{'description':state.production.settings(id)['description'],'publisher':state.production.settings(id)['publisher']},'phase':metadataOutput.phase,'detail':metadataOutput.detail,'file_exists':await File(metadataOutput.path).exists()});
        expect(metadataOutput.failed,true,reason:'Audit confirms bundled engine loses nonempty publisher/description');
        expect(metadataOutput.detail,contains('转换结果丢失或改变了书目信息'));
        final simpleInfo=library.openBookInformation(id);
        await simpleInfo.apply(await simpleInfo.preview({'description':'','publisher':''}));
        simpleInfo.dispose();
        final simplePlan=await mobi.preview(ConversionRequest(books:[id],directory:'${root.absolute.path}/mobi-complete',format:'MOBI',engine:engine,generateCover:true,runChecks:false));
        expect(simplePlan.previewed,true);
        final mobiOutput=(await mobi.commit(simplePlan,acknowledgeWarnings:true)).single;
        expect(mobiOutput.complete,true,reason:mobiOutput.detail);
        final mobiBytes = await File(mobiOutput.path).readAsBytes();
        observations.add({'id':'real_mobi_output','phase':mobiOutput.phase,'path':mobiOutput.path,'bytes':mobiBytes.length,'signature':ascii.decode(mobiBytes.sublist(60,68)),'directories_in_output':await Directory('${root.absolute.path}/mobi-complete').list().where((e)=>e is Directory).map((e)=>e.path).toList()});
        expect(mobiOutput.complete,true);
        expect(ascii.decode(mobiBytes.sublist(60,68)),'BOOKMOBI');
        mobi.dispose();

        final longSource = File('${root.absolute.path}/大书取消.txt');
        final body = StringBuffer();
        for(var chapter=1;chapter<=800;chapter++) {
          body.writeln('第$chapter章 测试标题');
          for(var line=0;line<100;line++) { body.writeln('这是合成审计正文，不包含用户数据。章节序号$chapter，正文行$line。'); }
        }
        await longSource.writeAsString(body.toString());
        expect((await library.importFiles([longSource.path])).single.succeeded,true);
        final longId=state.currentId;
        final stopping=LegacyConversionSession(state);
        final stopPlan=await stopping.preview(ConversionRequest(books:[longId],directory:'${root.absolute.path}/mobi-cancel',format:'MOBI',engine:engine,generateCover:true,runChecks:false));
        expect(stopPlan.previewed,true,reason:stopPlan.findings.map((v)=>v.detail).join('\n'));
        final working=stopping.commit(stopPlan,acknowledgeWarnings:true);
        final wait=Stopwatch()..start();
        while(stopping.batch?.active?.job?.phase!='converting' && stopping.busy && wait.elapsedMilliseconds<60000) {
          await Future<void>.delayed(const Duration(milliseconds:10));
        }
        final active=stopping.batch?.active;
        final beforePhase=active?.job?.phase;
        final beforeCancellable=active?.job?.cancellable;
        final nativeJobId=active?.job?.id;
        final cancelClock=Stopwatch()..start();
        await stopping.cancel();
        final accepted=active?.job?.cancelRequested;
        final stoppedResults=await working;
        final stopOutput=stoppedResults.single;
        observations.add({'id':'real_kindling_cancel','source_bytes':await longSource.length(),'phase_when_requested':beforePhase,'cancellable_when_requested':beforeCancellable,'native_job_id':nativeJobId,'cancel_accepted':accepted,'settled_after_ms':cancelClock.elapsedMilliseconds,'final_phase':stopOutput.phase,'batch_item_failed_flag':stopping.batch!.items.single.failed,'final_file_exists':await File(stopOutput.path).exists(),'output_entries':await Directory('${root.absolute.path}/mobi-cancel').list().map((e)=>e.path).toList()});
        expect(accepted,true);
        expect(stopOutput.phase,'cancelled');
        expect(await File(stopOutput.path).exists(),false);
        stopping.dispose();
        expect(await source.readAsString(), original);
        evidence['source_unchanged'] = true;
        evidence['completed'] = true;
      } catch (error, stack) {
        evidence['error'] = '$error';
        evidence['stack'] = '$stack';
        rethrow;
      } finally {
        await File('../artifacts/audit-20261004-output.json').writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
        library.dispose();
        state.dispose();
      }
    });
  });
}
