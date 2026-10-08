import 'package:celechron/database/database_helper.dart';
import 'package:celechron/mod/database_mod.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/model/todo.dart';
import 'package:celechron/model/tombstone.dart';
import 'package:get/get.dart';

const String scholarTodoUidPrefix = 'courses:';

/// Converts newly discovered Courses assignments into normal Elychron tasks.
///
/// Existing tasks are never overwritten: after importing an assignment the
/// user owns that task and may edit or complete it. A deterministic uid plus
/// deletion tombstones prevents later refreshes from recreating it.
List<Task> newTasksFromScholarTodos({
  required Iterable<Todo> todos,
  required Iterable<Task> existingTasks,
  required Iterable<TaskTombstone> tombstones,
  required DateTime now,
}) {
  final known = existingTasks.map((task) => task.uid).toSet();
  known.addAll(tombstones.map((tombstone) => tombstone.uid));
  final additions = <Task>[];

  for (final todo in todos) {
    if (todo.id.isEmpty) continue;
    final uid = '$scholarTodoUidPrefix${todo.id}';
    if (!known.add(uid)) continue;
    final due = todo.endTime;
    final anchor = due ?? now;
    additions.add(Task(
      uid: uid,
      summary: todo.name,
      description: '来自学在浙大\n课程：${todo.course}',
      location: todo.course,
      type: due == null ? TaskType.memo : TaskType.deadline,
      startTime: anchor,
      endTime: anchor,
      repeatEndsTime: DateTime(anchor.year, anchor.month, anchor.day),
      tags: <String>['学在浙大', todo.course],
      createdAt: now,
      updatedAt: now,
    ));
  }
  return additions;
}

Future<int> syncScholarTodosIntoTaskList(Iterable<Todo> todos) async {
  if (!Get.isRegistered<RxList<Task>>(tag: 'taskList') ||
      !Get.isRegistered<Rx<DateTime>>(tag: 'taskListLastUpdate') ||
      !Get.isRegistered<DatabaseHelper>(tag: 'db')) {
    return 0;
  }
  final db = Get.find<DatabaseHelper>(tag: 'db');
  final taskList = Get.find<RxList<Task>>(tag: 'taskList');
  final additions = newTasksFromScholarTodos(
    todos: todos,
    existingTasks: taskList,
    tombstones: db.getTombstones(),
    now: DateTime.now(),
  );
  if (additions.isEmpty) return 0;

  taskList.addAll(additions);
  taskList.sort((left, right) => left.endTime.compareTo(right.endTime));
  final updatedAt = Get.find<Rx<DateTime>>(tag: 'taskListLastUpdate');
  updatedAt.value = DateTime.now();
  await db.setTaskList(taskList);
  await db.setTaskListUpdateTime(updatedAt.value);
  return additions.length;
}
