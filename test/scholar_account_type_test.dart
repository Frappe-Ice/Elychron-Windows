import 'package:celechron/model/scholar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing username is treated as an unknown undergraduate account', () {
    expect(Scholar().isGrs, isFalse);
  });

  test('account type follows the Zhejiang University student number', () {
    final undergraduate = Scholar()..username = '3200000000';
    final graduate = Scholar()..username = '1234567890';

    expect(undergraduate.isGrs, isFalse);
    expect(graduate.isGrs, isTrue);
  });
}
