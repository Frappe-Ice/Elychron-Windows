import 'package:celechron/model/period.dart';
import 'package:celechron/model/task.dart';

/// A platform-neutral, read-only projection consumed by Windows desktop widgets.
///
/// Keep this model free of Flutter and database dependencies. The Windows host
/// can read the serialized snapshot without opening Hive or duplicating the
/// scheduling rules owned by the main Elychron process.
class DesktopWidgetSnapshot {
  DesktopWidgetSnapshot({
    required this.generatedAt,
    required List<DesktopAgendaItem> items,
  }) : items = List.unmodifiable(items);

  factory DesktopWidgetSnapshot.forDay({
    required DateTime now,
    required Iterable<Period> periods,
    required Iterable<Task> tasks,
  }) {
    final dayStart = DateTime(now.year, now.month, now.day);
    // Courses and events cover today plus tomorrow. Deadlines keep the wider
    // upcoming horizon so assignments are never hidden just because they are
    // more than a day away.
    final scheduleEnd = dayStart.add(const Duration(days: 2));
    final taskHorizon = dayStart.add(const Duration(days: 8));
    final items = <DesktopAgendaItem>[];

    for (final period in periods) {
      if (period.type != PeriodType.classes && period.type != PeriodType.test) {
        continue;
      }
      if (!_overlapsDay(
          period.startTime, period.endTime, dayStart, scheduleEnd)) {
        continue;
      }
      items.add(DesktopAgendaItem(
        id: 'period:${period.uid}',
        title: period.summary,
        startTime: period.startTime,
        endTime: period.endTime,
        location: period.location,
        kind: period.type == PeriodType.classes
            ? DesktopAgendaKind.course
            : DesktopAgendaKind.exam,
      ));
    }

    for (final task in tasks) {
      if (!_isVisibleTask(task)) continue;
      final start = task.isEvent ? task.startTime : task.endTime;
      final end = task.isEvent ? task.endTime : task.endTime;
      final shouldInclude = task.isEvent
          ? _overlapsDay(start, end, dayStart, scheduleEnd)
          : _isRelevantUpcomingTask(task, dayStart, taskHorizon);
      if (!shouldInclude) continue;
      items.add(DesktopAgendaItem(
        id: 'task:${task.uid}',
        title: task.summary,
        startTime: start,
        endTime: end,
        location: task.location,
        kind: _kindForTask(task),
        urgent: task.isOverdue || task.priority == TaskPriority.urgent,
      ));
    }

    items.sort((left, right) {
      final startOrder = left.startTime.compareTo(right.startTime);
      if (startOrder != 0) return startOrder;
      final endOrder = left.endTime.compareTo(right.endTime);
      if (endOrder != 0) return endOrder;
      return left.title.compareTo(right.title);
    });
    return DesktopWidgetSnapshot(generatedAt: now, items: items);
  }

  final DateTime generatedAt;
  final List<DesktopAgendaItem> items;

  factory DesktopWidgetSnapshot.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return DesktopWidgetSnapshot(
      generatedAt: DateTime.parse(json['generatedAt'] as String),
      items: rawItems is List
          ? rawItems
              .whereType<Map>()
              .map((item) => DesktopAgendaItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList(growable: false)
          : const <DesktopAgendaItem>[],
    );
  }

  DesktopAgendaItem? get currentItem {
    for (final item in items) {
      if (!generatedAt.isBefore(item.startTime) &&
          generatedAt.isBefore(item.endTime)) {
        return item;
      }
    }
    return null;
  }

  DesktopAgendaItem? get nextItem {
    for (final item in items) {
      if (item.startTime.isAfter(generatedAt)) return item;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'generatedAt': generatedAt.toIso8601String(),
        'items': items.map((item) => item.toJson()).toList(growable: false),
      };

  static bool _overlapsDay(
    DateTime start,
    DateTime end,
    DateTime dayStart,
    DateTime dayEnd,
  ) {
    // A deadline/reminder is represented as an instant, while events are
    // represented as half-open ranges [start, end).
    if (start.isAtSameMomentAs(end)) {
      return !start.isBefore(dayStart) && start.isBefore(dayEnd);
    }
    return start.isBefore(dayEnd) && end.isAfter(dayStart);
  }

  static bool _isVisibleTask(Task task) {
    if (!task.showsInCalendar) return false;
    return task.status != TaskStatus.completed &&
        task.status != TaskStatus.deleted &&
        task.status != TaskStatus.outdated;
  }

  static bool _isRelevantUpcomingTask(
    Task task,
    DateTime dayStart,
    DateTime horizon,
  ) {
    if (task.isMemo) return false;
    if (task.type == TaskType.deadline && task.endTime.isBefore(dayStart)) {
      return true;
    }
    return !task.endTime.isBefore(dayStart) && task.endTime.isBefore(horizon);
  }

  static DesktopAgendaKind _kindForTask(Task task) {
    if (task.isEvent) return DesktopAgendaKind.event;
    if (task.isRemind) return DesktopAgendaKind.reminder;
    return DesktopAgendaKind.deadline;
  }
}

enum DesktopAgendaKind { course, exam, event, deadline, reminder }

class DesktopAgendaItem {
  const DesktopAgendaItem({
    required this.id,
    required this.title,
    required this.startTime,
    required this.endTime,
    required this.location,
    required this.kind,
    this.urgent = false,
  });

  final String id;
  final String title;
  final DateTime startTime;
  final DateTime endTime;
  final String location;
  final DesktopAgendaKind kind;
  final bool urgent;

  factory DesktopAgendaItem.fromJson(Map<String, dynamic> json) {
    return DesktopAgendaItem(
      id: json['id'] as String,
      title: json['title'] as String,
      startTime: DateTime.parse(json['startTime'] as String),
      endTime: DateTime.parse(json['endTime'] as String),
      location: json['location'] as String? ?? '',
      kind: DesktopAgendaKind.values.firstWhere(
        (kind) => kind.name == json['kind'],
        orElse: () => DesktopAgendaKind.event,
      ),
      urgent: json['urgent'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'location': location,
        'kind': kind.name,
        'urgent': urgent,
      };
}
