import 'dart:io';

/// Windows integration that deliberately stores no account or application
/// data in the distribution directory.
final class WindowsStartupService {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValueName = 'ElychronDesktopWidget';
  static const _preferencesKey = r'HKCU\Software\Elychron\Windows';
  static const _widgetVisibleValue = 'WidgetVisible';
  static const _closeToTrayValue = 'CloseToTray';
  static const _widgetCardScaleValue = 'WidgetCardScalePercent';
  static const _widgetFontScaleValue = 'WidgetFontScalePercent';
  static const _widgetThemeValue = 'WidgetTheme';

  static String get widgetStartupCommand =>
      '"${Platform.resolvedExecutable}" --background';

  static Future<void> applyWidgetAutoStart(bool enabled) async {
    if (!Platform.isWindows) return;
    final result = enabled
        ? await Process.run(
            'reg.exe',
            [
              'add',
              _runKey,
              '/v',
              _runValueName,
              '/t',
              'REG_SZ',
              '/d',
              widgetStartupCommand,
              '/f',
            ],
            runInShell: false,
          )
        : await Process.run(
            'reg.exe',
            ['delete', _runKey, '/v', _runValueName, '/f'],
            runInShell: false,
          );
    // Deleting an already absent value is the desired end state.
    if (result.exitCode != 0 && enabled) {
      throw WindowsIntegrationException(
        '无法写入开机启动项（退出码 ${result.exitCode}）',
      );
    }
  }

  static Future<void> setWidgetVisible(bool visible) =>
      _writeBoolean(_widgetVisibleValue, visible);

  static Future<void> setCloseToTray(bool enabled) =>
      _writeBoolean(_closeToTrayValue, enabled);

  static Future<bool?> readWidgetVisible() => _readBoolean(_widgetVisibleValue);

  static Future<bool?> readCloseToTray() => _readBoolean(_closeToTrayValue);

  static Future<int> readWidgetCardScale() =>
      _readInteger(_widgetCardScaleValue, fallback: 100);

  static Future<int> readWidgetFontScale() =>
      _readInteger(_widgetFontScaleValue, fallback: 100);

  static Future<int> readWidgetTheme() =>
      _readInteger(_widgetThemeValue, fallback: 0);

  static Future<void> setWidgetCardScale(int percent) =>
      _writeInteger(_widgetCardScaleValue, percent.clamp(80, 160));

  static Future<void> setWidgetFontScale(int percent) =>
      _writeInteger(_widgetFontScaleValue, percent.clamp(80, 160));

  static Future<void> setWidgetTheme(int theme) =>
      _writeInteger(_widgetThemeValue, theme.clamp(0, 3));

  static Future<bool?> _readBoolean(String name) async {
    if (!Platform.isWindows) return null;
    final result = await Process.run(
      'reg.exe',
      ['query', _preferencesKey, '/v', name],
      runInShell: false,
    );
    if (result.exitCode != 0) return null;
    final match = RegExp(r'REG_DWORD\s+0x([0-9a-fA-F]+)')
        .firstMatch(result.stdout.toString());
    if (match == null) return null;
    return int.parse(match.group(1)!, radix: 16) != 0;
  }

  static Future<void> _writeBoolean(String name, bool enabled) async {
    if (!Platform.isWindows) return;
    final result = await Process.run(
      'reg.exe',
      [
        'add',
        _preferencesKey,
        '/v',
        name,
        '/t',
        'REG_DWORD',
        '/d',
        enabled ? '1' : '0',
        '/f',
      ],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw WindowsIntegrationException(
        '无法保存 Windows 设置（退出码 ${result.exitCode}）',
      );
    }
  }

  static Future<int> _readInteger(
    String name, {
    required int fallback,
  }) async {
    if (!Platform.isWindows) return fallback;
    final result = await Process.run(
      'reg.exe',
      ['query', _preferencesKey, '/v', name],
      runInShell: false,
    );
    if (result.exitCode != 0) return fallback;
    final match = RegExp(r'REG_DWORD\s+0x([0-9a-fA-F]+)')
        .firstMatch(result.stdout.toString());
    return match == null ? fallback : int.parse(match.group(1)!, radix: 16);
  }

  static Future<void> _writeInteger(String name, int value) async {
    if (!Platform.isWindows) return;
    final result = await Process.run(
      'reg.exe',
      [
        'add',
        _preferencesKey,
        '/v',
        name,
        '/t',
        'REG_DWORD',
        '/d',
        '$value',
        '/f',
      ],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw WindowsIntegrationException(
        '无法保存挂件外观设置（退出码 ${result.exitCode}）',
      );
    }
  }

  /// Creates a normal main-window shortcut on the current user's Desktop.
  /// PowerShell is used only as the Windows Shell COM bridge; the generated
  /// .lnk contains no credentials or per-user application data.
  static Future<String> createDesktopShortcut() async {
    if (!Platform.isWindows) {
      throw const WindowsIntegrationException('桌面快捷方式仅支持 Windows。');
    }
    final executable = _powershellLiteral(Platform.resolvedExecutable);
    final workingDirectory =
        _powershellLiteral(File(Platform.resolvedExecutable).parent.path);
    const shortcutName = 'Elychron.lnk';
    final script = "\$desktop=[Environment]::GetFolderPath('Desktop');"
        "\$path=Join-Path \$desktop '$shortcutName';"
        '\$shell=New-Object -ComObject WScript.Shell;'
        '\$shortcut=\$shell.CreateShortcut(\$path);'
        "\$shortcut.TargetPath='$executable';"
        "\$shortcut.WorkingDirectory='$workingDirectory';"
        "\$shortcut.IconLocation='$executable,0';"
        "\$shortcut.Description='Elychron Windows';"
        '\$shortcut.Save();Write-Output \$path';
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', script],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw WindowsIntegrationException(
        '创建桌面快捷方式失败（退出码 ${result.exitCode}）',
      );
    }
    return result.stdout.toString().trim();
  }

  static String _powershellLiteral(String value) => value.replaceAll("'", "''");
}

class WindowsIntegrationException implements Exception {
  const WindowsIntegrationException(this.message);

  final String message;

  @override
  String toString() => message;
}
