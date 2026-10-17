import 'dart:io';

import '../application/settings_service.dart';

import 'package:file_selector/file_selector.dart';

import '../application/library_service.dart';

class NativeBookPicker implements BookFilePicker {
  NativeBookPicker({this.settings});
  final SettingsService? settings;
  Future<String?> initialDirectory() async {
    await settings?.load();
    final path =
        settings?.snapshot.value.configuration['import_directory'] as String?;
    return path != null && path.isNotEmpty && await Directory(path).exists()
        ? path
        : null;
  }

  @override
  Future<String?> chooseFolder() async =>
      getDirectoryPath(initialDirectory: await initialDirectory());
  @override
  Future<String?> chooseProject() async => (await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'EasyPub++ 项目', extensions: ['json']),
    ],
  ))?.path;
  @override
  Future<String?> chooseProjectDestination() async => (await getSaveLocation(
    suggestedName: '书库.easypub.json',
    acceptedTypeGroups: const [
      XTypeGroup(label: 'EasyPub++ 项目', extensions: ['json']),
    ],
  ))?.path;
  @override
  Future<List<String>> chooseBooks() async => [
    for (final file in await openFiles(
      initialDirectory: await initialDirectory(),
      acceptedTypeGroups: const [
        XTypeGroup(label: '书稿', extensions: ['txt', 'epub']),
      ],
    ))
      file.path,
  ];
}
