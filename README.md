# Elychron Windows

> [!IMPORTANT]
> **这是基于 Elychron 的非官方 Windows 修改版，不是 Celechron、Elychron 上游或浙江大学的官方发布。**
> Windows 版问题请仅在[本仓库 Issues](https://github.com/Frappe-Ice/Elychron-Windows/issues)
> 反馈，请勿要求上游作者为本修改版提供支持。

## 项目身份、来源与修改声明

- **原始项目**：[Celechron/Celechron](https://github.com/Celechron/Celechron)，原项目版权归
  **nosig 及 Celechron 全体贡献者**所有。
- **直接上游**：[Elyyyyyyyyxer/Elychron](https://github.com/Elyyyyyyyyxer/Elychron)，
  是由 **Tixer** 维护的 Celechron 非官方修改版；其新增贡献的权利归相应贡献者所有。
- **本修改版**：[Frappe-Ice/Elychron-Windows](https://github.com/Frappe-Ice/Elychron-Windows)，
  由 **Frappe-Ice** 维护；本仓库新增贡献的权利归相应贡献者所有。
- **代码基线**：直接上游标签
  [`v1.4.1-elychron.1`](https://github.com/Elyyyyyyyyxer/Elychron/releases/tag/v1.4.1-elychron.1)，
  commit `b330365`。
- **修改标记**：本仓库于 **2026-10-08** 在上述基线上加入 Windows 主窗口、桌面挂件、
  开机自启动、快捷方式、浙大与 PTA 登录记忆及任务同步等修改。
- **许可证**：整个衍生作品继续遵循 **GNU GPL v3**，完整条款见 [LICENSE](LICENSE)。

本仓库及对应 Release 标签提供所发布 Windows 二进制的对应源码。任何名称、校徽、学校服务名称或
上游项目名称仅用于说明兼容性和来源，不表示原作者、上游项目或浙江大学认可、背书或维护本版本。

Elychron Windows 面向 Windows 10/11 x64，优先服务个人日常使用：在完整主窗口中管理课程、
日程和待办，同时用轻量桌面挂件展示今天与明天的安排。

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
- **桌面挂件**：每块显示器右侧各有一个固定宽度、纵向铺满的浅色透明挂件，展示今天、明天的课程和近期安排。
- **Windows 集成**：提供系统托盘菜单，可恢复主窗口、开关挂件或退出；关闭按钮可选择退出或最小化到托盘，也可从设置页创建或更新桌面快捷方式。
- **登录记忆**：浙大凭据由 Windows 安全存储保护，PTA Cookie 使用当前用户专属 WebView 配置保存。

开机自启动会在托盘启动隐藏的后台进程，不弹出主窗口。后台进程保留登录会话并每 5 分钟尝试刷新
浙大学业与 PTA 数据，挂件约 15 秒读取一次本地快照。挂件显示状态、开机启动和关闭按钮行为都会记忆；
上次关闭挂件后，下次开机不会自行显示。

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

Release 输出位于 `build/windows/x64/runner/Release/`。当前 Windows 发行包已通过 376 项自动化测试，
并经过“重新解压 → 启动主窗口 → 托盘常驻 → 启动双屏挂件”的实际验证。

Windows 设计边界与验收记录见 [`docs/WINDOWS_MVP.md`](docs/WINDOWS_MVP.md)。

## 已知边界

- 当前重点是个人可用性，尚未提供安装器、代码签名、自动更新和商店发布流程。
- 学校服务与 PTA 的实时同步取决于网站可用性、校园网络或 VPN 状态。
- 移动程序目录后，应重新运行一次主程序，并在设置页重新创建快捷方式，使启动项指向新位置。

## 许可证、再分发与免责声明

本项目遵循 [GNU General Public License Version 3](LICENSE)。你可以运行、研究、修改和再分发，
但在传播源码或二进制时，应按 GPLv3 履行相应义务，包括：

1. 保留现有版权、来源和许可证声明；
2. 显著标明你修改过作品及相应修改日期；
3. 继续以 GPLv3 许可所传播的修改作品，不附加限制接收者行使 GPL 权利的额外条款；
4. 随二进制提供完整的对应源码，或按 GPLv3 允许的方式确保接收者能够取得对应源码；
5. 在适用时提供安装和运行修改版本所需的信息。

本程序按“现状”提供，不附带任何明示或默示担保，包括但不限于适销性或特定用途适用性担保；
在适用法律允许的范围内，版权人和贡献者不对使用或无法使用本程序造成的损失承担责任。

以上是项目声明而非法律意见；再分发前请阅读完整 [GPLv3 条款](LICENSE)。
