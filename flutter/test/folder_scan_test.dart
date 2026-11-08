import 'dart:io';

import 'package:easypub_desktop/prototype/folder_scan.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('easypub-folder-scan-');
    await File('${root.path}/a.txt').writeAsString('第一章 开始\n正文不变');
    await Directory('${root.path}/child').create();
    await File('${root.path}/child/b.epub').writeAsBytes([1, 2, 3]);
    await File('${root.path}/ignore.png').writeAsBytes([4]);
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'favorite relocation validates destination and coalesces existing target',
    () async {
      final state = PrototypeState();
      addTearDown(state.dispose);
      final old = Directory('${root.path}/old');
      await old.create();
      await state.shelf.addFavoriteFolder(old.path);
      await state.shelf.addFavoriteFolder('${root.path}/child');
      expect(await state.shelf.renameFavoriteFolder(old.path, '旧收藏名称'), isTrue);
      expect(
        await state.shelf.renameFavoriteFolder('${root.path}/child', '目标收藏名称'),
        isTrue,
      );
      await old.delete();
      final before = List<String>.from(state.shelf.favoriteFolders);
      expect(
        await state.shelf.relocateFavoriteFolder(old.path, '${root.path}/missing'),
        isFalse,
      );
      expect(state.shelf.favoriteFolders, before);
      expect(
        await state.shelf.relocateFavoriteFolder(old.path, '${root.path}/child'),
        isTrue,
      );
      expect(state.shelf.favoriteFolders.length, 1);
      expect(
        state.shelf.favoriteFolderNames[folderImportPathKey('${root.path}/child')],
        '目标收藏名称',
      );
      expect(
        state.shelf.favoriteFolderNames.containsKey(folderImportPathKey(old.path)),
        isFalse,
      );
      expect(
        folderImportPathKey(state.shelf.favoriteFolders.single),
        folderImportPathKey('${root.path}/child'),
      );
      expect(state.shelf.books.every((book) => book.isDemo), isTrue);
    },
  );

  test(
    'scan is read-only, recursive choice and existing path are explicit',
    () async {
      final source = File('${root.path}/a.txt');
      final before = await source.readAsBytes();
      final flat = await scanBookFolder(
        root.path,
        recursive: false,
        cancelled: () => false,
        importedPaths: {source.path},
      );
      expect(flat.complete, isTrue, reason: flat.message);
      expect(flat.entries.single.alreadyImported, isTrue);
      expect(flat.entries.single.bytes, before.length);
      expect(flat.skipped, 1);
      final nested = await scanBookFolder(
        root.path,
        recursive: true,
        cancelled: () => false,
      );
      expect(nested.entries.map((e) => e.format), ['TXT', 'EPUB']);
      expect(await source.readAsBytes(), before);
    },
  );

  test('cancel and missing folders stay empty; scan limits preserve explicit partial results', () async {
    final cancelled = await scanBookFolder(
      root.path,
      recursive: true,
      cancelled: () => true,
    );
    final missing = await scanBookFolder(
      '${root.path}/missing',
      recursive: true,
      cancelled: () => false,
    );
    for (final result in [cancelled, missing]) {
      expect(result.complete, false);
      expect(result.entries, isEmpty);
    }
    final limited = await scanBookFolder(
      root.path,
      recursive: true,
      cancelled: () => false,
      maxBooks: 1,
    );
    expect(limited.complete, false);
    expect(limited.entries, hasLength(1));
    expect(limited.message, contains('已保留 1 本'));
    final bounded = await scanBookFolder(
      root.path,
      recursive: true,
      cancelled: () => false,
      maxEntries: 1,
    );
    expect(bounded.complete, false);
    expect(bounded.entries.length, lessThanOrEqualTo(1));
  });
}
