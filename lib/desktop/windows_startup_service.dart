import 'dart:io';

/// Windows integration that deliberately stores no account or application
/// data in the distribution directory.
final class WindowsStartupService {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValueName = 'ElychronDesktopWidget';

  static String get widgetStartupCommand =>
      '"${Platform.resolvedExecutable}" --desktop-widget';

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
