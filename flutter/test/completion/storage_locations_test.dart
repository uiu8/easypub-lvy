import 'desk_v86_plugins_test.dart' as plugin_fixture;

import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';
import 'package:easypub_desktop/prototype/prototype_state.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/application/storage_locations.dart';
import 'package:easypub_desktop/application/plugin_host.dart';

void main() {
  test(
    'isolated storage keeps defaults, copies images and controls cache roots',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(
          Platform.environment['EASYPUB_TEST_DLL']!,
        ),
      );
      final root = await Directory.systemTemp.createTemp('easypub-v104-dart-');
      // native 持有的缓存租约到进程退出释放；本用例不触碰真实应用目录。
      await StorageLocations.initialize(
        local: '${root.path}/local',
        temp: '${root.path}/temp',
      );
      expect(
        StorageLocations.directory('settings'),
        contains('EasyPub-RustFlutter'),
      );
      final registry = PluginRegistry(roots: []);
      expect(registry.dataRoot, StorageLocations.directory('plugin_data'));
      await registry.stopForStorage();
      await expectLater(
        registry.client('missing'),
        throwsA(isA<PluginError>()),
      );
      registry.storageSuspended = false;
      plugin_fixture.makePlugin(Directory(registry.userRoot));
      await registry.setEnabled('booksource', true);
      final clients = await Future.wait([
        registry.client('booksource'),
        registry.client('booksource'),
      ]);
      expect(identical(clients[0], clients[1]), true);
      await registry.stopForStorage();
      expect(clients.first.closed, true);
      registry.storageSuspended = false;
      final opening = registry
          .client('booksource')
          .then<Object>((c) => c, onError: (Object e) => e);
      await registry.stopForStorage();
      expect(await opening, isA<PluginError>());

      final png = File('${root.path}/cover.png');
      await png.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC',
        ),
      );
      final stored = await StorageLocations.copyImage(png.path);
      expect(stored, isNot(png.path));
      expect(await StorageLocations.copyImage(png.path), stored);
      expect(await File(stored).readAsBytes(), await png.readAsBytes());
      await StorageLocations.configure({
        'op': 'image.set',
        'mode': 'reference',
      });
      expect(await StorageLocations.copyImage(png.path), png.path);
      await StorageLocations.configure({
        'op': 'cache.set',
        'path': '${root.path}/cache',
      });
      expect(StorageLocations.directory('imports'), contains('cache'));
      final preview = Directory(StorageLocations.directory('imports'));
      await preview.create(recursive: true);
      final held = File('${preview.path}/book.txt');
      await held.writeAsString('fake');
      final result = await StorageLocations.request({
        'op': 'cache.clean',
        'kinds': ['imports'],
      });
      expect((result['categories'] as List).first['skipped'], isNotNull);
      expect(await held.exists(), true);
      await expectLater(
        StorageLocations.request({
          'op': 'move.start',
          'path': '${root.path}/new',
          'plugins_stopped': false,
        }),
        throwsA(
          isA<StorageException>().having(
            (e) => e.code,
            'code',
            'storage_plugins_running',
          ),
        ),
      );
      expect(
        (await StorageLocations.request({'op': 'stats'}))['data'],
        isNotEmpty,
      );
      final state = PrototypeState(
        settingsDirectory: StorageLocations.directory('settings'),
      );
      final library = LegacyLibraryAdapter(backend: state);
      addTearDown(() {
        library.dispose();
        state.dispose();
      });
      await library.load();
      await library.savePatch({'check_after_import': false});
      final gone = await png.copy('${root.path}/gone.png');
      for (var i = 0; i < 2; i++) {
        final text = File('${root.path}/book$i.txt');
        await text.writeAsString('第一章 开始\n正文$i\n');
        expect((await library.importFiles([text.path])).single.succeeded, true);
        final id = library.books.value
            .singleWhere((b) => b.path == text.path)
            .id;
        final info = library.openBookInformation(id);
        await info.apply(
          await info.preview({'cover_path': i == 0 ? png.path : gone.path}),
        );
        info.dispose();
      }
      await gone.delete();
      final migrated = await library.copyReferencedImages();
      expect(migrated['copied'], 1);
      expect((migrated['missing'] as List).single['reason'], 'missing');
      final originals = library.books.value
          .map((b) => state.production.settings(b.id)['cover_path'])
          .toList();
      expect(originals, contains(stored));
      expect(originals, contains(gone.path));
      final move = await library.moveStorage('${root.path}/moved');
      await expectLater(
        library.moveStorage('${root.path}/duplicate'),
        throwsA(
          isA<StorageException>().having((e) => e.code, 'code', 'storage_busy'),
        ),
      );
      expect(PluginRegistry.instance.storageSuspended, true);
      Map<String, dynamic> progress;
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      do {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        progress = await library.storageMoveProgress(move['job_id'] as String);
      } while (!['ready', 'failed', 'cancelled'].contains(progress['phase']) &&
          DateTime.now().isBefore(deadline));
      expect(progress['phase'], 'ready', reason: '$progress');
      final status = await StorageLocations.request({'op': 'status'});
      expect(status['pending_restart'], true);
      expect(status['data_root'], isNot(status['pending_data_root']));
      expect(PluginRegistry.instance.storageSuspended, true);
      // 迁移工作已结束，测试自己的两个根均可清除。
      await root.delete(recursive: true);
    },
  );
}
