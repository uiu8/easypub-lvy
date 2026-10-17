import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easypub_desktop/application/conversion_desktop.dart';
import 'package:easypub_desktop/application/workspace_autosave_service.dart';
import 'package:easypub_desktop/desk/conversion/conversion_options_dialog.dart';
import 'package:easypub_desktop/desk/controls/controls.dart';

class _Desktop implements ConversionDesktop {
  @override
  Future<String?> bundledConverter() async => null;
  @override
  Future<String?> chooseConverter() async => r'D:\chosen\kindling.exe';
  @override
  Future<void> openDirectory(String path) async {}
  @override
  Future<void> openOutput(String path) async {}
}

class _Autosave implements WorkspaceAutosaveService {
  final drafts = <String, Map<String, dynamic>>{};
  @override
  final workspaceSave = ValueNotifier(
    const WorkspaceSaveStatus(WorkspaceSavePhase.saved, ''),
  );
  @override
  Map<String, dynamic>? readDraft(String key) => drafts[key];
  @override
  void writeDraft(String key, Map<String, dynamic>? value) =>
      value == null ? drafts.remove(key) : drafts[key] = value;
  @override
  Future<bool> flushWorkspace() async => true;
}

/// V40：删除转换选项“使用本次已确认的参考目录”（OUT-038）。
void main() {
  testWidgets('转换高级设置不再有参考目录选项；旧草稿里残留的开关被忽略', (t) async {
    final autosave = _Autosave();
    // V39 之前保存的弹窗草稿带 useCatalog。
    autosave.drafts['workspace/conversion-options/AZW3'] = {
      'engine': r'D:\old\kindling.exe',
      'engineEdited': true,
      'useCatalog': true,
    };
    Map<String, dynamic>? result;
    await t.pumpWidget(
      MaterialApp(
        theme: deskTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => ConversionOptionsDialog(
                      engine: '',
                      format: 'AZW3',
                      desktop: _Desktop(),
                      autosave: autosave,
                    ),
                  ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开'));
    await t.pumpAndSettle();
    expect(find.text('使用本次已确认的参考目录'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text(r'D:\old\kindling.exe'), findsOneWidget);
    await t.tap(find.text('采用设置'));
    await t.pumpAndSettle();
    expect(result, {'engine': r'D:\old\kindling.exe', 'engineEdited': true});
    expect(t.takeException(), isNull);
  });
}
