#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cwchar>
#include <vector>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

enum DesktopWidgetCornerPreference {
  kDesktopWidgetRoundCorners = 2,
};

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

constexpr UINT kSpawnWorkerMessage = 0x052C;
constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayOpenCommand = 41001;
constexpr UINT kTrayToggleWidgetCommand = 41002;
constexpr UINT kTrayExitCommand = 41003;
constexpr const wchar_t kElychronPreferencesKey[] =
    L"Software\\Elychron\\Windows";

bool ReadElychronBoolean(const wchar_t* name, bool default_value) {
  DWORD value = default_value ? 1 : 0;
  DWORD size = sizeof(value);
  if (RegGetValue(HKEY_CURRENT_USER, kElychronPreferencesKey, name,
                  RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) {
    return default_value;
  }
  return value != 0;
}

void WriteElychronBoolean(const wchar_t* name, bool value) {
  HKEY key = nullptr;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, kElychronPreferencesKey, 0, nullptr, 0,
                     KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  const DWORD stored = value ? 1 : 0;
  RegSetValueEx(key, name, 0, REG_DWORD,
                reinterpret_cast<const BYTE*>(&stored), sizeof(stored));
  RegCloseKey(key);
}

void StartDesktopWidgets() {
  wchar_t executable[MAX_PATH]{};
  if (GetModuleFileName(nullptr, executable, MAX_PATH) == 0) return;
  std::wstring command =
      L"\"" + std::wstring(executable) + L"\" --desktop-widget";
  STARTUPINFO startup_info{sizeof(STARTUPINFO)};
  PROCESS_INFORMATION process_info{};
  if (CreateProcess(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                    nullptr, nullptr, &startup_info, &process_info)) {
    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
  }
}

void StopDesktopWidgets() {
  HANDLE stop_event =
      OpenEvent(EVENT_MODIFY_STATE, FALSE, L"Local\\ElychronDesktopWidgetStop");
  if (stop_event == nullptr) return;
  SetEvent(stop_event);
  CloseHandle(stop_event);
}

struct DesktopMonitorDescriptor {
  HMONITOR handle;
  bool primary;
};

BOOL CALLBACK CollectDesktopMonitors(HMONITOR monitor,
                                     HDC,
                                     LPRECT,
                                     LPARAM data) {
  MONITORINFO info{sizeof(MONITORINFO)};
  if (GetMonitorInfo(monitor, &info)) {
    reinterpret_cast<std::vector<DesktopMonitorDescriptor>*>(data)->push_back(
        {monitor, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
  }
  return TRUE;
}

HMONITOR DesktopMonitorAtIndex(int requested_index) {
  std::vector<DesktopMonitorDescriptor> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectDesktopMonitors,
                      reinterpret_cast<LPARAM>(&monitors));
  if (monitors.empty()) {
    return MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  }
  std::stable_sort(monitors.begin(), monitors.end(),
                   [](const auto& left, const auto& right) {
                     return left.primary && !right.primary;
                   });
  const int index =
      std::clamp(requested_index, 0, static_cast<int>(monitors.size()) - 1);
  return monitors[index].handle;
}

enum AccentState {
  kAccentDisabled = 0,
  kAccentEnableTransparentGradient = 2,
};

struct AccentPolicy {
  int state;
  int flags;
  int color;
  int animation_id;
};

struct WindowCompositionAttributeData {
  int attribute;
  PVOID data;
  ULONG data_size;
};

using SetWindowCompositionAttribute =
    BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

void EnableTransparentComposition(HWND window) {
  HMODULE user32 = LoadLibrary(L"user32.dll");
  if (user32 == nullptr) return;
  auto set_window_composition_attribute =
      reinterpret_cast<SetWindowCompositionAttribute>(
          GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (set_window_composition_attribute != nullptr) {
    AccentPolicy policy{kAccentEnableTransparentGradient, 2, 0, 0};
    WindowCompositionAttributeData data{19, &policy, sizeof(policy)};
    set_window_composition_attribute(window, &data);
  }
  FreeLibrary(user32);
}

BOOL CALLBACK FindWallpaperEngineWindow(HWND window, LPARAM lparam) {
  wchar_t class_name[128]{};
  if (GetClassName(window, class_name, 128) == 0) {
    return TRUE;
  }
  // Wallpaper Engine uses WPEDesktopDX11Window today and may select another
  // rendering backend in the future. Matching the stable prefix covers both.
  if (wcsncmp(class_name, L"WPEDesktop", 10) != 0) {
    return TRUE;
  }
  HWND host = GetParent(window);
  if (host != nullptr) {
    *reinterpret_cast<HWND*>(lparam) = host;
    return FALSE;
  }
  return TRUE;
}

HWND WallpaperEngineHost() {
  HWND host = nullptr;
  EnumChildWindows(GetDesktopWindow(), FindWallpaperEngineWindow,
                   reinterpret_cast<LPARAM>(&host));
  return host;
}

BOOL CALLBACK FindDesktopWorker(HWND top_level, LPARAM lparam) {
  if (FindWindowEx(top_level, nullptr, L"SHELLDLL_DefView", nullptr) ==
      nullptr) {
    return TRUE;
  }
  auto worker = FindWindowEx(nullptr, top_level, L"WorkerW", nullptr);
  // Recent Windows 11 Explorer builds do not always create the traditional
  // empty WorkerW sibling. In that layout, use the icon host itself instead
  // of returning null and accidentally placing the widget behind the
  // wallpaper.
  *reinterpret_cast<HWND*>(lparam) = worker != nullptr ? worker : top_level;
  return FALSE;
}

HWND DesktopWorkerWindow() {
  // When Wallpaper Engine is active, sharing its WorkerW host and placing the
  // widget above the wallpaper child keeps the widget visible without turning
  // it into an always-on-top application window.
  HWND wallpaper_engine_host = WallpaperEngineHost();
  if (wallpaper_engine_host != nullptr) {
    return wallpaper_engine_host;
  }

  HWND progman = FindWindow(L"Progman", nullptr);
  if (progman != nullptr) {
    DWORD_PTR unused = 0;
    SendMessageTimeout(progman, kSpawnWorkerMessage, 0, 0, SMTO_NORMAL, 1000,
                       &unused);
    SendMessageTimeout(progman, kSpawnWorkerMessage, 0xD, 0, SMTO_NORMAL,
                       1000, &unused);
    SendMessageTimeout(progman, kSpawnWorkerMessage, 0xD, 1, SMTO_NORMAL,
                       1000, &unused);
  }
  HWND worker = nullptr;
  EnumWindows(FindDesktopWorker, reinterpret_cast<LPARAM>(&worker));
  return worker;
}

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

constexpr int kDesktopWidgetLogicalWidth = 280;
constexpr int kDesktopWidgetLogicalMargin = 12;

RECT DesktopWidgetBounds(HMONITOR monitor, UINT dpi) {
  MONITORINFO monitor_info{sizeof(MONITORINFO)};
  if (!GetMonitorInfo(monitor, &monitor_info)) {
    return RECT{0, 0, kDesktopWidgetLogicalWidth, 360};
  }
  const RECT work = monitor_info.rcWork;
  const double scale_factor = dpi / 96.0;
  const int margin = Scale(kDesktopWidgetLogicalMargin, scale_factor);
  const int work_width = std::max(1L, work.right - work.left);
  const int work_height = std::max(1L, work.bottom - work.top);
  // Clamp in the target monitor's physical coordinate space. This matters
  // when a smaller secondary display sits immediately beside a high-DPI main
  // display: a width calculated in the main display's scale can otherwise
  // cross the shared edge and cover the neighbouring screen.
  const int width = std::clamp(
      Scale(kDesktopWidgetLogicalWidth, scale_factor), 120,
      std::max(120, work_width - margin * 2));
  const int height = std::max(240, work_height - margin * 2);
  const int right = work.right - margin;
  const int bottom = std::min(work.bottom - margin, work.top + margin + height);
  const int left = std::max(static_cast<int>(work.left) + margin,
                            right - width);
  return RECT{left, work.top + margin, right, bottom};
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = desktop_widget_mode_
                         ? DesktopMonitorAtIndex(desktop_widget_monitor_index_)
                         : MonitorFromPoint(target_point,
                                            MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  RECT widget_bounds{};
  if (desktop_widget_mode_) {
    widget_bounds = DesktopWidgetBounds(monitor, dpi);
  }

  // WS_DISABLED is intentional for the display-only widget: disabled
  // top-level windows are skipped by Windows hit testing even when the window
  // belongs to a different process than Explorer. HTTRANSPARENT alone only
  // reliably walks sibling windows owned by the same thread.
  const DWORD style =
      desktop_widget_mode_ ? WS_POPUP | WS_DISABLED : WS_OVERLAPPEDWINDOW;
  const DWORD extended_style = desktop_widget_mode_
                                   ? WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
                                         WS_EX_TRANSPARENT | WS_EX_LAYERED
                                   : 0;
  HWND window = CreateWindowEx(
      extended_style, window_class, title.c_str(), style,
      desktop_widget_mode_ ? widget_bounds.left : Scale(origin.x, scale_factor),
      desktop_widget_mode_ ? widget_bounds.top : Scale(origin.y, scale_factor),
      desktop_widget_mode_ ? widget_bounds.right - widget_bounds.left
                           : Scale(size.width, scale_factor),
      desktop_widget_mode_ ? widget_bounds.bottom - widget_bounds.top
                           : Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  if (desktop_widget_mode_) {
    // WS_EX_TRANSPARENT only guarantees cross-process click-through for a
    // layered window. Keep the layer fully opaque at the native level;
    // Flutter's own alpha channel still supplies the visible transparency.
    SetLayeredWindowAttributes(window, 0, 255, LWA_ALPHA);
    EnableTransparentComposition(window);
    const DesktopWidgetCornerPreference corner_preference =
        kDesktopWidgetRoundCorners;
    DwmSetWindowAttribute(window, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference, sizeof(corner_preference));
    // Keep the transparent Flutter surface as a top-level tool window.
    // Reparenting the GPU-backed view into Explorer/Wallpaper Engine turns the
    // complete composition surface invisible on current Windows 11 builds.
    // This is not topmost: normal application windows naturally cover it,
    // while it remains above desktop wallpaper renderers.
    SetWindowPos(window, HWND_TOP, widget_bounds.left, widget_bounds.top,
                 widget_bounds.right - widget_bounds.left,
                 widget_bounds.bottom - widget_bounds.top,
                 SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }

  const bool created = OnCreate();
  if (created && !desktop_widget_mode_) {
    NOTIFYICONDATA icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = window_handle_;
    icon.uID = kTrayIconId;
    icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    icon.uCallbackMessage = kTrayCallbackMessage;
    icon.hIcon =
        LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
    wcscpy_s(icon.szTip, L"Elychron");
    tray_icon_added_ = Shell_NotifyIcon(NIM_ADD, &icon) == TRUE;
  }
  return created;
}

bool Win32Window::Show() {
  if (start_hidden_ && !desktop_widget_mode_) return true;
  return ShowWindow(window_handle_,
                    desktop_widget_mode_ ? SW_SHOWNOACTIVATE : SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCHITTEST:
      if (desktop_widget_mode_) {
        // The widget is display-only. Its transparent surface spans most of
        // the monitor height, so it must never consume desktop or Wallpaper
        // Engine mouse input.
        return HTTRANSPARENT;
      }
      break;

    case WM_CLOSE:
      if (!desktop_widget_mode_ && !exit_requested_ &&
          ReadElychronBoolean(L"CloseToTray", true)) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      if (!desktop_widget_mode_) StopDesktopWidgets();
      DestroyWindow(hwnd);
      return 0;

    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kTrayOpenCommand:
          start_hidden_ = false;
          ShowWindow(hwnd, SW_RESTORE);
          SetForegroundWindow(hwnd);
          return 0;
        case kTrayToggleWidgetCommand: {
          const bool visible = ReadElychronBoolean(L"WidgetVisible", true);
          WriteElychronBoolean(L"WidgetVisible", !visible);
          if (visible) {
            StopDesktopWidgets();
          } else {
            StartDesktopWidgets();
          }
          return 0;
        }
        case kTrayExitCommand:
          exit_requested_ = true;
          SendMessage(hwnd, WM_CLOSE, 0, 0);
          return 0;
      }
      break;

    case kTrayCallbackMessage:
      if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
        start_hidden_ = false;
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        return 0;
      }
      if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
        const bool widget_visible =
            ReadElychronBoolean(L"WidgetVisible", true);
        HMENU menu = CreatePopupMenu();
        AppendMenu(menu, MF_STRING, kTrayOpenCommand,
                   L"\u6253\u5F00 Elychron");
        AppendMenu(menu, MF_STRING, kTrayToggleWidgetCommand,
                   widget_visible
                       ? L"\u5173\u95ED\u684C\u9762\u6302\u4EF6"
                       : L"\u6253\u5F00\u684C\u9762\u6302\u4EF6");
        AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenu(menu, MF_STRING, kTrayExitCommand,
                   L"\u9000\u51FA Elychron");
        POINT cursor{};
        GetCursorPos(&cursor);
        SetForegroundWindow(hwnd);
        TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                       cursor.x, cursor.y, 0, hwnd, nullptr);
        DestroyMenu(menu);
        return 0;
      }
      break;

    case WM_DESTROY:
      if (tray_icon_added_) {
        NOTIFYICONDATA icon{};
        icon.cbSize = sizeof(icon);
        icon.hWnd = hwnd;
        icon.uID = kTrayIconId;
        Shell_NotifyIcon(NIM_DELETE, &icon);
        tray_icon_added_ = false;
      }
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      if (desktop_widget_mode_) {
        const HMONITOR monitor =
            DesktopMonitorAtIndex(desktop_widget_monitor_index_);
        const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
        const RECT bounds = DesktopWidgetBounds(monitor, dpi);
        SetWindowPos(hwnd, HWND_TOP, bounds.left, bounds.top,
                     bounds.right - bounds.left, bounds.bottom - bounds.top,
                     SWP_NOACTIVATE | SWP_FRAMECHANGED);
        return 0;
      }
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_DISPLAYCHANGE: {
      if (desktop_widget_mode_) {
        const HMONITOR monitor =
            DesktopMonitorAtIndex(desktop_widget_monitor_index_);
        const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
        const RECT bounds = DesktopWidgetBounds(monitor, dpi);
        SetWindowPos(hwnd, HWND_TOP, bounds.left, bounds.top,
                     bounds.right - bounds.left, bounds.bottom - bounds.top,
                     SWP_NOACTIVATE | SWP_FRAMECHANGED);
        return 0;
      }
      break;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  if (desktop_widget_mode_) {
    const LONG_PTR child_extended_style =
        GetWindowLongPtr(content, GWL_EXSTYLE);
    SetWindowLongPtr(content, GWL_EXSTYLE,
                     child_extended_style | WS_EX_TRANSPARENT |
                         WS_EX_NOACTIVATE);
    // Flutter renders into a child HWND. Disable both that surface and its
    // top-level host so neither can become the mouse target above Explorer.
    EnableWindow(content, FALSE);
    EnableWindow(window_handle_, FALSE);
  }
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  if (!desktop_widget_mode_) {
    SetFocus(child_content_);
  }
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SetDesktopWidgetMode(bool enabled) {
  desktop_widget_mode_ = enabled;
}

void Win32Window::SetStartHidden(bool hidden) {
  start_hidden_ = hidden;
}

void Win32Window::SetDesktopWidgetMonitor(int monitor_index) {
  desktop_widget_monitor_index_ = std::max(0, monitor_index);
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
