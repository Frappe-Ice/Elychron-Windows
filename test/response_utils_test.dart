import 'dart:io';

import 'package:celechron/http/zjuServices/response_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('标准认证状态码会被识别', () {
    expect(
        statusIndicatesAuthenticationFailure(HttpStatus.unauthorized), isTrue);
    expect(statusIndicatesAuthenticationFailure(HttpStatus.forbidden), isTrue);
    expect(statusIndicatesAuthenticationFailure(901), isTrue);
  });

  test('ZDBK 自定义 921 可由调用方标记为会话失效', () {
    expect(statusIndicatesAuthenticationFailure(921), isFalse);
    expect(
      statusIndicatesAuthenticationFailure(
        921,
        additionalStatuses: const {921},
      ),
      isTrue,
    );
  });

  test('其他业务错误不会被误判成登录失效', () {
    expect(statusIndicatesAuthenticationFailure(500), isFalse);
    expect(statusIndicatesAuthenticationFailure(922), isFalse);
  });
}
