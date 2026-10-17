import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:easypub_desktop/src/rust/frb_generated.dart';
import 'package:easypub_desktop/src/rust/api.dart' as api;
import 'package:easypub_desktop/prototype/prototype_state.dart';
import 'package:easypub_desktop/prototype/project_io.dart' as project_io;
import 'package:easypub_desktop/infrastructure/legacy_library_adapter.dart';

/// Diagnostic assertions document current defects, not acceptance of repairs.
/// All books, settings, and projects are synthetic and isolated in systemTemp.
void main() {
  test('audit state transitions against real native library', () async {
    final dll = File(Platform.environment['EASYPUB_TEST_DLL'] ?? '../target/release/easypub_bridge.dll').absolute.path;
    await RustLib.init(externalLibrary: ExternalLibrary.open(dll));
    final dir = await Directory.systemTemp.createTemp('easypub-audit-state-20261004-');
    final results = <Map<String, dynamic>>[];
    final undoState = PrototypeState(settingsDirectory: dir.path + '/undo-settings');
    final undoLibrary = LegacyLibraryAdapter(backend: undoState);
    await undoLibrary.load();
    final source = File(dir.path + '/undo-source.txt');
    const original = '第一章 开始\n这里是正文  \n第二章 后续\n正文结束\n';
    await source.writeAsString(original);
    expect((await undoLibrary.importFiles([source.path])).single.succeeded, true);
    final bookId = undoLibrary.books.value.single.id;
    final cleanup = undoLibrary.openCleanup(bookId);
    final plan = await cleanup.preview(jsonEncode({
      'kind': 'cleanup',
      'pipeline': [{'kind': 'trim_trailing_spaces'}],
    }));
    await cleanup.apply(plan);
    final chapters = undoLibrary.openChapters(bookId);
    final page = await chapters.read(0);
    await chapters.rename(page, page.nodes.first.id, '第一章 已改名');
    final beforeUndo = await chapters.read(0);
    expect(beforeUndo.nodes.first.title, '第一章 已改名');
    await cleanup.undo();
    Object? afterUndoError;
    try { await chapters.read(0); } catch (error) { afterUndoError = error; }
    final undoProjectPath = dir.path + '/after-undo.easypub.json';
    final saveAfterUndo = await undoState.saveProjectOutcome(undoProjectPath);
    final saveAfterUndoMessage = undoState.projectStatus;
    final brokenReopened = PrototypeState(settingsDirectory: dir.path + '/broken-reopen-settings');
    final brokenOpenOk = await brokenReopened.openProjectOutcome(undoProjectPath);
    Object? brokenReopenError;
    try { await brokenReopened.manuscript.effectiveTree(brokenReopened.currentId, 0); }
    catch (error) { brokenReopenError = error; }
    final undoNativeError = afterUndoError is api.ApiError
        ? jsonDecode(await api.describeApiError(error: afterUndoError)) : null;
    final reopenNativeError = brokenReopenError is api.ApiError
        ? jsonDecode(await api.describeApiError(error: brokenReopenError)) : null;
    brokenReopened.dispose();
    await cleanup.redo();
    final restored = await chapters.read(0);
    results.add({
      'id': 'STATE-01',
      'scenario': 'apply cleanup -> rename chapter -> undo cleanup -> read effective manuscript',
      'observed': 'cleanup undo accepted but subsequent effective read fails; redo cleanup restores readability',
      'read_error_type': afterUndoError?.runtimeType.toString(),
      'native_error': undoNativeError,
      'broken_project_opened': brokenOpenOk,
      'broken_project_effective_read_error': reopenNativeError,
      'read_error': afterUndoError.toString(),
      'save_after_undo': saveAfterUndo,
      'save_after_undo_message': saveAfterUndoMessage,
      'redo_title': restored.nodes.first.title,
      'original_unchanged': await source.readAsString() == original,
      'reproduced': afterUndoError != null,
    });
    expect(afterUndoError, isNotNull, reason: 'Audit must reproduce invalid cross-domain state.');
    expect(restored.nodes.first.title, '第一章 已改名');
    expect(await source.readAsString(), original);
    cleanup.dispose();
    undoLibrary.dispose();
    undoState.dispose();

    final saverEntered = Completer<void>(), saverRelease = Completer<void>();
    Map<String, dynamic>? payload;
    final raceState = PrototypeState(
      settingsDirectory: dir.path + '/race-settings',
      projectSaver: (path, data) async {
        // Serialize where project_io.saveProject does; only completion is delayed.
        payload = (jsonDecode(jsonEncode(data)) as Map).cast<String, dynamic>();
        await project_io.saveProject(path, payload!);
        saverEntered.complete();
        await saverRelease.future;
      },
    );
    final raceLibrary = LegacyLibraryAdapter(backend: raceState);
    await raceLibrary.load();
    final raceSource = File(dir.path + '/race-source.txt');
    await raceSource.writeAsString('第一章 保存前\n测试内容\n第二章 继续\n结尾\n');
    expect((await raceLibrary.importFiles([raceSource.path])).single.succeeded, true);
    final raceId = raceLibrary.books.value.single.id;
    final raceChapters = raceLibrary.openChapters(raceId);
    final racePage = await raceChapters.read(0);
    final racePath = dir.path + '/concurrent-save.easypub.json';
    final saving = raceState.saveProjectOutcome(racePath);
    await saverEntered.future;
    expect(raceState.projectBusy, true);
    await raceChapters.rename(racePage, racePage.nodes.first.id, '第一章 保存进行中修改');
    saverRelease.complete();
    final saved = await saving;
    final dirtyAfter = raceState.savedProjectIdentity != raceState.projectIdentity;
    final liveTitle = (await raceChapters.read(0)).nodes.first.title;
    final reopened = PrototypeState(settingsDirectory: dir.path + '/reopen-settings');
    final reopenOk = await reopened.openProjectOutcome(racePath);
    final reopenedTree = await reopened.manuscript.effectiveTree(reopened.currentId, 0);
    final reopenedTitle = (reopenedTree['nodes'] as List).first['title'];
    results.add({
      'id': 'STATE-02',
      'scenario': 'save project pending -> chapter rename -> save completes -> reopen saved project',
      'saved': saved,
      'live_title': liveTitle,
      'reported_dirty': dirtyAfter,
      'reopen_ok': reopenOk,
      'reopened_title': reopenedTitle,
      'serialized_payload_had_effective_history': (payload!['books'] as List).first['effective_history'] != null,
      'reproduced': saved && !dirtyAfter && liveTitle != reopenedTitle,
    });
    expect(saved, true);
    expect(dirtyAfter, false, reason: 'Audit confirms false clean status in current implementation.');
    expect(reopenedTitle, isNot(liveTitle));
    reopened.dispose();
    raceLibrary.dispose();
    raceState.dispose();
    final report = {
      'type': 'diagnostic-observation-not-fix-acceptance',
      'at': DateTime.now().toIso8601String(),
      'dll': dll,
      'dll_sha256': sha256.convert(await File(dll).readAsBytes()).toString(),
      'synthetic_workspace': dir.path,
      'real_user_settings_or_cookie_read': false,
      'results': results,
    };
    await File('../artifacts/audit-20261004-state.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(report));
    print(const JsonEncoder.withIndent('  ').convert(report));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

