#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

struct MonitorDescriptor {
  HMONITOR handle;
  bool primary;
};

BOOL CALLBACK CollectMonitors(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  MONITORINFO info{sizeof(MONITORINFO)};
  if (GetMonitorInfo(monitor, &info)) {
    reinterpret_cast<std::vector<MonitorDescriptor>*>(data)->push_back(
        {monitor, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
  }
  return TRUE;
}

int MonitorCount() {
  std::vector<MonitorDescriptor> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitors,
                      reinterpret_cast<LPARAM>(&monitors));
  return std::max(1, static_cast<int>(monitors.size()));
}

int WidgetMonitorIndex(const std::vector<std::string>& arguments) {
  constexpr char prefix[] = "--desktop-widget-monitor=";
  for (const auto& argument : arguments) {
    if (argument.rfind(prefix, 0) != 0) continue;
    try {
      return std::max(0, std::stoi(argument.substr(sizeof(prefix) - 1)));
    } catch (...) {
      return 0;
    }
  }
  return 0;
}

bool HasExplicitWidgetMonitor(const std::vector<std::string>& arguments) {
  return std::any_of(arguments.begin(), arguments.end(), [](const auto& value) {
    return value.rfind("--desktop-widget-monitor=", 0) == 0;
  });
}

void LaunchAdditionalWidgetMonitors(int monitor_count) {
  wchar_t executable[MAX_PATH]{};
  if (GetModuleFileName(nullptr, executable, MAX_PATH) == 0) return;
  for (int index = 1; index < monitor_count; ++index) {
    std::wstring command = L"\"" + std::wstring(executable) +
                           L"\" --desktop-widget --desktop-widget-monitor=" +
                           std::to_wstring(index);
    STARTUPINFO startup_info{sizeof(STARTUPINFO)};
    PROCESS_INFORMATION process_info{};
    if (CreateProcess(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                      nullptr, nullptr, &startup_info, &process_info)) {
      CloseHandle(process_info.hThread);
      CloseHandle(process_info.hProcess);
    }
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  const bool close_desktop_widget =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--close-desktop-widget") != command_line_arguments.end();
  if (close_desktop_widget) {
    HANDLE stop_event = OpenEvent(EVENT_MODIFY_STATE, FALSE,
                                  L"Local\\ElychronDesktopWidgetStop");
    if (stop_event != nullptr) {
      SetEvent(stop_event);
      CloseHandle(stop_event);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  const bool desktop_widget =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--desktop-widget") != command_line_arguments.end();
  const bool background =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--background") != command_line_arguments.end();
  const int widget_monitor_index =
      WidgetMonitorIndex(command_line_arguments);
  HANDLE widget_mutex = nullptr;
  HANDLE widget_stop_event = nullptr;
  if (desktop_widget) {
    const std::wstring mutex_name =
        L"Local\\ElychronDesktopWidgetInstance." +
        std::to_wstring(widget_monitor_index);
    widget_mutex = CreateMutex(nullptr, FALSE, mutex_name.c_str());
    if (widget_mutex == nullptr || GetLastError() == ERROR_ALREADY_EXISTS) {
      if (widget_mutex != nullptr) CloseHandle(widget_mutex);
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
    widget_stop_event = CreateEvent(nullptr, TRUE, FALSE,
                                    L"Local\\ElychronDesktopWidgetStop");
    if (!HasExplicitWidgetMonitor(command_line_arguments)) {
      LaunchAdditionalWidgetMonitors(MonitorCount());
    }
  }

  HANDLE main_mutex = nullptr;
  if (!desktop_widget) {
    main_mutex = CreateMutex(nullptr, FALSE, L"Local\\ElychronMainInstance");
    if (main_mutex == nullptr || GetLastError() == ERROR_ALREADY_EXISTS) {
      HWND existing = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Elychron");
      if (existing != nullptr && !background) {
        ShowWindow(existing, SW_RESTORE);
        SetForegroundWindow(existing);
      }
      if (main_mutex != nullptr) CloseHandle(main_mutex);
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(command_line_arguments);

  FlutterWindow window(project);
  window.SetDesktopWidgetMode(desktop_widget);
  window.SetDesktopWidgetMonitor(widget_monitor_index);
  window.SetStartHidden(background);
  Win32Window::Point origin(desktop_widget ? 0 : 10,
                           desktop_widget ? 0 : 10);
  Win32Window::Size size(desktop_widget ? 280 : 1280,
                         desktop_widget ? 360 : 720);
  if (!window.Create(desktop_widget ? L"Elychron Desktop Widget" : L"Elychron",
                     origin, size)) {
    if (widget_stop_event != nullptr) CloseHandle(widget_stop_event);
    if (widget_mutex != nullptr) CloseHandle(widget_mutex);
    if (main_mutex != nullptr) CloseHandle(main_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  bool running = true;
  while (running) {
    if (desktop_widget && widget_stop_event != nullptr) {
      const DWORD wait_result = MsgWaitForMultipleObjects(
          1, &widget_stop_event, FALSE, INFINITE, QS_ALLINPUT);
      if (wait_result == WAIT_OBJECT_0) break;
      while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
          running = false;
          break;
        }
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      }
    } else if (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    } else {
      running = false;
    }
  }

  if (widget_stop_event != nullptr) CloseHandle(widget_stop_event);
  if (widget_mutex != nullptr) CloseHandle(widget_mutex);
  if (main_mutex != nullptr) CloseHandle(main_mutex);

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
