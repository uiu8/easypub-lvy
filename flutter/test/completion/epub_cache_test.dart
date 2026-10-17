import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:easypub_desktop/prototype/epub_import_cache.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/prototype/txt_import.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> fixture(File target, String body) async {
  final result = await Process.run(
    Platform.environment['EASYPUB_TEST_PYTHON']!,
    [
      '-X',
      'utf8',
      '-c',
      r'''
import sys,zipfile
target,body=sys.argv[1:]
with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_STORED) as z:
 def put(name,data):
  z.writestr(zipfile.ZipInfo(name,(2020,1,1,0,0,0)),data.encode())
 put('mimetype','application/epub+zip')
 put('META-INF/container.xml','<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>')
 put('book.opf','<package><metadata><title>缓存测试</title></metadata><manifest><item id="c" href="text.xhtml" media-type="application/xhtml+xml"/><item id="s" href="style.css" media-type="text/css"/></manifest><spine><itemref idref="c"/></spine></package>')
 put('text.xhtml','<html><body><h1>第一章 测试</h1><p>'+body+'</p></body></html>')
 put('style.css','p { color: black; }')
''',
      target.path,
      body,
    ],
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
}

void main() {
  setUpAll(
    () async => RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    ),
  );
  test(
    'same stat changed EPUB imports fresh body and preserves old working copy',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'epub-content-regression-',
      );
      final source = File('${root.path}/source.epub');
      await fixture(source, '原来正文');
      final before = await readBook(source.path, () => false);
      final oldText = await File(before.path).readAsString();
      final stat = await source.stat();
      final oldHash = sha256.convert(await source.readAsBytes());
      await fixture(source, '全新内容');
      await source.setLastModified(stat.modified);
      expect(await source.length(), stat.size);
      expect((await source.stat()).modified, stat.modified);
      expect(sha256.convert(await source.readAsBytes()), isNot(oldHash));
      final after = await readBook(source.path, () => false);
      expect(await File(after.path).readAsString(), contains('全新内容'));
      expect(after.sourceId, isNot(before.sourceId));
      expect(await File(before.path).readAsString(), oldText);
      expect(after.resourceReport!['source_path'], source.path);
    },
  );

  test('tampered text, resource and manifest regenerate without overwriting old cache', () async {
    final root = await Directory.systemTemp.createTemp(
      'epub-damaged-regression-',
    );
    final source = File('${root.path}/source.epub');
    await fixture(source, '原来正文');
    final initial = await readBook(source.path, () => false);
    final same = await readBook(source.path, () => false);
    expect(same.path, initial.path);
    final text = File(initial.path);
    await text.writeAsString('损坏正文');
    final repaired = await readBook(source.path, () => false);
    expect(await File(repaired.path).readAsString(), contains('原来正文'));
    expect(await text.readAsString(), '损坏正文');
    final css = File(
      (repaired.resourceReport!['css'] as List).single['path'] as String,
    );
    await css.writeAsString('damaged resource');
    final resources = await readBook(source.path, () => false);
    expect(
      await File(
        (resources.resourceReport!['css'] as List).single['path'] as String,
      ).readAsString(),
      'p { color: black; }',
    );
    expect(await css.readAsString(), 'damaged resource');
    final manifest = File(
      '${resources.resourceReport!['resource_root']}/manifest.json',
    );
    await manifest.writeAsString(jsonEncode({'schema': 3}));
    final finalImport = await readBook(source.path, () => false);
    expect(finalImport.resourceReport!['source_path'], source.path);
    expect(finalImport.path, isNot(resources.path));
  });
  test('interruption, cancellation and source replacement never publish partial generations', () async {
    final root = await Directory.systemTemp.createTemp(
      'epub-transaction-regression-',
    );
    final source = File('${root.path}/source.epub');
    final cacheRoot = Directory('${root.path}/cache');
    await fixture(source, '原来正文');
    var fail = true;
    var cancel = false;
    final cache = EpubImportCache(
      root: cacheRoot,
      extractResources: ({required sourcePath, required resourceDir}) async {
        if (fail) {
          throw const FormatException('synthetic interrupted extraction');
        }
        return api.importEpubResources(
          sourcePath: sourcePath,
          resourceDir: resourceDir,
        );
      },
    );
    Future<List<FileSystemEntity>> receipts() async => cacheRoot
        .list(recursive: true)
        .where((e) => e.path.endsWith('current.json'))
        .toList();
    await expectLater(cache.read(source, () => false), throwsFormatException);
    expect(await receipts(), isEmpty);
    fail = false;
    final cancelled = EpubImportCache(
      root: cacheRoot,
      extractText: ({required sourcePath, required outputPath}) async {
        final result = await api.importEpubText(
          sourcePath: sourcePath,
          outputPath: outputPath,
        );
        cancel = true;
        return result;
      },
    );
    await expectLater(
      cancelled.read(source, () => cancel),
      throwsFormatException,
    );
    expect(await receipts(), isEmpty);
    final changed = EpubImportCache(
      root: cacheRoot,
      extractText: ({required sourcePath, required outputPath}) async {
        final result = await api.importEpubText(
          sourcePath: sourcePath,
          outputPath: outputPath,
        );
        await fixture(source, '全新内容');
        return result;
      },
    );
    await expectLater(changed.read(source, () => false), throwsFormatException);
    expect(await receipts(), isEmpty);
    final recovered = await cache.read(source, () => false);
    expect(await File(recovered.textPath).readAsString(), contains('全新内容'));
    expect(await receipts(), hasLength(1));
    expect(
      await cacheRoot
          .list(recursive: true)
          .where((e) => e.path.endsWith('source.epub'))
          .toList(),
      isEmpty,
    );
    await expectLater(cache.read(source, () => true), throwsFormatException);
    expect(await receipts(), hasLength(1));
  });

  test('same names in different folders and concurrent readers have consistent bundles', () async {
    final root = await Directory.systemTemp.createTemp(
      'epub-identity-regression-',
    );
    final sourceA = File('${root.path}/a/book.epub');
    final sourceB = File('${root.path}/b/book.epub');
    await sourceA.parent.create();
    await sourceB.parent.create();
    await fixture(sourceA, '原来正文');
    await fixture(sourceB, '全新内容');
    final cache = EpubImportCache(root: Directory('${root.path}/cache'));
    final bundles = await Future.wait([
      cache.read(sourceA, () => false),
      cache.read(sourceA, () => false),
      cache.read(sourceB, () => false),
    ]);
    for (final bundle in bundles.take(2)) {
      expect(await File(bundle.textPath).readAsString(), contains('原来正文'));
      expect(bundle.resources['source_path'], sourceA.path);
    }
    expect(await File(bundles.last.textPath).readAsString(), contains('全新内容'));
    expect(bundles.last.resources['source_path'], sourceB.path);
    final cached = await cache.read(sourceA, () => false);
    expect(bundles.take(2).map((e) => e.textPath), contains(cached.textPath));
  });
  test('Windows competing receipt publication reuses verified winner and persistent denial still fails', () async {
    final root = await Directory.systemTemp.createTemp(
      'epub-publish-regression-',
    );
    final source = File('${root.path}/book.epub');
    await fixture(source, '并发正文');
    final both = Completer<void>(), published = Completer<void>();
    var calls = 0;
    final cache = EpubImportCache(
      root: Directory('${root.path}/cache'),
      publishReceipt: (pending, destination) async {
        if (++calls == 1) {
          await both.future;
          await pending.rename(destination);
          published.complete();
        } else {
          both.complete();
          await published.future;
          throw FileSystemException(
            'simulated Windows sharing conflict',
            destination,
            const OSError('denied', 5),
          );
        }
      },
    );
    final results = await Future.wait([
      cache.read(source, () => false),
      cache.read(source, () => false),
    ]);
    expect(results[0].textPath, results[1].textPath);
    expect(await File(results[0].textPath).readAsString(), contains('并发正文'));
    expect(calls, 2);
    var denied = 0;
    final lockedRoot = Directory('${root.path}/locked');
    final locked = EpubImportCache(
      root: lockedRoot,
      publishReceipt: (_, destination) async {
        denied++;
        throw FileSystemException(
          'simulated persistent denial',
          destination,
          const OSError('denied', 5),
        );
      },
    );
    await expectLater(
      locked.read(source, () => false),
      throwsA(isA<FileSystemException>()),
    );
    expect(denied, 6);
    expect(
      await lockedRoot
          .list(recursive: true)
          .where((f) => f.path.endsWith('current.json'))
          .toList(),
      isEmpty,
    );
  }, skip: !Platform.isWindows);
  test('rename-unavailable cache reuses verified immutable receipts and repairs corruption', () async {
    final root = await Directory.systemTemp.createTemp(
      'epub-immutable-regression-',
    );
    final source = File('${root.path}/book.epub');
    await fixture(source, '完成正文');
    var publishes = 0;
    final cacheRoot = Directory('${root.path}/cache');
    final cache = EpubImportCache(
      root: cacheRoot,
      publishReceipt: (_, destination) async {
        publishes++;
        throw FileSystemException(
          'synthetic rename unavailable',
          destination,
          const OSError('not same device', 17),
        );
      },
    );
    Future<List<File>> receipts() async => cacheRoot
        .list(recursive: true)
        .where((e) => e is File && e.path.contains('ready-g-'))
        .cast<File>()
        .toList();
    final first = await cache.read(source, () => false);
    expect(await File(first.textPath).readAsString(), contains('完成正文'));
    expect((await cache.read(source, () => false)).textPath, first.textPath);
    expect(publishes, 1);
    expect(await receipts(), hasLength(1));
    expect(
      await File('${File(first.textPath).parent.parent.path}/current.json')
          .exists(),
      isFalse,
    );
    // An interrupted receipt is ignored even though its generation is complete.
    final incomplete = (await receipts()).single;
    await incomplete.writeAsString('{"version":4,');
    final second = await cache.read(source, () => false);
    expect(second.textPath, isNot(first.textPath));
    expect(await incomplete.readAsString(), '{"version":4,');
    expect(await File(first.textPath).readAsString(), contains('完成正文'));
    expect((await cache.read(source, () => false)).textPath, second.textPath);
    expect(publishes, 2);
    final css = File(
      (second.resources['css'] as List).single['path'] as String,
    );
    await css.writeAsString('damaged');
    final third = await cache.read(source, () => false);
    expect(third.textPath, isNot(second.textPath));
    expect(await css.readAsString(), 'damaged');
    expect(
      await File((third.resources['css'] as List).single['path'] as String)
          .readAsString(),
      'p { color: black; }',
    );
    expect((await cache.read(source, () => false)).textPath, third.textPath);
    expect(publishes, 3);
  }, skip: !Platform.isWindows);

  test('immutable fallback rejects cancellation, changed source and failed receipt writes', () async {
    final root = await Directory.systemTemp.createTemp(
      'epub-immutable-failure-',
    );
    final source = File('${root.path}/book.epub');
    await fixture(source, '原来正文');
    for (final mode in ['cancel', 'change', 'write_failure']) {
      var cancelled = false;
      final cacheRoot = Directory('${root.path}/$mode');
      final cache = EpubImportCache(
        root: cacheRoot,
        publishReceipt: (pending, destination) async {
          if (mode == 'cancel') cancelled = true;
          if (mode == 'change') await fixture(source, '全新内容');
          if (mode == 'write_failure') {
            final generation = pending.parent.path
                .split(Platform.pathSeparator)
                .last;
            await Directory(
              '${File(destination).parent.path}/ready-$generation.json',
            ).create();
          }
          throw FileSystemException(
            'synthetic rename unavailable',
            destination,
            const OSError('not same device', 17),
          );
        },
      );
      await expectLater(
        cache.read(source, () => cancelled),
        mode == 'write_failure'
            ? throwsA(isA<FileSystemException>())
            : throwsFormatException,
      );
      expect(
        await cacheRoot
            .list(recursive: true)
            .where(
              (e) =>
                  e is File &&
                  (e.path.contains('ready-g-') ||
                      e.path.endsWith('current.json')),
            )
            .toList(),
        isEmpty,
      );
    }
  }, skip: !Platform.isWindows);

  test('concurrent immutable publications preserve both generations and allow later reuse', () async {
    final root = await Directory.systemTemp.createTemp(
      'epub-immutable-concurrent-',
    );
    final source = File('${root.path}/book.epub');
    await fixture(source, '并发完成正文');
    final both = Completer<void>();
    var calls = 0;
    final cache = EpubImportCache(
      root: Directory('${root.path}/cache'),
      publishReceipt: (_, destination) async {
        if (++calls == 2) both.complete();
        await both.future;
        throw FileSystemException(
          'synthetic rename unavailable',
          destination,
          const OSError('not same device', 17),
        );
      },
    );
    final results = await Future.wait([
      cache.read(source, () => false),
      cache.read(source, () => false),
    ]);
    expect(results.map((e) => e.textPath).toSet(), hasLength(2));
    for (final bundle in results) {
      expect(await File(bundle.textPath).readAsString(), contains('并发完成正文'));
    }
    final reused = await cache.read(source, () => false);
    expect(results.map((e) => e.textPath), contains(reused.textPath));
    expect(calls, 2);
  }, skip: !Platform.isWindows);
}
