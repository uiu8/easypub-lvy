import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/txt_import.dart';

void main() {
  test(
    'new owned library starts empty instead of exposing synthetic books',
    () {
      final library = LegacyLibraryAdapter();
      expect(library.books.value, isEmpty);
      library.dispose();
    },
  );
  test(
    'failed reimport is not reported as success because a row already exists',
    () async {
      var fail = false;
      final backend = PrototypeState(
        importer: (path, cancelled) async {
          if (fail) throw const FormatException('source no longer readable');
          return ImportedTxt(
            path: path,
            sourceId: 'source',
            revision: 1,
            encoding: 'UTF-8',
            lines: 3,
            headings: 1,
          );
        },
      );
      final library = LegacyLibraryAdapter(backend: backend);
      addTearDown(() {
        library.dispose();
        backend.dispose();
      });
      expect(library.books.value, isEmpty);
      var notifications = 0;
      library.books.addListener(() => notifications++);
      final first = await library.importFiles([r'D:\test\book.txt']);
      expect(first.single.succeeded, isTrue);
      expect(library.books.value.length, 1);
      final count = notifications;
      fail = true;
      final second = await library.importFiles([r'D:\test\book.txt']);
      expect(second.single.succeeded, isFalse);
      expect(library.books.value.length, 1);
      expect(
        notifications,
        count,
        reason: 'progress/failure must not rebuild unchanged book list',
      );
      expect(library.importing.value, isFalse);
    },
  );
}
