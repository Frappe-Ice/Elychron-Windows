import 'package:celechron/desktop/windows_startup_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup command quotes executable and uses hidden background mode', () {
    expect(WindowsStartupService.widgetStartupCommand, startsWith('"'));
    expect(
      WindowsStartupService.widgetStartupCommand,
      endsWith('" --background'),
    );
  });
}
