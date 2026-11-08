import 'dart:io';

import 'package:easypub_desktop/application/book_check_service.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('B5 R0 图集样书批量导入后检查有真实问题，切书不失效', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['EASYPUB_TEST_DLL']!,
      ),
    );
    final root = (await Directory('../artifacts').createTemp('b5-atlas-'))
        .absolute;
    final state = PrototypeState(settingsDirectory: '${root.path}/settings');
    final library = LegacyLibraryAdapter(backend: state);
    addTearDown(() {
      library.dispose();
      state.dispose();
    });
    await library.load();
    final sample = StringBuffer('山海之间\n作者：样例\n\n');
    for (var c = 1; c <= 40; c++) {
      if (c == 1) sample.writeln('第一卷 远行');
      if (c == 21) sample.writeln('第二卷 归来');
      if (c == 13) continue;
      sample.writeln(c == 30 ? '第三十章 风起' : '第$c章 ${c.isEven ? '风起' : '云涌'}$c');
      for (var p = 0; p < 6; p++) {
        sample.writeln('　　这是第$c章的第${p + 1}段正文，山路很长，海风很轻，行人一步一步走向远方。');
      }
      if (c == 8) sample.writeln('第八章我杀这边的人，他们都看着我');
      sample.writeln();
    }
    final main = File('${root.path}/山海之间.txt')
      ..writeAsStringSync(sample.toString());
    final paths = [main.path];
    for (var i = 0; i < 7; i++) {
      paths.add(
        (File(
          '${root.path}/配书$i.txt',
        )..writeAsStringSync('第一章 开端\n正文。\n\n第二章 继续\n正文。\n')).path,
      );
    }
    expect((await library.importFiles(paths)).every((r) => r.succeeded), true);
    final book = library.books.value.firstWhere((b) => b.title == '山海之间');
    library.selectBook(book.id);
    final checks = library.openChecks(book.id);
    addTearDown(checks.dispose);
    final imported = (checks as CachedBookCheckSession).latest;
    expect(imported, isNotNull);
    expect(
      imported!.domains.singleWhere((d) => d.id == 'chapters').failed,
      false,
    );
    final report = await checks.inspect();
    final chapterCheck = report.domains.singleWhere((d) => d.id == 'chapters');
    expect(chapterCheck.failed, false);
    expect(chapterCheck.count, greaterThan(0));
    final chapters = library.openChapters(book.id);
    final tree = await chapters.read(0);
    final issues = await chapters.issues(tree, 0, effective: true);
    expect(issues.total, chapterCheck.count);
    expect(issues.items, isNotEmpty);
    library.selectBook(library.books.value.last.id);
    expect(checks.isCurrent(report), true);
    library.selectBook(book.id);
    expect(checks.isCurrent(report), true);
  });
}
