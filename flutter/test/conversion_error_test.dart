import 'package:easypub_desktop/prototype/kindling_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final row in [
    ('engine_timed_out_review_log', 'Io', '超过执行时限'),
    ('engine_log_limit_review_log', 'TooLarge', '日志超过大小限制'),
    ('review_export_files_and_log', 'Io', '磁盘空间'),
    ('unknown', 'OutputConflict', '已有文件'),
    ('review_engine_output', 'InvalidRule', '成品无效'),
  ]) {
    test('转换失败给出原因和下一步 ${row.$1}', () async {
      final job = KindlingJob(
        onChanged: () {},
        call: (request) async {
          if (request['op'] == 'start') return {'job_id': 1};
          if (request['op'] == 'forget') return {};
          return {
            'phase': 'failed',
            'terminal': true,
            'error': {
              'next_action': row.$1,
              'code': row.$2,
              'raw': 'FAKE_COOKIE_BODY_PASSWORD',
            },
          };
        },
      );
      await expectLater(
        job.run({}),
        throwsA(
          isA<ExportStopped>()
              .having((e) => e.message, '原因', contains(row.$3))
              .having((e) => e.message, '下一步', contains('请'))
              .having(
                (e) => e.message,
                '不回显原始错误',
                isNot(contains('FAKE_COOKIE_BODY_PASSWORD')),
              ),
        ),
      );
    });
  }
}
