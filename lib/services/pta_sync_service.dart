import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:celechron/desktop/desktop_widget_service.dart';
import 'package:celechron/mod/pta_todo_sync.dart';
import 'package:celechron/services/diagnostic_log_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

final class PtaSyncService extends ChangeNotifier {
  PtaSyncService._();

  static final instance = PtaSyncService._();

  /// Only the authenticated dashboard is safe to scrape. The public
  /// /problem-sets catalogue also contains paid courses/books and must never
  /// be treated as the user's assigned work.
  static const dashboardUrl = 'https://pintia.cn/problem-sets/dashboard';
  static const refreshInterval = Duration(minutes: 5);
  static const _dashboardPollInterval = Duration(seconds: 2);
  static const _dashboardPollAttempts = 30;

  WebviewController? _controller;
  Timer? _periodicTimer;
  Timer? _settleTimer;
  StreamSubscription<String>? _urlSubscription;
  StreamSubscription<LoadingState>? _loadingSubscription;
  Future<void>? _initializing;
  Future<int>? _syncing;
  String _status = '正在准备 PTA…';
  String? _error;
  String _url = dashboardUrl;
  bool _ready = false;

  WebviewController? get controller => _controller;
  bool get ready => _ready;
  String get status => _status;
  String? get error => _error;
  String get url => _url;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!Platform.isWindows) {
      _error = 'PTA 内嵌页目前仅在 Windows 版提供。';
      notifyListeners();
      return;
    }
    try {
      final version = await WebviewController.getWebViewVersion();
      if (version == null) {
        throw const PtaSetupException('未检测到 Microsoft Edge WebView2 Runtime。');
      }
      final dataDir = await getApplicationSupportDirectory();
      try {
        await WebviewController.initializeEnvironment(
          userDataPath: '${dataDir.path}${Platform.pathSeparator}pta-webview',
        );
      } on PlatformException catch (error) {
        if (!error.message.toString().contains('initialized')) rethrow;
      }

      final webview = WebviewController();
      _controller = webview;
      await webview.initialize();
      _urlSubscription = webview.url.listen((url) {
        _url = url;
        _status = url.contains('login') ? '请在 PTA 页面完成登录' : 'PTA 已连接';
        notifyListeners();
      });
      _loadingSubscription = webview.loadingState.listen((state) {
        if (state != LoadingState.navigationCompleted) return;
        _settleTimer?.cancel();
        _settleTimer = Timer(
          const Duration(seconds: 1),
          () => unawaited(syncNow()),
        );
      });
      await webview.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      await webview.loadUrl(dashboardUrl);
      _ready = true;
      _status = 'PTA 已连接，正在读取题集…';
      _periodicTimer = Timer.periodic(
        refreshInterval,
        (_) => unawaited(_periodicRefresh()),
      );
      notifyListeners();
    } catch (error, stackTrace) {
      _error = error.toString();
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.error,
        module: 'PTA',
        operation: 'initialize',
        message: 'PTA 内嵌会话初始化失败',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
    }
  }

  Future<void> _periodicRefresh() async {
    final webview = _controller;
    if (webview == null || !_ready) return;
    if (_isDashboardUrl(_url)) {
      await webview.reload();
    }
  }

  Future<int> syncNow() => _syncing ??= _syncNow().whenComplete(() {
        _syncing = null;
      });

  Future<int> _syncNow() async {
    final webview = _controller;
    if (webview == null || !_ready) return 0;
    if (!_isDashboardUrl(_url)) {
      if (_url.contains('login')) {
        _status = '请先登录 PTA，登录状态会保存在本机';
        notifyListeners();
      }
      return 0;
    }
    try {
      if (!await _waitForDashboardContent(webview)) return 0;
      // Trigger lazy lists before collecting anchors. Preserve the user's
      // current position so a manual sync does not leave the page at the end.
      final originalOffset = await webview.executeScript('window.scrollY');
      var previousHeight = -1;
      for (var attempt = 0; attempt < 12; attempt++) {
        final heightValue =
            await webview.executeScript('document.body.scrollHeight');
        final height = heightValue is num ? heightValue.toInt() : -1;
        await webview.executeScript(
          'window.scrollTo(0, document.body.scrollHeight)',
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (height == previousHeight) break;
        previousHeight = height;
      }
      if (originalOffset is num) {
        await webview.executeScript(
          'window.scrollTo(0, ${originalOffset.toInt()})',
        );
      }
      const script = r'''
(() => {
  const results = [];
  const links = Array.from(document.querySelectorAll('a[href*="/problem-sets/"]'));
  for (const link of links) {
    let parsed;
    try { parsed = new URL(link.href, location.href); } catch (_) { continue; }
    // Card links commonly point below the set root (for example
    // /problem-sets/<id>/problems/type/7), not to the root itself.
    const match = parsed.pathname.match(/^\/problem-sets\/(\d+)(?:\/|$)/);
    if (!match) continue;
    let node = link;
    let best = '';
    for (let depth = 0; node && depth < 10; depth++, node = node.parentElement) {
      const text = (node.innerText || '').trim();
      if (text.length < 8 || text.length > 1800) continue;
      const hasDate = /20\d{2}[\-/年]\d{1,2}/.test(text);
      if (!hasDate) continue;
      const scopeIds = new Set([match[1]]);
      for (const nested of node.querySelectorAll('a[href*="/problem-sets/"]')) {
        try {
          const nestedMatch = new URL(nested.href, location.href).pathname
            .match(/^\/problem-sets\/(\d+)(?:\/|$)/);
          if (nestedMatch) scopeIds.add(nestedMatch[1]);
        } catch (_) {}
      }
      // We have climbed out of this card into a list containing neighbours.
      // Stop here so status text from a real assignment can never validate a
      // catalogue/recommendation card beside it.
      if (scopeIds.size > 1) break;
      const hasAvailability = /已开放|未开放|将于.{0,32}开放/.test(text);
      const hasDeadline = /关闭|截止|结束/.test(text);
      if (hasAvailability && hasDeadline) {
        best = text;
        break;
      }
    }
    if (!best) continue;
    results.push({
      id: match[1],
      url: parsed.origin + parsed.pathname,
      title: (link.innerText || link.textContent || '').trim(),
      text: best
    });
  }
  return JSON.stringify(results);
})()
''';
      final encoded = await webview.executeScript(script);
      final decoded = encoded is String ? jsonDecode(encoded) : encoded;
      final rawItems =
          decoded is List ? decoded.cast<Object?>() : const <Object?>[];
      final problemSets = PtaProblemSet.fromDashboardItems(
        rawItems,
        now: DateTime.now(),
      );
      DiagnosticLogService.instance.record(
        module: 'PTA',
        operation: 'candidateSummary',
        requestUri: Uri.tryParse(_url),
        message: '候选卡片 ${rawItems.length} 个；确认已布置且未截止 ${problemSets.length} 个',
      );
      final imported = await syncPtaProblemSetsIntoTaskList(problemSets);
      await DesktopWidgetService.publishNow();
      _status = problemSets.isEmpty
          ? '未发现尚未截止的已布置 PTA 题集'
          : '已读取 ${problemSets.length} 个 PTA 题集${imported > 0 ? '，新增 $imported 条代办' : ''}';
      DiagnosticLogService.instance.record(
        module: 'PTA',
        operation: 'sync',
        requestUri: Uri.tryParse(_url),
        message: '读取 ${problemSets.length} 个题集，新增 $imported 条代办',
      );
      notifyListeners();
      return imported;
    } catch (error, stackTrace) {
      _status = 'PTA 读取失败，可登录后点击“同步题集”重试';
      DiagnosticLogService.instance.record(
        level: CelechronLogLevel.warning,
        module: 'PTA',
        operation: 'sync',
        requestUri: Uri.tryParse(_url),
        message: 'PTA 页面读取失败',
        error: error,
        stackTrace: stackTrace,
      );
      notifyListeners();
      return 0;
    }
  }

  Future<bool> _waitForDashboardContent(WebviewController webview) async {
    for (var attempt = 1; attempt <= _dashboardPollAttempts; attempt++) {
      if (!_isDashboardUrl(_url)) return false;
      final encoded = await webview.executeScript(r'''
(() => JSON.stringify({
  state: document.readyState,
  textLength: (document.body && document.body.innerText || '').trim().length,
  waiting: /请耐心等待页面加载完成|检查网络连接|访问备用线路/.test(
    document.body && document.body.innerText || ''
  ),
  emptyState: /暂无.{0,12}题集|没有.{0,12}题集|暂未.{0,12}题集/.test(
    document.body && document.body.innerText || ''
  ),
  problemLinks: Array.from(document.querySelectorAll('a[href*="/problem-sets/"]'))
    .filter(link => {
      try {
        return /^\/problem-sets\/\d+(?:\/|$)/.test(
          new URL(link.href, location.href).pathname
        );
      } catch (_) {
        return false;
      }
    }).length
}))()
''');
      final decoded = encoded is String ? jsonDecode(encoded) : encoded;
      final state = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
      final waiting = state['waiting'] == true;
      final emptyState = state['emptyState'] == true;
      final problemLinks = (state['problemLinks'] as num?)?.toInt() ?? 0;
      final documentComplete = state['state'] == 'complete';
      // Navigation/footer text can become long before the SPA has injected
      // its cards. Only a real set link or an explicit empty-state message is
      // proof that dashboard data finished loading.
      if (!waiting && documentComplete && (problemLinks > 0 || emptyState)) {
        return true;
      }
      _status = 'PTA 页面加载较慢，正在等待（$attempt/$_dashboardPollAttempts）';
      notifyListeners();
      await Future<void>.delayed(_dashboardPollInterval);
    }
    _status = 'PTA 页面仍未加载完成，将在下次自动重试';
    DiagnosticLogService.instance.record(
      level: CelechronLogLevel.warning,
      module: 'PTA',
      operation: 'waitForDashboard',
      requestUri: Uri.tryParse(_url),
      message: '等待 PTA dashboard 超时；未把加载页误判为空题集',
    );
    notifyListeners();
    return false;
  }

  bool _isDashboardUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.host == 'pintia.cn' || uri.host.endsWith('.pintia.cn')) &&
        uri.path == '/problem-sets/dashboard';
  }

  Future<void> reload() async => _controller?.reload();

  @visibleForTesting
  void disposeForTesting() {
    _periodicTimer?.cancel();
    _settleTimer?.cancel();
    unawaited(_urlSubscription?.cancel());
    unawaited(_loadingSubscription?.cancel());
    _controller?.dispose();
  }
}

class PtaSetupException implements Exception {
  const PtaSetupException(this.message);

  final String message;

  @override
  String toString() => message;
}
