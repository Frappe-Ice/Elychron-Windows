import 'dart:async';

import 'package:celechron/services/pta_sync_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:url_launcher/url_launcher_string.dart';
import 'package:webview_windows/webview_windows.dart';

class PtaPage extends StatefulWidget {
  const PtaPage({super.key});

  @override
  State<PtaPage> createState() => _PtaPageState();
}

class _PtaPageState extends State<PtaPage> {
  final _service = PtaSyncService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_service.initialize());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        if (_service.error != null) return _buildError(context);
        final controller = _service.controller;
        if (!_service.ready || controller == null) {
          return const Center(child: CupertinoActivityIndicator(radius: 14));
        }
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 12, 8),
                child: Row(
                  children: [
                    const Icon(Icons.code_rounded),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _service.status,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      onPressed: () => unawaited(_service.syncNow()),
                      child: const Text('同步全部题集'),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      onPressed: () => unawaited(_service.reload()),
                      child: const Icon(CupertinoIcons.refresh),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Text(
                  '会话 Cookie 只保存在这台电脑的 Elychron 数据目录中；不保存 PTA 密码，不执行提交或评测。所有尚未截止的题集都会导入代办，不限一周。',
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.secondaryLabel,
                  ),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Webview(controller),
                    StreamBuilder<LoadingState>(
                      stream: controller.loadingState,
                      builder: (context, snapshot) =>
                          snapshot.data == LoadingState.loading
                              ? const Align(
                                  alignment: Alignment.topCenter,
                                  child: CupertinoActivityIndicator(),
                                )
                              : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.exclamationmark_triangle, size: 42),
              const SizedBox(height: 14),
              const Text('无法启动 PTA 内嵌页', style: TextStyle(fontSize: 20)),
              const SizedBox(height: 8),
              Text(_service.error!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              CupertinoButton.filled(
                onPressed: () => launchUrlString(PtaSyncService.dashboardUrl),
                child: const Text('在浏览器中打开 PTA'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
