import 'dart:async';

import 'package:celechron/design/alarm_reliability.dart';
import 'package:celechron/design/alarm_theme_picker.dart';
import 'package:celechron/database/database_helper.dart';
import 'package:celechron/desktop/desktop_widget_service.dart';
import 'package:celechron/desktop/windows_startup_service.dart';
import 'package:celechron/mod/ai/ai_settings_page.dart';
import 'package:celechron/mod/ai/deepseek.dart';
import 'package:celechron/mod/lan_sync_page.dart';
import 'package:celechron/mod/settings_data_actions.dart';
import 'package:celechron/page/focus/focus_stats_page.dart';
import 'package:celechron/page/option/option_controller.dart';
import 'package:celechron/page/option/option_view.dart' show BackChervonRow;
import 'package:celechron/model/scholar.dart';
import 'package:celechron/model/task.dart';
import 'package:celechron/services/pta_sync_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:celechron/utils/platform_features.dart';

/// ============ 设置页里属于魔改的两个区块 ============
///
/// 上游的 `lib/page/option/option_view.dart` 一直在更新（1.3 就加了 36 行），
/// 所以把这些声明式的设置行放在这里，那个文件里只留两处挂载（见 `// ===== MOD =====`）。

/// 是否开放「局域网同步」（多端协同）入口。
///
/// **公开发布这版先关掉**：功能尚未完工（用户决定）。代码、网页面板与测试都保留，
/// 把这里改回 `true` 就能恢复入口，不需要改别的地方。
const bool kLanSyncEnabled = false;

/// Windows 专属能力：从主程序导出只读快照，由独立桌面挂件展示。
Widget modWindowsSection(
  BuildContext context, {
  required TextStyle? headerStyle,
  required EdgeInsetsGeometry margin,
}) {
  if (!PlatformFeatures.isWindows) {
    return const SliverToBoxAdapter(child: SizedBox.shrink());
  }
  return SliverToBoxAdapter(
    child: CupertinoListSection.insetGrouped(
      additionalDividerMargin: 2,
      margin: margin,
      header: Container(
        padding: const EdgeInsets.only(left: 16),
        child: Text('Windows', style: headerStyle),
      ),
      children: const [
        _WindowsSyncStatusTile(),
        _WindowsAutoStartTile(),
        _WindowsWidgetVisibleTile(),
        _WindowsCloseBehaviorTile(),
        _WindowsShortcutTile(),
      ],
    ),
  );
}

class _WindowsAutoStartTile extends StatefulWidget {
  const _WindowsAutoStartTile();

  @override
  State<_WindowsAutoStartTile> createState() => _WindowsAutoStartTileState();
}

class _WindowsAutoStartTileState extends State<_WindowsAutoStartTile> {
  late bool _enabled;
  bool _busy = false;

  DatabaseHelper get _db => Get.find<DatabaseHelper>(tag: 'db');

  @override
  void initState() {
    super.initState();
    _enabled = _db.getWindowsWidgetAutoStart();
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await WindowsStartupService.applyWidgetAutoStart(enabled);
      await _db.setWindowsWidgetAutoStart(enabled);
      if (mounted) setState(() => _enabled = enabled);
    } on Object catch (error) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('设置失败'),
          content: Text(error.toString()),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: const Text('Windows 后台开机启动'),
      subtitle: const Text('不弹主窗口；保持托盘、自动同步和挂件更新'),
      trailing: CupertinoSwitch(
        value: _enabled,
        onChanged: _busy ? null : _setEnabled,
      ),
      onTap: _busy ? null : () => _setEnabled(!_enabled),
    );
  }
}

class _WindowsWidgetVisibleTile extends StatefulWidget {
  const _WindowsWidgetVisibleTile();

  @override
  State<_WindowsWidgetVisibleTile> createState() =>
      _WindowsWidgetVisibleTileState();
}

class _WindowsWidgetVisibleTileState extends State<_WindowsWidgetVisibleTile> {
  late bool _visible;
  bool _busy = false;

  DatabaseHelper get _db => Get.find<DatabaseHelper>(tag: 'db');

  @override
  void initState() {
    super.initState();
    _visible = _db.getWindowsWidgetVisible();
    unawaited(_loadNativeValue());
  }

  Future<void> _loadNativeValue() async {
    final value = await WindowsStartupService.readWidgetVisible();
    if (value == null) return;
    await _db.setWindowsWidgetVisible(value);
    if (mounted) setState(() => _visible = value);
  }

  Future<void> _setVisible(bool visible) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (visible) {
        await DesktopWidgetService.showWidget();
      } else {
        await DesktopWidgetService.hideWidget();
      }
      if (mounted) setState(() => _visible = visible);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoListTile(
        title: const Text('显示桌面日程挂件'),
        subtitle: const Text('展示今天、明天的课程和近期全部待办'),
        trailing: CupertinoSwitch(
          value: _visible,
          onChanged: _busy ? null : _setVisible,
        ),
        onTap: _busy ? null : () => _setVisible(!_visible),
      );
}

class _WindowsCloseBehaviorTile extends StatefulWidget {
  const _WindowsCloseBehaviorTile();

  @override
  State<_WindowsCloseBehaviorTile> createState() =>
      _WindowsCloseBehaviorTileState();
}

class _WindowsCloseBehaviorTileState extends State<_WindowsCloseBehaviorTile> {
  late bool _closeToTray;
  bool _busy = false;

  DatabaseHelper get _db => Get.find<DatabaseHelper>(tag: 'db');

  @override
  void initState() {
    super.initState();
    _closeToTray = _db.getWindowsCloseToTray();
    unawaited(_loadNativeValue());
  }

  Future<void> _loadNativeValue() async {
    final value = await WindowsStartupService.readCloseToTray();
    if (value == null) return;
    await _db.setWindowsCloseToTray(value);
    if (mounted) setState(() => _closeToTray = value);
  }

  Future<void> _setCloseToTray(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await WindowsStartupService.setCloseToTray(enabled);
      await _db.setWindowsCloseToTray(enabled);
      if (mounted) setState(() => _closeToTray = enabled);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoListTile(
        title: const Text('关闭按钮最小化到托盘'),
        subtitle: Text(
          _closeToTray ? '点击关闭后继续后台同步，可从托盘恢复' : '点击关闭后退出程序和挂件',
        ),
        trailing: CupertinoSwitch(
          value: _closeToTray,
          onChanged: _busy ? null : _setCloseToTray,
        ),
        onTap: _busy ? null : () => _setCloseToTray(!_closeToTray),
      );
}

class _WindowsShortcutTile extends StatelessWidget {
  const _WindowsShortcutTile();

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: const Text('创建桌面快捷方式'),
      subtitle: const Text('为当前程序位置创建 Elychron 快捷方式'),
      trailing: const BackChervonRow(),
      onTap: () async {
        try {
          final path = await WindowsStartupService.createDesktopShortcut();
          if (!context.mounted) return;
          await showCupertinoDialog<void>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: const Text('已创建快捷方式'),
              content: Text(path),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ],
            ),
          );
        } on Object catch (error) {
          if (!context.mounted) return;
          await showCupertinoDialog<void>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: const Text('创建失败'),
              content: Text(error.toString()),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('知道了'),
                ),
              ],
            ),
          );
        }
      },
    );
  }
}

class _WindowsSyncStatusTile extends StatelessWidget {
  const _WindowsSyncStatusTile();

  @override
  Widget build(BuildContext context) {
    final pta = PtaSyncService.instance;
    return AnimatedBuilder(
      animation: pta,
      builder: (context, _) => Obx(() {
        final scholar = Get.find<Rx<Scholar>>(tag: 'scholar').value;
        final tasks = Get.find<RxList<Task>>(tag: 'taskList');
        final courseTaskCount =
            tasks.where((task) => task.uid.startsWith('courses:')).length;
        final ptaTaskCount =
            tasks.where((task) => task.uid.startsWith('pta:')).length;
        final loginLabel = scholar.isLogan ? '浙大已登录' : '浙大未登录';
        return CupertinoListTile(
          title: const Text('自动同步状态'),
          subtitle: Text(
            '$loginLabel · 学在浙大 $courseTaskCount 条 · PTA $ptaTaskCount 条',
          ),
          trailing: const BackChervonRow(),
          onTap: () => _showWindowsSyncDetails(
            context,
            scholar: scholar,
            courseTaskCount: courseTaskCount,
            ptaTaskCount: ptaTaskCount,
          ),
        );
      }),
    );
  }
}

Future<void> _showWindowsSyncDetails(
  BuildContext context, {
  required Scholar scholar,
  required int courseTaskCount,
  required int ptaTaskCount,
}) async {
  final pta = PtaSyncService.instance;
  final latestAcademicUpdate = <DateTime>[
    scholar.lastUpdateTimeGrade,
    scholar.lastUpdateTimeCourse,
    scholar.lastUpdateTimeHomework,
  ].reduce((left, right) => left.isAfter(right) ? left : right);
  final academicStatus = scholar.isLogan
      ? '已登录；最近更新 ${_shortLocalTime(latestAcademicUpdate)}'
      : '未登录；请在“学业”页或设置顶部登录';
  await showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: const Text('Windows 自动同步'),
      content: Text(
        '浙大教务：$academicStatus\n'
        '负责校历、课表、考试、成绩、主修与实践。\n\n'
        '学在浙大：已导入 $courseTaskCount 条作业代办；所有新作业都会进入待办。\n\n'
        'PTA：已导入 $ptaTaskCount 条真实题集；${pta.status}。\n'
        'Cookie 只保存在本机，不保存 PTA 密码。\n\n'
        '主程序运行时每 15 分钟自动刷新；挂件快照每 15 秒更新。',
        textAlign: TextAlign.left,
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () {
            Navigator.of(dialogContext).pop();
            unawaited(_syncAllWindowsSources());
          },
          child: const Text('立即同步全部'),
        ),
      ],
    ),
  );
}

Future<void> _syncAllWindowsSources() async {
  if (Get.isRegistered<Rx<Scholar>>(tag: 'scholar')) {
    final scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
    if (scholar.value.username?.isNotEmpty == true &&
        scholar.value.password?.isNotEmpty == true) {
      await scholar.value.refresh(onPartialUpdate: scholar.refresh);
      scholar.refresh();
    }
  }
  await PtaSyncService.instance.syncNow();
  await DesktopWidgetService.publishNow();
}

String _shortLocalTime(DateTime value) {
  if (value.year <= 2001) return '尚未成功';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

/// 待办提醒方式 / 默认提前量 / 闹钟配色
List<Widget> modReminderTiles(
  BuildContext context,
  OptionController optionController,
) =>
    [
      CupertinoListTile(
        title: const Text('待办提醒方式'),
        subtitle: const Text('通知：横幅弹出+响铃；闹钟：全屏响铃，可延迟或划掉'),
        trailing: Obx(() => CupertinoSlidingSegmentedControl<int>(
              children: const {
                0: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('通知')),
                1: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text('闹钟')),
              },
              groupValue: optionController.reminderMode.value,
              onValueChanged: (value) {
                if (value != null) {
                  optionController.setReminderMode(value);
                }
              },
            )),
      ),
      // ===== P1：默认提醒提前量 =====
      // 活动锚「开始」、截止锚「截止」，各自再提前这么多；提醒型就是那一刻。
      const _ReminderLeadTile(),
      // ===== P3：专注参数 + 休息提醒 =====
      const _FocusParamTile(),
      const _FocusRestNotifyTile(),
      // ===== P4：专注记录 / 统计 =====
      CupertinoListTile(
        title: const Text('专注记录'),
        subtitle: const Text('今天 / 本周 / 本月时长、最近七天、按任务分布'),
        trailing: const BackChervonRow(),
        onTap: () async {
          await Navigator.of(context, rootNavigator: true).push(
            CupertinoPageRoute<void>(
              builder: (BuildContext context) => const FocusStatsPage(),
            ),
          );
        },
      ),
      CupertinoListTile(
        title: const Text('闹钟可靠性'),
        subtitle: const Text('全屏闹钟授权、锁屏弹出、电池白名单，一项项查'),
        trailing: const BackChervonRow(),
        onTap: () => showAlarmReliabilityDialog(context),
      ),
      CupertinoListTile(
        title: const Text('闹钟配色'),
        subtitle: const Text('浅色 + 毛玻璃，仅影响闹钟页'),
        trailing: const BackChervonRow(),
        onTap: () => showAlarmThemePicker(
          context,
          onChanged: () {},
        ),
      ),
    ];

/// 「默认提醒提前量」这一行：点开选一个值，存进 optionsBox。
class _ReminderLeadTile extends StatefulWidget {
  const _ReminderLeadTile();

  @override
  State<_ReminderLeadTile> createState() => _ReminderLeadTileState();
}

class _ReminderLeadTileState extends State<_ReminderLeadTile> {
  /// 可选的提前量（分钟）。0 = 准时，1440 = 提前一天。
  static const List<int> _options = [0, 5, 10, 15, 30, 60, 120, 1440];

  DatabaseHelper? get _db {
    if (!Get.isRegistered<DatabaseHelper>(tag: 'db')) return null;
    return Get.find<DatabaseHelper>(tag: 'db');
  }

  int get _minutes => _db?.getReminderLeadMinutes() ?? 30;

  static String leadLabel(int minutes) {
    if (minutes <= 0) return '准时';
    if (minutes % 1440 == 0) return '提前 ${minutes ~/ 1440} 天';
    if (minutes % 60 == 0) return '提前 ${minutes ~/ 60} 小时';
    return '提前 $minutes 分钟';
  }

  Future<void> _pick() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        title: const Text('默认提前多久提醒'),
        message: const Text('活动按「开始前」算，截止按「截止前」算；提醒型不受影响。'),
        actions: _options
            .map((minutes) => CupertinoActionSheetAction(
                  onPressed: () {
                    _db?.setReminderLeadMinutes(minutes);
                    Navigator.of(context).pop();
                    if (mounted) setState(() {});
                  },
                  child: Text(leadLabel(minutes)),
                ))
            .toList(),
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: const Text('默认提醒提前量'),
      subtitle: Text('新建活动/截止时默认 ${leadLabel(_minutes)} 提醒'),
      trailing: BackChervonRow(child: Text(leadLabel(_minutes))),
      onTap: _pick,
    );
  }
}

/// 数据（导出 / 导入）
Widget modDataSection(
  BuildContext context, {
  required TextStyle? headerStyle,
  required EdgeInsetsGeometry margin,
}) =>
    SliverToBoxAdapter(
        child: CupertinoListSection.insetGrouped(
            additionalDividerMargin: 2,
            margin: margin,
            header: Container(
                padding: const EdgeInsets.only(left: 16),
                child: Text('数据', style: headerStyle)),
            children: <CupertinoListTile>[
          // 「局域网同步」（多端协同）尚未完工，公开发布这版先不开放入口。
          // 代码与网页面板都还在 `lib/mod/lan_*.dart` 里，改回 true 即可恢复。
          if (kLanSyncEnabled) ...[
            CupertinoListTile(
              title: const Text('局域网同步'),
              subtitle: const Text('同一 Wi-Fi 下用电脑浏览器看待办、改待办，无需账号'),
              trailing: const BackChervonRow(),
              onTap: () async {
                await Navigator.of(context, rootNavigator: true).push(
                  CupertinoPageRoute<void>(
                    builder: (BuildContext context) => const LanSyncPage(),
                  ),
                );
              },
            ),
          ],
          CupertinoListTile(
            title: const Text('导出数据'),
            subtitle: const Text('导出为 JSON 文件，可自己保存或传到电脑'),
            trailing: const BackChervonRow(),
            onTap: () => modExportData(context),
          ),
          CupertinoListTile(
            title: const Text('导入数据'),
            subtitle: const Text('从 JSON 文件合并（按 uid 比对，新的生效）'),
            trailing: const BackChervonRow(),
            onTap: () => modImportData(context),
          ),
          // 一键把「机型 / 系统 / 版本 + 脱敏日志 + 反馈模板」复制到剪贴板。
          // 目的是让反馈发生在 QQ 群、论坛帖这类没门槛的地方时，也能说清现场。
          CupertinoListTile(
            title: const Text('复制反馈信息'),
            subtitle: const Text('机型、系统、版本 + 脱敏日志，直接粘到反馈渠道'),
            trailing: const BackChervonRow(),
            onTap: () => modCopyFeedback(context),
          ),
        ]));

/// ===== P3：专注参数（工作 / 休息分钟数）=====
///
/// 默认 60 / 15（用户拍板）。改动只影响**下一次**开始专注，
/// 正在跑的那次会保留它自己的参数。
class _FocusParamTile extends StatefulWidget {
  const _FocusParamTile();

  @override
  State<_FocusParamTile> createState() => _FocusParamTileState();
}

class _FocusParamTileState extends State<_FocusParamTile> {
  static const List<int> _workOptions = [15, 25, 30, 45, 60, 90, 120];
  static const List<int> _restOptions = [0, 5, 10, 15, 20, 30];

  DatabaseHelper? get _db {
    if (!Get.isRegistered<DatabaseHelper>(tag: 'db')) return null;
    return Get.find<DatabaseHelper>(tag: 'db');
  }

  int get _work => _db?.getFocusWorkMinutes() ?? 60;
  int get _rest => _db?.getFocusRestMinutes() ?? 15;

  static String label(int minutes) {
    if (minutes <= 0) return '不休息';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时';
    return '$minutes 分钟';
  }

  Future<void> _pick({required bool isWork}) async {
    final options = isWork ? _workOptions : _restOptions;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        title: Text(isWork ? '一段专注多久' : '每轮休息多久'),
        message:
            Text(isWork ? '默认 60 分钟。到点会自动进入休息。' : '默认 15 分钟。想连着干可以把休息设成「不休息」。'),
        actions: options
            .map((minutes) => CupertinoActionSheetAction(
                  onPressed: () {
                    if (isWork) {
                      _db?.setFocusWorkMinutes(minutes);
                    } else {
                      _db?.setFocusRestMinutes(minutes);
                    }
                    Navigator.of(context).pop();
                    if (mounted) setState(() {});
                  },
                  child: Text(label(minutes)),
                ))
            .toList(),
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: const Text('专注时长'),
      subtitle: const Text('到点自动在工作 / 休息之间交替；下一次专注生效'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(48, 36),
            onPressed: () => _pick(isWork: true),
            child: Text(label(_work)),
          ),
          const Text(' / ', style: TextStyle(fontSize: 14)),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: const Size(48, 36),
            onPressed: () => _pick(isWork: false),
            child: Text(label(_rest)),
          ),
        ],
      ),
      onTap: () => _pick(isWork: true),
    );
  }
}

/// ===== P3：休息开始时提醒一句（默认开）=====
class _FocusRestNotifyTile extends StatefulWidget {
  const _FocusRestNotifyTile();

  @override
  State<_FocusRestNotifyTile> createState() => _FocusRestNotifyTileState();
}

class _FocusRestNotifyTileState extends State<_FocusRestNotifyTile> {
  DatabaseHelper? get _db {
    if (!Get.isRegistered<DatabaseHelper>(tag: 'db')) return null;
    return Get.find<DatabaseHelper>(tag: 'db');
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      title: const Text('休息时提醒我'),
      subtitle: const Text('工作段走完时弹一条通知，提醒起来走走'),
      trailing: CupertinoSwitch(
        value: _db?.getFocusRestNotify() ?? true,
        onChanged: (value) {
          _db?.setFocusRestNotify(value);
          setState(() {});
        },
      ),
    );
  }
}

/// AI 智能助手（配置 API key / 模型 / 测试连接）
Widget modAiSection(
  BuildContext context, {
  required TextStyle? headerStyle,
  required EdgeInsetsGeometry margin,
}) =>
    ValueListenableBuilder<int>(
      valueListenable: AiConfig.revision,
      builder: (BuildContext context, int _, Widget? __) => SliverToBoxAdapter(
        child: CupertinoListSection.insetGrouped(
          additionalDividerMargin: 2,
          margin: margin,
          header: Container(
              padding: const EdgeInsets.only(left: 16),
              child: Text('智能', style: headerStyle)),
          children: <CupertinoListTile>[
            CupertinoListTile(
              title: const Text('AI 智能助手'),
              subtitle: Text(
                AiConfig.isReady
                    ? '已启用 · ${AiConfig.model}'
                    : '默认关闭；填自己的 DeepSeek key 后可用',
              ),
              trailing: const BackChervonRow(),
              onTap: () async {
                await AiConfig.load();
                if (!context.mounted) return;
                await Navigator.of(context, rootNavigator: true).push(
                  CupertinoPageRoute<void>(
                    builder: (BuildContext context) => const AiSettingsPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
