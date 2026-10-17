import 'package:flutter/foundation.dart';

enum WorkspaceSavePhase { saved, pending, saving, error }

class WorkspaceSaveStatus {
  const WorkspaceSaveStatus(this.phase, this.message, {this.savedAt});

  final WorkspaceSavePhase phase;
  final String message;
  final DateTime? savedAt;
}

/// Persistence of the working copy, including input that has not been applied.
/// Draft values must contain JSON values; storing them never applies an edit.
abstract interface class WorkspaceAutosaveService {
  ValueListenable<WorkspaceSaveStatus> get workspaceSave;
  Map<String, dynamic>? readDraft(String key);
  void writeDraft(String key, Map<String, dynamic>? value);
  Future<bool> flushWorkspace();
}
