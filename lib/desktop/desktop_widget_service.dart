import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/desktop/desktop_widget_snapshot.dart';
import 'package:celechron/model/scholar.dart';
import 'package:celechron/model/task.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// Bridges the main process and the read-only Windows desktop widget.
///
/// The widget intentionally never opens Hive. The main process writes a small
/// JSON projection atomically, avoiding cross-process database locks and
/// keeping credentials out of the widget process.
final class DesktopWidgetService {
  static const widgetArgument = '--desktop-widget';
  static const closeWidgetArgument = '--close-desktop-widget';
  static const _snapshotFileName = 'desktop-widget-v1.json';
  static Timer? _publishTimer;

  static Future<File> snapshotFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$_snapshotFileName');
  }

  static Future<void> startPublishing() async {
    if (!Platform.isWindows || _publishTimer != null) return;
    await publishNow();
    _publishTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(publishNow()),
    );
  }

  static Future<void> publishNow() async {
    if (!Get.isRegistered<Rx<Scholar>>(tag: 'scholar') ||
        !Get.isRegistered<RxList<Task>>(tag: 'taskList')) {
      return;
    }
    final scholar = Get.find<Rx<Scholar>>(tag: 'scholar').value;
    final tasks = Get.find<RxList<Task>>(tag: 'taskList');
    final snapshot = DesktopWidgetSnapshot.forDay(
      now: DateTime.now(),
      periods: scholar.periods,
      tasks: tasks,
    );
    final target = await snapshotFile();
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  static Future<DesktopWidgetSnapshot?> readSnapshot() async {
    try {
      final file = await snapshotFile();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return DesktopWidgetSnapshot.fromJson(Map<String, dynamic>.from(json));
    } on Object {
      return null;
    }
  }

  static Future<void> showWidget() async {
    if (!Platform.isWindows) return;
    await publishNow();
    await Process.start(
      Platform.resolvedExecutable,
      const [widgetArgument],
      mode: ProcessStartMode.detached,
    );
  }

  static Future<void> hideWidget() async {
    if (!Platform.isWindows) return;
    await Process.start(
      Platform.resolvedExecutable,
      const [closeWidgetArgument],
      mode: ProcessStartMode.detached,
    );
  }
}
