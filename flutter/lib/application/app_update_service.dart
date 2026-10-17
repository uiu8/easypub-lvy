// 自动更新（V68，SET-071–073）：检查 GitHub 发布页、后台下载并校验、启动更新程序。
// 实际的网络、校验与文件替换在 Rust（easypub_app::app_update 与 easypub_updater.exe）。

class UpdateRelease {
  UpdateRelease.fromJson(Map v)
    : release = v['release'] as int,
      tag = v['tag'] as String? ?? '',
      date = v['date'] as String? ?? '',
      notes = v['notes'] as String? ?? '',
      bytes = v['bytes'] as int? ?? 0;
  final int release, bytes;
  final String tag, date, notes;
}

class UpdateStatus {
  UpdateStatus.fromJson(Map v)
    : packaged = v['packaged'] == true,
      writable = v['writable'] == true,
      currentRelease = v['current_release'] as int?,
      ready = v['ready'] is Map
          ? UpdateRelease.fromJson(v['ready'] as Map)
          : null,
      backupRelease = v['backup_release'] as int?,
      lastError = (v['last'] is Map)
          ? (v['last'] as Map)['error'] as String?
          : null,
      releasesUrl = v['releases_url'] as String? ?? '';

  /// 从发布包运行，并且包里有更新程序；开发版本为 false。
  final bool packaged;

  /// 程序目录可写（装在 Program Files 等只读位置时不能自动更新）。
  final bool writable;
  final int? currentRelease, backupRelease;

  /// 已下载并校验、等待重启替换的版本。
  final UpdateRelease? ready;

  /// 上次替换失败时更新程序留下的原因代码。
  final String? lastError;
  final String releasesUrl;
}

class UpdateCheck {
  UpdateCheck.fromJson(Map v)
    : available = v['available'] == true,
      currentRelease = v['current_release'] as int?,
      latest = UpdateRelease.fromJson(v['latest'] as Map);
  final bool available;
  final int? currentRelease;
  final UpdateRelease latest;
}

class UpdateProgress {
  UpdateProgress.fromJson(Map v)
    : jobId = v['job_id'] as int,
      phase = v['phase'] as String,
      received = v['received'] as int? ?? 0,
      total = v['total'] as int? ?? 0,
      error = v['error'] as String?;
  final int jobId, received, total;

  /// downloading / extracting / verifying / completed / cancelled / failed。
  final String phase;
  final String? error;
  bool get active =>
      const {'downloading', 'extracting', 'verifying'}.contains(phase);
}

abstract interface class AppUpdateService {
  Future<UpdateStatus> status();
  Future<UpdateCheck> check();

  /// 开始下载 [release]（必须是最近一次检查得到的版本）。
  Future<UpdateProgress> download(int release);
  Future<UpdateProgress> poll(int jobId);
  Future<UpdateProgress> cancel(int jobId);

  /// 启动更新程序：update 换成已下载的新版本；rollback 换回上一版。调用方随后退出程序。
  Future<void> launch(String mode);
}

abstract interface class AppUpdateLibrary {
  AppUpdateService get appUpdates;

  /// 有转换或批量任务在进行时不能重启更新。
  bool get updateBlockedByTasks;
}
