import 'package:celechron/utils/platform_features.dart';
import 'package:celechron/mod/login_criteria.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:celechron/model/scholar.dart';

import '../../worker/ecard_widget_messenger.dart';
import 'option_controller.dart';

class LoginForm extends StatelessWidget {
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final _optionController = Get.find<OptionController>(tag: 'optionController');
  final buttonPressed = false.obs;

  LoginForm({super.key}) {
    // Reuse whatever half of a remembered login is still available. This is
    // especially helpful when migrating from the old concurrent Windows
    // secure-storage writes, which could leave only one of the two keys.
    final scholar = Get.find<Rx<Scholar>>(tag: 'scholar').value;
    usernameController.text = scholar.username ?? '';
    passwordController.text = scholar.password ?? '';
  }

  Future<void> _submit(BuildContext context) async {
    if (buttonPressed.value) return;
    final username = usernameController.text.trim();
    final password = passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('请填写账号和密码'),
          content: const Text('请输入浙江大学统一身份认证的学号和密码。'),
          actions: [
            CupertinoDialogAction(
              child: const Text('确定'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
      );
      return;
    }

    buttonPressed.value = true;
    final scholar = Get.find<Rx<Scholar>>(tag: 'scholar');
    scholar.value
      ..username = username
      ..password = password;
    scholar.refresh();

    try {
      final result = await scholar.value.login();
      if (!LoginCriteria.succeeded(result)) {
        if (!context.mounted) return;
        final message = result
            .whereType<String>()
            .where((value) => value.trim().isNotEmpty)
            .join('\n');
        await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('登录失败'),
            content: Text(message.isEmpty ? '统一身份认证未通过，请检查账号、密码和网络。' : message),
            actions: [
              CupertinoDialogAction(
                child: const Text('确定'),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          ),
        );
        return;
      }

      // 登录成功时凭据已经由 Scholar.login 写入 Windows 安全存储。
      // 再做一次完整刷新，让学业页和待办立刻拿到最新数据。
      await scholar.value.refresh(onPartialUpdate: scholar.refresh);
      scholar.refresh();
      _optionController.pushOnGradeChange =
          PlatformFeatures.hasBackgroundRefresh;
      final hint = LoginCriteria.degradedHint(result);
      if (!context.mounted) return;
      Navigator.of(context).pop();
      if (hint.isNotEmpty) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('已登录，部分模块暂不可用'),
            content: Text(hint),
            actions: [
              CupertinoDialogAction(
                child: const Text('知道了'),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          ),
        );
      }
    } on Object catch (error) {
      if (!context.mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('登录遇到问题'),
          content: Text('$error'),
          actions: [
            CupertinoDialogAction(
              child: const Text('确定'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
      );
    } finally {
      buttonPressed.value = false;
      ECardWidgetMessenger.update();
    }
  }

  @override
  Widget build(BuildContext context) {
    var brightness = CupertinoTheme.of(context).brightness ??
        MediaQuery.of(context).platformBrightness;

    return Container(
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: CupertinoDynamicColor.resolve(
                CupertinoColors.systemGroupedBackground, context)),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 6,
          right: 6,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.only(
                    left: 16, right: 16, bottom: 8, top: 16),
                child: Text(
                  '统一身份认证登录',
                  style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    SizedBox(
                        height: 48,
                        child: CupertinoTextField(
                          controller: usernameController,
                          keyboardType: TextInputType.text,
                          autocorrect: false,
                          enableSuggestions: false,
                          prefix: Container(
                              padding: const EdgeInsets.only(left: 12),
                              child: Text('学号',
                                  style: CupertinoTheme.of(context)
                                      .textTheme
                                      .textStyle)),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: brightness == Brightness.light
                                ? CupertinoColors.systemBackground
                                : CupertinoColors.secondarySystemBackground,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        )),
                    const SizedBox(height: 16),
                    SizedBox(
                        height: 48,
                        child: CupertinoTextField(
                          controller: passwordController,
                          obscureText: true,
                          prefix: Container(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text('密码',
                                style: CupertinoTheme.of(context)
                                    .textTheme
                                    .textStyle),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: brightness == Brightness.light
                                ? CupertinoColors.systemBackground
                                : CupertinoColors.secondarySystemBackground,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        )),
                    const SizedBox(height: 16),
                    Obx(() => CupertinoButton(
                        onPressed:
                            buttonPressed.value ? null : () => _submit(context),
                        color: buttonPressed.value
                            ? CupertinoColors.inactiveGray
                            : CupertinoColors.activeBlue,
                        child: SizedBox(
                          height: 24,
                          width: 60,
                          child: Center(
                              child: buttonPressed.value
                                  ? const CupertinoActivityIndicator()
                                  : const Text('登录',
                                      style: TextStyle(
                                          color: CupertinoColors.white))),
                        ))),
                  ],
                ),
              ),
            ],
          ),
        ));
  }
}
