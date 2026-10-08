import 'package:celechron/mod/pta_todo_sync.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/model/tombstone.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 8, 12);

  test(
      'PTA dashboard parser keeps every future deadline without a one-week cap',
      () {
    final sets = PtaProblemSet.fromDashboardItems(
      [
        {
          'id': '1001',
          'url': 'https://pintia.cn/problem-sets/1001',
          'title': '十月实验',
          'text': '十月实验\n已开放\n2026/10/1 08:00 – 2026/10/20 23:59关闭',
        },
        {
          'id': '1002',
          'url': 'https://pintia.cn/problem-sets/1002',
          'title': '十二月大作业',
          'text': '十二月大作业\n已开放\n开放 2026-10-08 08:00\n截止 2026-12-31 23:59',
        },
      ],
      now: now,
    );

    expect(sets.map((set) => set.id), ['1001', '1002']);
    expect(sets.last.deadline, DateTime(2026, 12, 31, 23, 59));
  });

  test('closed PTA sets are not turned into new overdue tasks', () {
    final sets = PtaProblemSet.fromDashboardItems(
      [
        {
          'id': 'old',
          'url': 'https://pintia.cn/problem-sets/old',
          'title': '旧题集',
          'text': '旧题集\n已开放\n2026/09/01 08:00 – 2026/09/08 23:59关闭',
        },
      ],
      now: now,
    );
    expect(sets, isEmpty);
  });

  test('catalogue courses and books are rejected even when they contain dates',
      () {
    final sets = PtaProblemSet.fromDashboardItems(
      [
        {
          'id': 'book-1',
          'url': 'https://pintia.cn/problem-sets/12',
          'title': '程序设计习题集教材',
          'text': '程序设计习题集教材\n限时优惠至 2026/12/31 23:59',
        },
        {
          'id': 'assigned-1',
          'url': 'https://pintia.cn/problem-sets/1001',
          'title': '课程实验\n将于2026-12-31 23:59关闭\n已开放',
          'text': '课程实验\n将于2026-12-31 23:59关闭\n已开放',
        },
      ],
      now: now,
    );

    expect(sets.map((set) => set.id), ['assigned-1']);
    expect(sets.single.title, '课程实验');
  });

  test('cleanup classifier keeps assigned tasks and rejects catalogue imports',
      () {
    Task ptaTask(String id, String summary) => Task(
          uid: 'pta:$id',
          summary: summary,
          description: '来自 PTA',
          startTime: now,
          endTime: now,
          repeatEndsTime: now,
        );

    expect(
      isVerifiedPtaAssignmentTask(
        ptaTask('assignment', '真实实验\n将于2026-12-31 23:59关闭\n已开放'),
      ),
      isTrue,
    );
    expect(
      isVerifiedPtaAssignmentTask(ptaTask('book', '程序设计教材限时优惠')),
      isFalse,
    );
    expect(
      isVerifiedPtaAssignmentTask(Task(
        uid: 'pta:new-format',
        summary: '新格式实验',
        description: '来自 PTA 已布置题集（严格验证）\n截止：2026-12-31 23:59',
        startTime: now,
        endTime: now,
        repeatEndsTime: now,
      )),
      isTrue,
    );
  });

  test('PTA imports use stable ids and respect existing tasks and tombstones',
      () {
    PtaProblemSet set(String id) => PtaProblemSet(
          id: id,
          title: '题集 $id',
          url: 'https://pintia.cn/problem-sets/$id',
          deadline: DateTime(2026, 12, 31),
        );
    final existing = Task(
      uid: 'pta:1',
      startTime: now,
      endTime: now,
      repeatEndsTime: now,
    );
    final tasks = newTasksFromPtaProblemSets(
      problemSets: [set('1'), set('2'), set('3')],
      existingTasks: [existing],
      tombstones: [TaskTombstone(uid: 'pta:2', deletedAt: now)],
      now: now,
    );

    expect(tasks, hasLength(1));
    expect(tasks.single.uid, 'pta:3');
    expect(tasks.single.type, TaskType.deadline);
    expect(tasks.single.tags, ['PTA']);
    expect(tasks.single.description, contains('来自 PTA 已布置题集（严格验证）'));
    expect(tasks.single.description, contains('截止：2026-12-31 00:00'));
  });
}
