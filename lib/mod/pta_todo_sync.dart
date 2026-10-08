import 'package:celechron/database/database_helper.dart';
import 'package:celechron/mod/database_mod.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/model/tombstone.dart';
import 'package:get/get.dart';

const String ptaTodoUidPrefix = 'pta:';

class PtaProblemSet {
  const PtaProblemSet({
    required this.id,
    required this.title,
    required this.url,
    required this.deadline,
  });

  final String id;
  final String title;
  final String url;
  final DateTime deadline;

  static List<PtaProblemSet> fromDashboardItems(
    Iterable<Object?> rawItems, {
    required DateTime now,
  }) {
    final byId = <String, PtaProblemSet>{};
    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final id = map['id']?.toString().trim() ?? '';
      final url = map['url']?.toString().trim() ?? '';
      final block = map['text']?.toString().trim() ?? '';
      if (id.isEmpty || url.isEmpty || block.isEmpty) continue;
      // The authenticated dashboard mixes assigned work with paid/public
      // recommendations. Assigned sets expose both an availability state and
      // a close/deadline state; catalogue cards do not. Never import merely
      // because a recommendation happens to contain a date.
      if (!_looksLikeAssignedProblemSet(block)) continue;

      final timestamps = RegExp(
        r'(20\d{2})[\-/年](\d{1,2})[\-/月](\d{1,2})日?\s+(\d{1,2}):(\d{2})',
      ).allMatches(block).toList();
      if (timestamps.isEmpty) continue;
      final last = timestamps.last;
      final deadline = DateTime(
        int.parse(last.group(1)!),
        int.parse(last.group(2)!),
        int.parse(last.group(3)!),
        int.parse(last.group(4)!),
        int.parse(last.group(5)!),
      );
      // Dashboard may retain recently closed sets. They are useful on PTA but
      // should not suddenly become overdue Elychron tasks.
      if (deadline.isBefore(now.subtract(const Duration(hours: 1)))) continue;

      final hintedTitle = (map['title']?.toString() ?? '')
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .firstWhere(_usableTitle, orElse: () => '');
      final title = _usableTitle(hintedTitle)
          ? hintedTitle
          : block
              .split(RegExp(r'[\r\n]+'))
              .map((line) => line.trim())
              .firstWhere(_usableTitle, orElse: () => 'PTA 题集 $id');
      byId[id] = PtaProblemSet(
        id: id,
        title: title,
        url: url,
        deadline: deadline,
      );
    }
    final result = byId.values.toList()
      ..sort((left, right) => left.deadline.compareTo(right.deadline));
    return result;
  }

  static bool _usableTitle(String value) {
    if (value.length < 3 || value.length > 160) return false;
    if (RegExp(r'^20\d{2}[\-/年]').hasMatch(value)) return false;
    return !const {'进入', '查看', '开始', '继续', '详情', '登录'}.contains(value);
  }

  static bool _looksLikeAssignedProblemSet(String text) {
    final hasAvailability = RegExp(r'已开放|未开放|将于.{0,32}开放').hasMatch(text);
    final hasDeadline = RegExp(r'关闭|截止|结束').hasMatch(text);
    return hasAvailability && hasDeadline;
  }
}

bool isVerifiedPtaAssignmentTask(Task task) {
  if (!task.uid.startsWith(ptaTodoUidPrefix)) return true;
  final text = '${task.summary}\n${task.description}';
  return text.contains('来自 PTA 已布置题集（严格验证）') ||
      (RegExp(r'已开放|未开放|将于.{0,32}开放').hasMatch(text) &&
          RegExp(r'关闭|截止|结束').hasMatch(text));
}

/// Removes the one known bad import batch created by the early dashboard
/// scraper. It deliberately does not create tombstones: if one of those IDs is
/// later genuinely assigned to the user, the corrected scraper may import it.
Future<int> cleanupInvalidPtaImports() async {
  if (!Get.isRegistered<RxList<Task>>(tag: 'taskList') ||
      !Get.isRegistered<Rx<DateTime>>(tag: 'taskListLastUpdate') ||
      !Get.isRegistered<DatabaseHelper>(tag: 'db')) {
    return 0;
  }
  final db = Get.find<DatabaseHelper>(tag: 'db');
  final taskList = Get.find<RxList<Task>>(tag: 'taskList');
  final before = taskList.length;
  taskList.removeWhere(
    (task) =>
        task.uid.startsWith(ptaTodoUidPrefix) &&
        !isVerifiedPtaAssignmentTask(task),
  );
  final removed = before - taskList.length;
  if (removed == 0) return 0;
  final updatedAt = Get.find<Rx<DateTime>>(tag: 'taskListLastUpdate');
  updatedAt.value = DateTime.now();
  await db.setTaskList(taskList);
  await db.setTaskListUpdateTime(updatedAt.value);
  return removed;
}

List<Task> newTasksFromPtaProblemSets({
  required Iterable<PtaProblemSet> problemSets,
  required Iterable<Task> existingTasks,
  required Iterable<TaskTombstone> tombstones,
  required DateTime now,
}) {
  final known = existingTasks.map((task) => task.uid).toSet()
    ..addAll(tombstones.map((tombstone) => tombstone.uid));
  final additions = <Task>[];
  for (final problemSet in problemSets) {
    final uid = '$ptaTodoUidPrefix${problemSet.id}';
    if (!known.add(uid)) continue;
    additions.add(Task(
      uid: uid,
      summary: problemSet.title,
      description: _ptaTaskDescription(problemSet),
      location: 'PTA',
      type: TaskType.deadline,
      startTime: problemSet.deadline,
      endTime: problemSet.deadline,
      repeatEndsTime: DateTime(
        problemSet.deadline.year,
        problemSet.deadline.month,
        problemSet.deadline.day,
      ),
      tags: const <String>['PTA'],
      createdAt: now,
      updatedAt: now,
    ));
  }
  return additions;
}

Future<int> syncPtaProblemSetsIntoTaskList(
  Iterable<PtaProblemSet> problemSets,
) async {
  if (!Get.isRegistered<RxList<Task>>(tag: 'taskList') ||
      !Get.isRegistered<Rx<DateTime>>(tag: 'taskListLastUpdate') ||
      !Get.isRegistered<DatabaseHelper>(tag: 'db')) {
    return 0;
  }
  final db = Get.find<DatabaseHelper>(tag: 'db');
  final taskList = Get.find<RxList<Task>>(tag: 'taskList');
  final additions = newTasksFromPtaProblemSets(
    problemSets: problemSets,
    existingTasks: taskList,
    tombstones: db.getTombstones(),
    now: DateTime.now(),
  );
  var changed = additions.isNotEmpty;
  final now = DateTime.now();
  final byUid = <String, PtaProblemSet>{
    for (final problemSet in problemSets)
      '$ptaTodoUidPrefix${problemSet.id}': problemSet,
  };
  for (final task in taskList) {
    final problemSet = byUid[task.uid];
    if (problemSet == null) continue;
    final description = _ptaTaskDescription(problemSet);
    if (task.summary == problemSet.title &&
        task.description == description &&
        task.startTime == problemSet.deadline &&
        task.endTime == problemSet.deadline) {
      continue;
    }
    // Keep user-owned state such as completed/starred/reminders, but follow
    // deadline and title corrections made by the course owner on PTA.
    task.summary = problemSet.title;
    task.description = description;
    task.location = 'PTA';
    task.startTime = problemSet.deadline;
    task.endTime = problemSet.deadline;
    task.repeatEndsTime = DateTime(
      problemSet.deadline.year,
      problemSet.deadline.month,
      problemSet.deadline.day,
    );
    if (!task.tags.contains('PTA')) task.tags.add('PTA');
    task.updatedAt = now;
    changed = true;
  }
  if (!changed) return 0;
  taskList.addAll(additions);
  taskList.sort((left, right) => left.endTime.compareTo(right.endTime));
  final updatedAt = Get.find<Rx<DateTime>>(tag: 'taskListLastUpdate');
  updatedAt.value = DateTime.now();
  await db.setTaskList(taskList);
  await db.setTaskListUpdateTime(updatedAt.value);
  return additions.length;
}

String _ptaTaskDescription(PtaProblemSet problemSet) {
  String two(int value) => value.toString().padLeft(2, '0');
  final deadline = problemSet.deadline;
  return '来自 PTA 已布置题集（严格验证）\n'
      '截止：${deadline.year}-${two(deadline.month)}-${two(deadline.day)} '
      '${two(deadline.hour)}:${two(deadline.minute)}\n'
      '${problemSet.url}';
}
