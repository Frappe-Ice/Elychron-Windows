import 'package:celechron/desktop/desktop_widget_snapshot.dart';
import 'package:celechron/model/period.dart';
import 'package:celechron/model/task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 8, 10, 0);

  test('combines course and task data into a sorted desktop snapshot', () {
    final course = Period(
      uid: 'course-1',
      type: PeriodType.classes,
      summary: '软件工程',
      location: '紫金港东1A-101',
      startTime: DateTime(2026, 10, 8, 8, 0),
      endTime: DateTime(2026, 10, 8, 9, 35),
    );
    final task = Task(
      uid: 'task-1',
      summary: '提交实验报告',
      type: TaskType.deadline,
      startTime: DateTime(2026, 10, 8, 20, 0),
      endTime: DateTime(2026, 10, 8, 20, 0),
      repeatEndsTime: DateTime(2026, 10, 8),
    );

    final snapshot = DesktopWidgetSnapshot.forDay(
      now: now,
      periods: [course],
      tasks: [task],
    );

    expect(snapshot.items.map((item) => item.title), [
      '软件工程',
      '提交实验报告',
    ]);
    expect(snapshot.nextItem?.id, 'task:task-1');
    expect(snapshot.toJson()['version'], 1);
  });

  test('includes an overnight course that overlaps the selected day', () {
    final overnight = Period(
      uid: 'overnight',
      type: PeriodType.classes,
      summary: '跨夜安排',
      startTime: DateTime(2026, 10, 7, 23, 30),
      endTime: DateTime(2026, 10, 8, 0, 30),
    );

    final snapshot = DesktopWidgetSnapshot.forDay(
      now: now,
      periods: [overnight],
      tasks: const [],
    );

    expect(snapshot.items.single.id, 'period:overnight');
  });

  test('includes tomorrow courses but not the day after tomorrow', () {
    Period course(String id, DateTime start) => Period(
          uid: id,
          type: PeriodType.classes,
          summary: id,
          startTime: start,
          endTime: start.add(const Duration(hours: 1)),
        );

    final snapshot = DesktopWidgetSnapshot.forDay(
      now: now,
      periods: [
        course('tomorrow', DateTime(2026, 10, 9, 8)),
        course('later', DateTime(2026, 10, 10, 8)),
      ],
      tasks: const [],
    );

    expect(snapshot.items.map((item) => item.id), ['period:tomorrow']);
  });

  test('omits completed tasks and memos from the desktop agenda', () {
    Task task(String id, TaskType type, TaskStatus status) => Task(
          uid: id,
          summary: id,
          type: type,
          status: status,
          startTime: DateTime(2026, 10, 8, 12),
          endTime: DateTime(2026, 10, 8, 12),
          repeatEndsTime: DateTime(2026, 10, 8),
        );

    final snapshot = DesktopWidgetSnapshot.forDay(
      now: now,
      periods: const [],
      tasks: [
        task('completed', TaskType.deadline, TaskStatus.completed),
        task('memo', TaskType.memo, TaskStatus.running),
      ],
    );

    expect(snapshot.items, isEmpty);
  });

  test('includes upcoming deadlines so imported assignments reach the widget',
      () {
    final now = DateTime(2026, 10, 8, 12);
    final upcoming = Task(
      uid: 'courses:assignment-1',
      summary: '课程作业',
      type: TaskType.deadline,
      startTime: DateTime(2026, 10, 11, 20),
      endTime: DateTime(2026, 10, 11, 20),
      repeatEndsTime: DateTime(2026, 10, 11),
    );

    final snapshot = DesktopWidgetSnapshot.forDay(
      now: now,
      periods: const [],
      tasks: [upcoming],
    );

    expect(snapshot.items.map((item) => item.id),
        contains('task:courses:assignment-1'));
  });
}
