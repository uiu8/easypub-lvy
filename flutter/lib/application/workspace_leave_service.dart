import 'package:flutter/foundation.dart';

import 'library_service.dart';

abstract interface class WorkspaceResetService {
  Future<ProjectOutcome> clearWorkspace();
}

/// Authoritative state used by all workspace replacement/exit entry points.
abstract class WorkspaceLeaveService {
  bool get hasUnsavedChanges;
  bool get hasPendingWork;
  String get workspaceIdentity;
}

/// Advances only after an entire replacement project has been accepted.
/// Ordinary edits, saves and failed opens do not invalidate mounted forms.
abstract class WorkspaceLifecycleService {
  ValueListenable<int> get workspaceGeneration;
}
