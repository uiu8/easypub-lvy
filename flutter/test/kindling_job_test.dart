import 'package:easypub_desktop/src/rust/api.dart';
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

  test('pushed status finishes without polling and releases the job', () async {
    // 桥接第 1 批：后端推送状态，界面不再查询。
    final ops = <String>[];
    final phases = <String>[];
    late KindlingJob job;
    job = KindlingJob(
      onChanged: () => phases.add(job.phase),
      call: (request) async {
        ops.add(request['op'] as String);
        return switch (request['op']) {
          'start' => {'job_id': 7},
          'forget' => {},
          _ => throw StateError('should not poll'),
        };
      },
      watch: (id) {
        expect(id, 7);
        return Stream.fromIterable([
          {'phase': 'preparing', 'terminal': false, 'cancellable': true},
          {'phase': 'converting', 'terminal': false, 'cancellable': true},
          {
            'phase': 'completed',
            'terminal': true,
            'result': {'committed': true},
          },
        ]);
      },
    );
    expect(await job.run({}), {'committed': true});
    expect(ops, ['start', 'forget']);
    expect(phases, ['preparing', 'converting', 'completed']);
    expect(job.id, isNull);
  });

  test('broken push falls back to polling the same job', () async {
    final ops = <String>[];
    final job = KindlingJob(
      onChanged: () {},
      call: (request) async {
        ops.add(request['op'] as String);
        return switch (request['op']) {
          'start' => {'job_id': 9},
          'status' => {
            'phase': 'completed',
            'terminal': true,
            'result': {'committed': true},
          },
          _ => {},
        };
      },
      watch: (_) async* {
        yield {'phase': 'converting', 'terminal': false};
        throw StateError('stream closed');
      },
    );
    expect(await job.run({}), {'committed': true});
    expect(ops, ['start', 'status', 'forget']);
  });

  test('typed pushed status maps to the polled status fields', () {
    // 桥接第 2 批：推送的是有类型的状态，换成与查询相同的字段。
    expect(
      KindlingJob.statusFields(
        const KindlingJobStatus(
          phase: 'completed',
          terminal: true,
          cancellable: false,
          cancelRequested: false,
          resultJson: '{"committed":true}',
        ),
      ),
      {
        'phase': 'completed',
        'terminal': true,
        'cancellable': false,
        'cancel_requested': false,
        'result': {'committed': true},
      },
    );
    expect(
      KindlingJob.statusFields(
        const KindlingJobStatus(
          phase: 'failed',
          terminal: true,
          cancellable: false,
          cancelRequested: false,
          failure: JobFailure(code: 'Io', operation: 'x', nextAction: 'y'),
        ),
      )['error'],
      {'code': 'Io', 'operation': 'x', 'next_action': 'y'},
    );
  });

  test('pushed failure and cancellation stop with a message', () async {
    Future<Object?> outcome(Map<String, dynamic> last) async {
      final job = KindlingJob(
        onChanged: () {},
        call: (request) async =>
            request['op'] == 'start' ? {'job_id': 1} : <String, dynamic>{},
        watch: (_) => Stream.value(last),
      );
      try {
        await job.run({});
        return null;
      } catch (e) {
        return e;
      }
    }

    expect(
      await outcome({'phase': 'cancelled', 'terminal': true}),
      isA<ExportStopped>(),
    );
    expect(
      await outcome({
        'phase': 'failed',
        'terminal': true,
        'error': {'code': 'Io', 'operation': 'x', 'next_action': 'y'},
      }),
      isA<ExportStopped>(),
    );
  });
}
