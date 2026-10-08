import 'package:celechron/mod/scholar_todo_sync.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/model/todo.dart';
import 'package:celechron/model/tombstone.dart';
import 'package:flutter_test/flutter_test.dart';

Todo todo(String id, {String? endTime}) => Todo.fromJson({
      'id': id,
      'title': '第 $id 次作业',
      'course_name': '测试课程',
      'end_time': endTime,
    });

void main() {
  final now = DateTime(2026, 10, 8, 12);

  test('新作业生成普通截止型待办', () {
    final tasks = newTasksFromScholarTodos(
      todos: [todo('42', endTime: '2026-10-10T20:00:00')],
      existingTasks: const [],
      tombstones: const [],
      now: now,
    );

    expect(tasks, hasLength(1));
    expect(tasks.single.uid, 'courses:42');
    expect(tasks.single.type, TaskType.deadline);
    expect(tasks.single.summary, '第 42 次作业');
    expect(tasks.single.location, '测试课程');
    expect(tasks.single.tags, contains('学在浙大'));
  });

  test('已导入或已删除的作业不会再次生成', () {
    final existing = Task(
      uid: 'courses:1',
      startTime: now,
      endTime: now,
      repeatEndsTime: now,
    );
    final tasks = newTasksFromScholarTodos(
      todos: [todo('1'), todo('2'), todo('3')],
      existingTasks: [existing],
      tombstones: [TaskTombstone(uid: 'courses:2', deletedAt: now)],
      now: now,
    );

    expect(tasks.map((task) => task.uid), ['courses:3']);
    expect(tasks.single.type, TaskType.memo);
  });
}
