import 'package:celechron/desktop/windows_startup_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('widget startup command quotes executable and uses widget argument', () {
    expect(WindowsStartupService.widgetStartupCommand, startsWith('"'));
    expect(
      WindowsStartupService.widgetStartupCommand,
      endsWith('" --desktop-widget'),
    );
  });
}
