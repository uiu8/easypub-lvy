import 'package:easypub_desktop/prototype/kindling_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status disconnect retries same handle and forget failure preserves receipt', () async {
    final calls = <Map<String, dynamic>>[];
    var polls = 0;
    final job = KindlingJob(
      onChanged: () {},
      call: (request) async {
        calls.add(request);
        switch (request['op']) {
          case 'start':
            return {'job_id': 37};
          case 'status':
            expect(request['job_id'], 37);
            if (++polls == 1) throw StateError('temporary disconnect');
            return {
              'phase': 'complete',
              'terminal': true,
              'result': {'committed': true},
            };
          case 'forget':
            throw StateError('release failed');
          default:
            throw StateError('unexpected request');
        }
      },
    );
    expect(await job.run({'op': 'commit'}), {'committed': true});
    expect(calls.where((c) => c['op'] == 'start'), hasLength(1));
    expect(job.terminal, true);
    expect(job.id, isNull);
  });

  test(
    'repeated status polls notify only when visible state changes',
    () async {
      var notifications = 0;
      var polls = 0;
      final job = KindlingJob(
        onChanged: () => notifications++,
        call: (request) async {
          switch (request['op']) {
            case 'start':
              return {'job_id': 41};
            case 'status':
              polls++;
              if (polls < 3) {
                return {
                  'phase': 'converting',
                  'terminal': false,
                  'cancellable': true,
                };
              }
              return {
                'phase': 'complete',
                'terminal': true,
                'cancellable': false,
                'result': {'committed': true},
              };
            case 'forget':
              return {};
            default:
              throw StateError('unexpected operation');
          }
        },
      );
      expect(await job.run({}), {'committed': true});
      expect(polls, 3);
      expect(notifications, 2);
    },
  );
}
