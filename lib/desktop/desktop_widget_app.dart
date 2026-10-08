import 'dart:async';

import 'package:celechron/desktop/desktop_widget_service.dart';
import 'package:celechron/desktop/desktop_widget_snapshot.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Material, Colors;
import 'package:intl/intl.dart';

class DesktopWidgetApp extends StatelessWidget {
  const DesktopWidgetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoApp(
      debugShowCheckedModeBanner: false,
      theme: CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: Color(0xFFD95783),
        scaffoldBackgroundColor: Color(0x00000000),
        barBackgroundColor: Color(0x00000000),
      ),
      color: Color(0x00000000),
      home: DesktopAgendaWidget(),
    );
  }
}

class DesktopAgendaWidget extends StatefulWidget {
  const DesktopAgendaWidget({super.key});

  @override
  State<DesktopAgendaWidget> createState() => _DesktopAgendaWidgetState();
}

class _DesktopAgendaWidgetState extends State<DesktopAgendaWidget> {
  DesktopWidgetSnapshot? _snapshot;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final snapshot = await DesktopWidgetService.readSnapshot();
    if (mounted) setState(() => _snapshot = snapshot);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final now = DateTime.now();
    final items = snapshot?.items ?? const <DesktopAgendaItem>[];
    final scheduleItems = items
        .where((item) =>
            item.kind == DesktopAgendaKind.course ||
            item.kind == DesktopAgendaKind.exam ||
            item.kind == DesktopAgendaKind.event)
        .toList(growable: false);
    final todoItems = items
        .where((item) =>
            item.kind == DesktopAgendaKind.deadline ||
            item.kind == DesktopAgendaKind.reminder)
        .toList(growable: false);
    return CupertinoPageScaffold(
      backgroundColor: const Color(0x00000000),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 9, 11, 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          DateFormat('M月d日 EEEE', 'zh').format(now),
                          style: const TextStyle(
                            color: Color(0xFF656B76),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          '今天与近期',
                          style: TextStyle(
                            color: Color(0xFF565D69),
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${scheduleItems.length} 课程 · ${todoItems.length} 代办',
                    style: const TextStyle(
                      color: Color(0xFF656B76),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    _AgendaSection(
                      title: '今日课程与日程',
                      emptyText: '今天没有课程或日程',
                      items: scheduleItems,
                      now: now,
                    ),
                    const SizedBox(height: 7),
                    _AgendaSection(
                      title: '近期作业与代办',
                      emptyText:
                          snapshot == null ? '等待 Elychron 同步' : '未来 7 天暂无作业或代办',
                      items: todoItems,
                      now: now,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                snapshot == null
                    ? '等待 Elychron 同步'
                    : '更新于 ${DateFormat('HH:mm').format(snapshot.generatedAt)}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF8B8B94),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgendaRow extends StatelessWidget {
  const _AgendaRow({required this.item, required this.now});

  final DesktopAgendaItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final active = !now.isBefore(item.startTime) && now.isBefore(item.endTime);
    final color = item.urgent
        ? CupertinoColors.systemRed
        : active
            ? const Color(0xFFD95783)
            : _kindColor(item.kind);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: active ? const Color(0xE8F9E8EF) : const Color(0xE8F5F6F8),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              child: Text(
                _timeLabel(item.startTime, now),
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF3E4652),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_detailText(item).isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      _detailText(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF626A76),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _kindColor(DesktopAgendaKind kind) => switch (kind) {
        DesktopAgendaKind.course => const Color(0xFF3B82C4),
        DesktopAgendaKind.exam => const Color(0xFFD17A21),
        DesktopAgendaKind.event => const Color(0xFF7656B8),
        DesktopAgendaKind.deadline => const Color(0xFFD95783),
        DesktopAgendaKind.reminder => const Color(0xFF29977A),
      };

  static String _timeLabel(DateTime time, DateTime now) {
    final sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    return DateFormat(sameDay ? 'HH:mm' : 'M/d').format(time);
  }

  static String _detailText(DesktopAgendaItem item) {
    final location = item.location.trim();
    final category = switch (item.kind) {
      DesktopAgendaKind.course => '课程',
      DesktopAgendaKind.exam => '考试',
      DesktopAgendaKind.event => '日程',
      DesktopAgendaKind.deadline =>
        item.id.startsWith('task:courses:') ? '学业作业' : '待办截止',
      DesktopAgendaKind.reminder => '提醒',
    };
    return location.isEmpty ? category : '$category · $location';
  }
}

class _AgendaSection extends StatelessWidget {
  const _AgendaSection({
    required this.title,
    required this.emptyText,
    required this.items,
    required this.now,
  });

  final String title;
  final String emptyText;
  final List<DesktopAgendaItem> items;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$title  ${items.length}',
          style: const TextStyle(
            color: Color(0xFF626A76),
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        if (items.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xDDF2F3F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              emptyText,
              style: const TextStyle(
                color: Color(0xFF8B8B94),
                fontSize: 10,
              ),
            ),
          )
        else
          for (var index = 0; index < items.length; index++) ...[
            if (index > 0) const SizedBox(height: 4),
            _AgendaRow(item: items[index], now: now),
          ],
      ],
    );
  }
}
