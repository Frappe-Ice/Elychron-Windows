# Elychron Windows

面向 Windows 10/11 x64 的 Elychron 桌面版。项目以
[`v1.4.1-elychron.1`](https://github.com/Elyyyyyyyyxer/Elychron/releases/tag/v1.4.1-elychron.1)
为基础，优先服务个人日常使用：在完整主窗口中管理课程、日程和待办，同时用轻量桌面挂件
展示当天安排。

> 这是非官方修改版，与 Celechron 官方项目及浙江大学无隶属关系。

## 下载

前往 [Releases](https://github.com/Frappe-Ice/Elychron-Windows/releases/latest) 下载
`Elychron-Windows-x64-*.zip`。

1. 完整解压 ZIP，不要直接在压缩软件中运行。
2. 双击 `Elychron.exe`。
3. 在“学业”页登录浙江大学统一身份认证；在“PTA”页完成 PTA 登录。
4. 在“设置 → Windows”中管理桌面挂件、开机自启动、快捷方式和数据同步。

当前版本为便携版，没有安装器或 Microsoft Store 包。PTA 页面依赖 Microsoft Edge
WebView2 Runtime，现代 Windows 通常已经自带。

## Windows 版能力

- **完整主窗口**：日程、待办、专注、学业、PTA 和设置均可通过桌面侧边栏进入。
- **完整待办系统**：保留活动、截止、提醒、备忘四种时间语义，以及子待办、标签、优先级、
  附件和评论等能力。
- **学业同步**：同步课表、成绩、考试及“学在浙大”作业；新发现的全部作业会自动进入待办，
  不再只导入近一周任务。
- **PTA 同步**：使用持久化 WebView 登录状态抓取已布置题集，并通过严格卡片范围与状态校验，
  避免把课程、图书或商品加入待办。
- **桌面挂件**：每块显示器右侧各有一个固定宽度、纵向铺满的浅色透明挂件，展示课程和近期安排。
- **Windows 集成**：挂件可随 Windows 登录自动启动；可从设置页创建或更新桌面快捷方式。
- **登录记忆**：浙大凭据由 Windows 安全存储保护，PTA Cookie 使用当前用户专属 WebView 配置保存。

开机自启动只打开桌面挂件，不弹出主窗口。挂件可以继续显示最近一次快照；需要抓取网站最新内容时，
请打开主窗口或在“设置 → Windows”中执行同步。

## 隐私与本地数据

发行包不预置任何个人信息，也不包含账号、密码、Cookie、课表、待办、诊断日志或本机路径。

首次运行后产生的数据保存在当前 Windows 用户自己的 AppData 中，不写入程序目录：

- 浙大账号凭据：Windows 安全存储；
- PTA 登录状态：应用专属 WebView 配置；
- 课表、待办和挂件快照：应用本地数据目录。

因此复制 Release ZIP 不会同时复制登录状态。详细检查原则见
[`packaging/PRIVACY-CHECKLIST.txt`](packaging/PRIVACY-CHECKLIST.txt)。

## 构建与测试

需要 Flutter Windows 开发环境、Visual Studio C++ 桌面工作负载和 WebView2 Runtime：

```powershell
flutter pub get
flutter test
flutter build windows --release
```

Release 输出位于 `build/windows/x64/runner/Release/`。当前 Windows 发行包已通过 375 项自动化测试，
并经过“重新解压 → 启动主窗口 → 启动双屏挂件”的实际验证。

Windows 设计边界与验收记录见 [`docs/WINDOWS_MVP.md`](docs/WINDOWS_MVP.md)。

## 已知边界

- 当前重点是个人可用性，尚未提供安装器、代码签名、自动更新和商店发布流程。
- 学校服务与 PTA 的实时同步取决于网站可用性、校园网络或 VPN 状态。
- 移动程序目录后，应重新运行一次主程序，并在设置页重新创建快捷方式，使启动项指向新位置。

## 上游与许可证

本项目保留原项目提交历史，并基于
[Elyyyyyyyyxer/Elychron](https://github.com/Elyyyyyyyyxer/Elychron) 的
`v1.4.1-elychron.1` 开发；更上游为
[Celechron/Celechron](https://github.com/Celechron/Celechron)。感谢所有原作者与贡献者。

项目继续遵循 [GPL-3.0](LICENSE)。分发修改后的二进制时，应同时提供对应源码并保留版权和许可证声明。
