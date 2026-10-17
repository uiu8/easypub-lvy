import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/application/chapter_service.dart';
import 'package:easypub_desktop/desk/catalog/catalog_page.dart';
import 'package:easypub_desktop/desk/catalog/composition_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';
import 'package:easypub_desktop/desk/dialogs.dart';

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  testWidgets(
    'reorder UI preserves manual edit, undo, reopen and actual EPUB image placement',
    (t) async {
      t.view.physicalSize = const Size(1600, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var stage = 0;
      var operation = 'setup';
      Future<void> runChecked(Future<void> Function() action) async {
        stage++;
        final error = await t.runAsync(() async {
          try {
            await action();
            return null;
          } on api.ApiError catch (e) {
            return await api.describeApiError(error: e);
          } catch (e, stack) {
            return '$e\n$stack';
          }
        });
        expect(
          error,
          isNull,
          reason: 'async stage $stage operation $operation',
        );
      }

      late PrototypeState state;
      late LegacyLibraryAdapter library;
      late String id, path;
      const original = '第二章 乙\n乙文  \n第一章 甲\n甲文  \n第三章 丙\n丙文  \n';
      await runChecked(() async {
        path = (await Directory('../artifacts').createTemp('catalog-reorder-'))
            .absolute
            .path;
        state = PrototypeState(settingsDirectory: '$path/settings');
        library = LegacyLibraryAdapter(backend: state);
        await library.load();
        await library.savePatch({'check_after_import': false});
        await File('$path/book.txt').writeAsString(original);
        expect(
          (await library.importFiles(['$path/book.txt'])).single.succeeded,
          true,
        );
        id = state.currentId;
        await File('$path/figure.png').writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgZGIGAAAOAAfXb+R4AAAAAElFTkSuQmCC',
          ),
        );
        final production = await state.production.previewChanges({
          id: {
            'op': 'patch',
            'fields': {
              'illustrations': {
                'op': 'set',
                'value': [
                  {
                    'path': '$path/figure.png',
                    'source_line': 2,
                    'caption': '乙章插图',
                    'alt': '乙图',
                  },
                ],
              },
            },
          },
        });
        expect(await state.production.confirm(production), true);
        final cleanup = library.openCleanup(id);
        await cleanup.apply(
          await cleanup.preview(
            jsonEncode({
              'kind': 'cleanup',
              'pipeline': [
                {'kind': 'trim_trailing_spaces'},
              ],
            }),
          ),
        );
        cleanup.dispose();
        final chapters = library.openChapters(id);
        final tree = await chapters.read(0);
        await chapters.confirm(
          await chapters.preview(
            tree,
            RenameChapter(tree.nodes.first.id, '手工标题乙'),
          ),
        );
        final session = library.openCatalog(id);
        final snapshot = await session.acquire(
          'paste',
          '第一卷 起\n第一章 甲\n第二章 乙\n第二卷 终\n第三章 丙',
          declaredTotal: 3,
        );
        session.accept(snapshot);
        final plain = await session.preview(snapshot, identityConfirmed: true);
        expect(plain.reorder, false);
        final order = await session.preview(
          snapshot,
          identityConfirmed: true,
          reorder: true,
        );
        expect(order.relocatedChapters, 3);
        expect(order.proposedEdits, greaterThan(0));
        final stale = await session.prepareRepair(order);
        await session.preview(snapshot, identityConfirmed: true);
        await expectLater(
          stale.session.confirm(stale.preview),
          throwsA(isA<ChapterStateChanged>()),
        );
      });
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 300; i++) {
          await t.pump(const Duration(milliseconds: 20));
          if (ready()) return;
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
        fail(
          'catalog UI did not settle: ${t.widgetList<DeskNote>(find.byType(DeskNote)).map((n) => n.text).join(' / ')}',
        );
      }

      Future<void> idle() =>
          until(() => find.byType(LinearProgressIndicator).evaluate().isEmpty);
      await t.pumpWidget(
        MaterialApp(
          theme: deskTheme(),
          home: Scaffold(
            body: CatalogPage(
              library: library,
              bookId: id,
              onReturn: () {},
              pickFile: () async => null,
            ),
          ),
        ),
      );
      await t.tap(find.text('已核对书名、作者、来源和目录范围'));
      await t.pump();
      await t.tap(find.text('按参考目录整章归位'));
      await t.pump();
      await t.tap(find.text('核对当前书稿与目录'));
      await until(() => find.textContaining('整章归位：3 章').evaluate().isNotEmpty);
      await t.pumpAndSettle();
      expect(find.textContaining('整章归位：3 章'), findsOneWidget);
      await t.tap(find.text('目录一键修复预览'));
      await until(
        () => find.byType(CatalogCompositionDialog).evaluate().isNotEmpty,
      );
      await idle();
      await t.pumpAndSettle();
      await runChecked(() async {
        expect(
          (await library.openChapters(id).read(0)).nodes.first.title,
          '手工标题乙',
        );
      });
      await t.tap(find.text('已核对所选修改和预览'));
      await t.pump();
      await t.tap(find.text('确认应用目录修复'));
      await until(
        () => find.byType(CatalogCompositionDialog).evaluate().isEmpty,
      );
      await idle();
      await runChecked(() async {
        expect(
          (await library.openChapters(id).read(0)).nodes.map((n) => n.title),
          ['第一卷 起', '第一章 甲', '手工标题乙', '第二卷 终', '第三章 丙'],
        );
      });
      await t.tap(find.text('撤销本次目录修复'));
      await until(() => find.text('撤销本次目录修复').evaluate().isEmpty);
      await runChecked(() async {
        var chapters = library.openChapters(id);
        var tree = await chapters.read(0);
        expect(tree.nodes.map((n) => n.title), ['手工标题乙', '第一章 甲', '第三章 丙']);
        operation = 'redo';
        await chapters.history(tree, undo: false);
        operation = 'save';
        expect(
          (await library.saveProject('$path/saved.easypub.json')).succeeded,
          true,
        );
        operation = 'reopen';
        expect(
          (await library.openProject('$path/saved.easypub.json')).succeeded,
          true,
        );
        chapters = library.openChapters(id);
        tree = await chapters.read(0);
        expect(tree.nodes.map((n) => n.title), [
          '第一卷 起',
          '第一章 甲',
          '手工标题乙',
          '第二卷 终',
          '第三章 丙',
        ]);
        for (final pair in [
          ('第一章 甲', '甲文'),
          ('手工标题乙', '乙文'),
          ('第三章 丙', '丙文'),
        ]) {
          expect(
            (await chapters.body(
              tree,
              tree.nodes.singleWhere((n) => n.title == pair.$1).id,
              0,
            )).lines.join('\n'),
            contains(pair.$2),
          );
        }
        operation = 'publication';
        final information = library.openBookInformation(id);
        await information.apply(await information.preview({'language': 'zh'}));
        information.dispose();
        final publication = state.publicationRequest(id);
        final request = {
          'op': 'preview',
          'publication': publication,
          'source_path': '$path/book.txt',
          'output_path': '$path/ordered.epub',
          'confirmed': false,
        };
        operation = 'export preview';
        final preview = jsonDecode(
          await api.epubExportText(requestJson: jsonEncode(request)),
        ) as Map;
        expect(preview['plan_id'], isA<String>(), reason: preview.toString());
        final receipt = jsonDecode(
          await api.epubExportText(
            requestJson: jsonEncode({
              ...request,
              'op': 'commit',
              'confirmed': true,
              'plan_id': preview['plan_id'],
            }),
          ),
        ) as Map;
        expect(receipt['committed'], true, reason: receipt.toString());
        final verify = await Process.run(
          Platform.environment['EASYPUB_TEST_PYTHON']!,
          [
            '-X',
            'utf8',
            '-c',
            r"""
import sys,zipfile,posixpath,xml.etree.ElementTree as E
with zipfile.ZipFile(sys.argv[1]) as z:
 ns={'o':'http://www.idpf.org/2007/opf','c':'urn:oasis:names:tc:opendocument:xmlns:container','h':'http://www.w3.org/1999/xhtml'}
 opf=E.fromstring(z.read('META-INF/container.xml')).find('.//c:rootfile',ns).attrib['full-path'];base=posixpath.dirname(opf)
 root=E.fromstring(z.read(opf));items={e.attrib['id']:e.attrib['href'] for e in root.findall('.//o:manifest/o:item',ns)}
 chapters=[];images=[]
 for ref in root.findall('.//o:spine/o:itemref',ns):
  name=posixpath.normpath(posixpath.join(base,items[ref.attrib['idref']]))
  doc=E.fromstring(z.read(name));text=''.join(doc.itertext());chapters.append(text)
  for img in doc.findall('.//h:img',ns):
   assert '乙文' in text and '手工标题乙' in text
   name=posixpath.normpath(posixpath.join(posixpath.dirname(name),img.attrib['src']))
   assert z.read(name)==open(sys.argv[2],'rb').read();images.append(name)
 joined='\n'.join(chapters)
 assert joined.index('甲文')<joined.index('乙文')<joined.index('丙文')
 assert all(body+'  ' not in joined for body in ['甲文','乙文','丙文'])
 assert len(images)==1
 print('SPINE_BODY_ORDER_AND_IMAGE_BYTES_VERIFIED')
""",
            '$path/ordered.epub',
            '$path/figure.png',
          ],
        );
        expect(
          verify.exitCode,
          0,
          reason: verify.stdout.toString() + verify.stderr.toString(),
        );
        expect(await File('$path/book.txt').readAsString(), original);
      });
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
