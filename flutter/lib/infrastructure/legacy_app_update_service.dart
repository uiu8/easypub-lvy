import 'dart:convert';

import '../application/app_update_service.dart';
import '../src/rust/api.dart' as api;

/// 经 Rust `op: app_update` 完成检查、下载与启动更新程序（V68）。
class LegacyAppUpdateService implements AppUpdateService {
  LegacyAppUpdateService({this.appDirectory, this.baseUrl, this.testPublicKey});

  /// 测试用：程序目录、本机回环测试源与测试公钥。正式运行时都为空。
  final String? appDirectory, baseUrl, testPublicKey;

  Future<Map> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async => jsonDecode(
    await api.productionBatchText(
      requestJson: jsonEncode({
        'op': 'app_update',
        'action': action,
        'app_dir': ?appDirectory,
        'base_url': ?baseUrl,
        'test_public_key': ?testPublicKey,
        ...fields,
      }),
      apply: false,
      planId: '',
      confirmed: false,
    ),
  ) as Map;

  @override
  Future<UpdateStatus> status() async =>
      UpdateStatus.fromJson(await _call('status'));

  @override
  Future<UpdateCheck> check() async =>
      UpdateCheck.fromJson(await _call('check'));

  @override
  Future<UpdateProgress> download(int release) async =>
      UpdateProgress.fromJson(await _call('download', {'release': release}));

  @override
  Future<UpdateProgress> poll(int jobId) async =>
      UpdateProgress.fromJson(await _call('poll', {'job_id': jobId}));

  @override
  Future<UpdateProgress> cancel(int jobId) async =>
      UpdateProgress.fromJson(await _call('cancel', {'job_id': jobId}));

  @override
  Future<void> launch(String mode) => _call('launch', {'mode': mode});
}
