#include "native_desktop_widget.h"

#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cwctype>
#include <fstream>
#include <string>
#include <vector>

#include "resource.h"

namespace {

constexpr wchar_t kWidgetClass[] = L"ELYCHRON_NATIVE_DESKTOP_WIDGET";
constexpr wchar_t kWidgetTitle[] = L"Elychron Desktop Widget";
constexpr UINT_PTR kRefreshTimer = 1;
constexpr UINT kTrayCallback = WM_APP + 42;
constexpr UINT kOpenMainWindowMessage = WM_APP + 2;
constexpr UINT kTrayOpen = 42001;
constexpr UINT kTrayToggleWidget = 42002;
constexpr UINT kTrayExit = 42003;
constexpr UINT kMainExitCommand = 41003;
constexpr UINT kTrayIconId = 1;
constexpr wchar_t kPreferencesKey[] = L"Software\\Elychron\\Windows";

struct Item {
  std::wstring title;
  std::wstring location;
  std::wstring kind;
  SYSTEMTIME time{};
  bool urgent = false;
};

struct State {
  int monitor_index = 0;
  int timer_ticks = 0;
  std::vector<Item> items;
  HWND widget = nullptr;
  HWND tray = nullptr;
  HANDLE stop_event = nullptr;
  bool widget_visible = true;
  bool tray_added = false;
};

bool ReadWidgetVisible() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  if (RegGetValue(HKEY_CURRENT_USER, kPreferencesKey, L"WidgetVisible",
                  RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) {
    return true;
  }
  return value != 0;
}

void WriteWidgetVisible(bool visible) {
  HKEY key = nullptr;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, kPreferencesKey, 0, nullptr, 0,
                     KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  const DWORD value = visible ? 1 : 0;
  RegSetValueEx(key, L"WidgetVisible", 0, REG_DWORD,
                reinterpret_cast<const BYTE*>(&value), sizeof(value));
  RegCloseKey(key);
}

void LaunchMainApplication() {
  HWND existing = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Elychron");
  if (existing != nullptr) {
    PostMessage(existing, kOpenMainWindowMessage, 0, 0);
    return;
  }
  wchar_t executable[MAX_PATH]{};
  if (GetModuleFileName(nullptr, executable, MAX_PATH) == 0) return;
  std::wstring command = L"\"" + std::wstring(executable) + L"\"";
  STARTUPINFO startup{sizeof(startup)};
  PROCESS_INFORMATION process{};
  if (CreateProcess(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                    nullptr, nullptr, &startup, &process)) {
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
  }
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(),
                      static_cast<int>(value.size()), result.data(), length);
  return result;
}

std::wstring SnapshotPath() {
  wchar_t app_data[MAX_PATH]{};
  if (FAILED(SHGetFolderPath(nullptr, CSIDL_APPDATA, nullptr,
                             SHGFP_TYPE_CURRENT, app_data))) {
    return {};
  }
  return std::wstring(app_data) +
         L"\\org.cc\\celechron\\desktop-widget-v1.json";
}

std::wstring ReadSnapshot() {
  const std::wstring path = SnapshotPath();
  if (path.empty()) return {};
  std::ifstream stream(path, std::ios::binary);
  if (!stream) return {};
  return Utf8ToWide(std::string(std::istreambuf_iterator<char>(stream), {}));
}

int HexValue(wchar_t value) {
  if (value >= L'0' && value <= L'9') return value - L'0';
  value = static_cast<wchar_t>(towlower(value));
  if (value >= L'a' && value <= L'f') return value - L'a' + 10;
  return -1;
}

std::wstring JsonString(const std::wstring& object, const wchar_t* key) {
  const std::wstring needle = L"\"" + std::wstring(key) + L"\"";
  size_t pos = object.find(needle);
  if (pos == std::wstring::npos) return {};
  pos = object.find(L':', pos + needle.size());
  if (pos == std::wstring::npos) return {};
  pos = object.find(L'\"', pos + 1);
  if (pos == std::wstring::npos) return {};
  std::wstring result;
  for (++pos; pos < object.size(); ++pos) {
    wchar_t ch = object[pos];
    if (ch == L'\"') break;
    if (ch != L'\\' || pos + 1 >= object.size()) {
      result.push_back(ch);
      continue;
    }
    ch = object[++pos];
    if (ch == L'n') result.push_back(L'\n');
    else if (ch == L'r') result.push_back(L'\r');
    else if (ch == L't') result.push_back(L'\t');
    else if (ch == L'u' && pos + 4 < object.size()) {
      int code = 0;
      bool valid = true;
      for (int index = 0; index < 4; ++index) {
        const int hex = HexValue(object[pos + 1 + index]);
        if (hex < 0) valid = false;
        code = code * 16 + std::max(0, hex);
      }
      if (valid) {
        result.push_back(static_cast<wchar_t>(code));
        pos += 4;
      }
    } else {
      result.push_back(ch);
    }
  }
  return result;
}

bool ParseTime(const std::wstring& value, SYSTEMTIME* time) {
  if (value.size() < 16) return false;
  int year = 0, month = 0, day = 0, hour = 0, minute = 0;
  if (swscanf_s(value.c_str(), L"%d-%d-%dT%d:%d", &year, &month, &day,
                &hour, &minute) != 5) {
    return false;
  }
  time->wYear = static_cast<WORD>(year);
  time->wMonth = static_cast<WORD>(month);
  time->wDay = static_cast<WORD>(day);
  time->wHour = static_cast<WORD>(hour);
  time->wMinute = static_cast<WORD>(minute);
  return true;
}

std::vector<std::wstring> JsonObjects(const std::wstring& json) {
  std::vector<std::wstring> objects;
  size_t items = json.find(L"\"items\"");
  size_t start = json.find(L'[', items);
  if (start == std::wstring::npos) return objects;
  bool quoted = false;
  bool escaped = false;
  int depth = 0;
  size_t object_start = std::wstring::npos;
  for (size_t index = start + 1; index < json.size(); ++index) {
    const wchar_t ch = json[index];
    if (quoted) {
      if (escaped) escaped = false;
      else if (ch == L'\\') escaped = true;
      else if (ch == L'\"') quoted = false;
      continue;
    }
    if (ch == L'\"') quoted = true;
    else if (ch == L'{') {
      if (depth++ == 0) object_start = index;
    } else if (ch == L'}' && depth > 0 && --depth == 0) {
      objects.push_back(json.substr(object_start, index - object_start + 1));
    } else if (ch == L']' && depth == 0) {
      break;
    }
  }
  return objects;
}

std::vector<Item> LoadItems() {
  std::vector<Item> result;
  for (const auto& object : JsonObjects(ReadSnapshot())) {
    Item item;
    item.title = JsonString(object, L"title");
    item.location = JsonString(object, L"location");
    item.kind = JsonString(object, L"kind");
    item.urgent = object.find(L"\"urgent\":true") != std::wstring::npos;
    if (!item.title.empty() &&
        ParseTime(JsonString(object, L"startTime"), &item.time)) {
      result.push_back(std::move(item));
    }
  }
  return result;
}

struct MonitorEntry {
  HMONITOR handle;
  bool primary;
};

BOOL CALLBACK CollectMonitors(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  MONITORINFO info{sizeof(info)};
  if (GetMonitorInfo(monitor, &info)) {
    reinterpret_cast<std::vector<MonitorEntry>*>(data)->push_back(
        {monitor, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
  }
  return TRUE;
}

RECT WidgetBounds(int requested_index) {
  std::vector<MonitorEntry> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitors,
                      reinterpret_cast<LPARAM>(&monitors));
  if (monitors.empty()) return RECT{0, 0, 280, 600};
  std::stable_sort(monitors.begin(), monitors.end(),
                   [](const auto& left, const auto& right) {
                     return left.primary && !right.primary;
                   });
  const auto& selected = monitors[std::clamp(
      requested_index, 0, static_cast<int>(monitors.size()) - 1)];
  MONITORINFO info{sizeof(info)};
  GetMonitorInfo(selected.handle, &info);
  const UINT dpi = GetDpiForWindow(GetDesktopWindow());
  const int margin = MulDiv(12, dpi, 96);
  const int width = MulDiv(280, dpi, 96);
  return RECT{info.rcWork.right - margin - width, info.rcWork.top + margin,
              info.rcWork.right - margin, info.rcWork.bottom - margin};
}

HFONT Font(int size, int weight) {
  return CreateFont(-size, 0, 0, 0, weight, FALSE, FALSE, FALSE,
                    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                    CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Microsoft YaHei UI");
}

void Text(HDC dc, const std::wstring& value, RECT rect, COLORREF color,
          HFONT font, UINT flags = DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS) {
  SelectObject(dc, font);
  SetTextColor(dc, color);
  SetBkMode(dc, TRANSPARENT);
  DrawText(dc, value.c_str(), -1, &rect, flags | DT_NOPREFIX);
}

bool SameDay(const SYSTEMTIME& left, const SYSTEMTIME& right) {
  return left.wYear == right.wYear && left.wMonth == right.wMonth &&
         left.wDay == right.wDay;
}

SYSTEMTIME Tomorrow(SYSTEMTIME today) {
  FILETIME file{};
  SystemTimeToFileTime(&today, &file);
  ULARGE_INTEGER value{file.dwLowDateTime, file.dwHighDateTime};
  value.QuadPart += 24ULL * 60 * 60 * 10000000;
  file.dwLowDateTime = value.LowPart;
  file.dwHighDateTime = value.HighPart;
  FileTimeToSystemTime(&file, &today);
  return today;
}

bool IsSchedule(const Item& item) {
  return item.kind == L"course" || item.kind == L"exam" ||
         item.kind == L"event";
}

COLORREF KindColor(const Item& item) {
  if (item.urgent) return RGB(210, 55, 70);
  if (item.kind == L"course") return RGB(59, 130, 196);
  if (item.kind == L"exam") return RGB(209, 122, 33);
  if (item.kind == L"event") return RGB(118, 86, 184);
  if (item.kind == L"reminder") return RGB(41, 151, 122);
  return RGB(217, 87, 131);
}

void DrawSection(HDC dc, int width, int* y, const wchar_t* title,
                 const std::vector<const Item*>& items, HFONT small_font,
                 HFONT normal, HFONT semibold) {
  RECT heading{11, *y, width - 11, *y + 18};
  Text(dc, std::wstring(title) + L"  " + std::to_wstring(items.size()),
       heading, RGB(98, 106, 118), small_font, DT_LEFT | DT_SINGLELINE);
  *y += 20;
  const int count = std::min(7, static_cast<int>(items.size()));
  if (count == 0) {
    HBRUSH brush = CreateSolidBrush(RGB(242, 243, 246));
    HPEN pen = CreatePen(PS_NULL, 0, 0);
    SelectObject(dc, brush);
    SelectObject(dc, pen);
    RoundRect(dc, 11, *y, width - 11, *y + 28, 10, 10);
    RECT empty{19, *y + 5, width - 19, *y + 25};
    Text(dc, L"暂无内容", empty, RGB(139, 139, 148), small_font);
    DeleteObject(pen);
    DeleteObject(brush);
    *y += 34;
    return;
  }
  for (int index = 0; index < count; ++index) {
    const Item& item = *items[index];
    HBRUSH brush = CreateSolidBrush(RGB(245, 246, 248));
    HPEN pen = CreatePen(PS_NULL, 0, 0);
    SelectObject(dc, brush);
    SelectObject(dc, pen);
    RoundRect(dc, 11, *y, width - 11, *y + 48, 10, 10);
    HBRUSH accent = CreateSolidBrush(KindColor(item));
    RECT bar{11, *y + 3, 14, *y + 45};
    FillRect(dc, &bar, accent);
    wchar_t time[16]{};
    swprintf_s(time, L"%02u:%02u", item.time.wHour, item.time.wMinute);
    RECT time_rect{20, *y + 8, 62, *y + 28};
    Text(dc, time, time_rect, KindColor(item), semibold);
    RECT title_rect{64, *y + 5, width - 19, *y + 27};
    Text(dc, item.title, title_rect, RGB(62, 70, 82), normal);
    std::wstring detail = item.location.empty() ? item.kind : item.location;
    RECT detail_rect{64, *y + 26, width - 19, *y + 44};
    Text(dc, detail, detail_rect, RGB(98, 106, 118), small_font);
    DeleteObject(accent);
    DeleteObject(pen);
    DeleteObject(brush);
    *y += 53;
  }
  *y += 2;
}

void Render(HWND window, State* state) {
  state->items = LoadItems();
  const RECT bounds = WidgetBounds(state->monitor_index);
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  HDC screen = GetDC(nullptr);
  HDC memory = CreateCompatibleDC(screen);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels,
                                    nullptr, 0);
  HGDIOBJ old_bitmap = SelectObject(memory, bitmap);
  memset(pixels, 0, static_cast<size_t>(width) * height * 4);

  HFONT small_font = Font(12, FW_NORMAL);
  HFONT normal = Font(14, FW_SEMIBOLD);
  HFONT semibold = Font(12, FW_BOLD);
  HFONT heading = Font(18, FW_SEMIBOLD);
  SYSTEMTIME today{};
  GetLocalTime(&today);
  const SYSTEMTIME tomorrow = Tomorrow(today);
  const wchar_t* weekdays[] = {L"星期日", L"星期一", L"星期二", L"星期三",
                               L"星期四", L"星期五", L"星期六"};
  wchar_t date[64]{};
  swprintf_s(date, L"%u月%u日 %s", today.wMonth, today.wDay,
             weekdays[today.wDayOfWeek]);
  RECT date_rect{11, 8, width - 11, 28};
  Text(memory, date, date_rect, RGB(101, 107, 118), small_font);
  RECT heading_rect{11, 28, width - 11, 54};
  Text(memory, L"今天与近期", heading_rect, RGB(86, 93, 105), heading);

  std::vector<const Item*> today_items;
  std::vector<const Item*> tomorrow_items;
  std::vector<const Item*> todos;
  for (const auto& item : state->items) {
    if (IsSchedule(item) && SameDay(item.time, today)) today_items.push_back(&item);
    else if (IsSchedule(item) && SameDay(item.time, tomorrow)) tomorrow_items.push_back(&item);
    else if (!IsSchedule(item)) todos.push_back(&item);
  }
  int y = 60;
  DrawSection(memory, width, &y, L"今日课程与日程", today_items, small_font,
              normal, semibold);
  DrawSection(memory, width, &y, L"明日课程与日程", tomorrow_items, small_font,
              normal, semibold);
  DrawSection(memory, width, &y, L"近期作业与代办", todos, small_font, normal,
              semibold);

  auto data = static_cast<unsigned char*>(pixels);
  for (size_t index = 0; index < static_cast<size_t>(width) * height; ++index) {
    unsigned char* pixel = data + index * 4;
    if (pixel[0] || pixel[1] || pixel[2]) {
      const unsigned char alpha = 235;
      pixel[0] = static_cast<unsigned char>(pixel[0] * alpha / 255);
      pixel[1] = static_cast<unsigned char>(pixel[1] * alpha / 255);
      pixel[2] = static_cast<unsigned char>(pixel[2] * alpha / 255);
      pixel[3] = alpha;
    }
  }

  POINT destination{bounds.left, bounds.top};
  SIZE size{width, height};
  POINT source{0, 0};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(window, screen, &destination, &size, memory, &source, 0,
                      &blend, ULW_ALPHA);

  DeleteObject(heading);
  DeleteObject(semibold);
  DeleteObject(normal);
  DeleteObject(small_font);
  SelectObject(memory, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(memory);
  ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK TrayProc(HWND window, UINT message, WPARAM wparam,
                          LPARAM lparam);

LRESULT CALLBACK WidgetProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  auto state = reinterpret_cast<State*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == kTrayCallback || message == WM_COMMAND) {
    return TrayProc(window, message, wparam, lparam);
  }
  switch (message) {
    case WM_NCCREATE:
      SetWindowLongPtr(window, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(
                           reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams));
      return TRUE;
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_TIMER:
      if (state != nullptr) {
        const bool should_show = ReadWidgetVisible();
        if (!should_show) {
          if (IsWindowVisible(window)) ShowWindow(window, SW_HIDE);
        } else if (!IsWindowVisible(window) || IsIconic(window)) {
          ShowWindow(window, SW_SHOWNOACTIVATE);
          SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                           SWP_SHOWWINDOW);
        }
        state->widget_visible = should_show;
        if (should_show && ++state->timer_ticks >= 30) {
          state->timer_ticks = 0;
          Render(window, state);
        }
      }
      return 0;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
      if (state != nullptr) Render(window, state);
      return 0;
    case WM_DESTROY:
      KillTimer(window, kRefreshTimer);
      if (state != nullptr && state->tray_added) {
        NOTIFYICONDATA icon{};
        icon.cbSize = sizeof(icon);
        icon.hWnd = window;
        icon.uID = kTrayIconId;
        Shell_NotifyIcon(NIM_DELETE, &icon);
        state->tray_added = false;
      }
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT CALLBACK TrayProc(HWND window, UINT message, WPARAM wparam,
                          LPARAM lparam) {
  auto state = reinterpret_cast<State*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    state = reinterpret_cast<State*>(
        reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
    return TRUE;
  }
  if (state == nullptr) return DefWindowProc(window, message, wparam, lparam);

  if (message == kTrayCallback) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
      LaunchMainApplication();
      return 0;
    }
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      HMENU menu = CreatePopupMenu();
      AppendMenu(menu, MF_STRING, kTrayOpen, L"打开 Elychron");
      AppendMenu(menu, MF_STRING, kTrayToggleWidget,
                 ReadWidgetVisible() ? L"关闭桌面挂件" : L"打开桌面挂件");
      AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenu(menu, MF_STRING, kTrayExit, L"退出 Elychron");
      POINT point{};
      GetCursorPos(&point);
      const UINT command = TrackPopupMenu(
          menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_RETURNCMD | TPM_NONOTIFY,
          point.x, point.y, 0, window, nullptr);
      DestroyMenu(menu);
      if (command != 0) SendMessage(window, WM_COMMAND, command, 0);
      return 0;
    }
  }
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kTrayOpen:
        LaunchMainApplication();
        return 0;
      case kTrayToggleWidget: {
        const bool visible = !ReadWidgetVisible();
        WriteWidgetVisible(visible);
        state->widget_visible = visible;
        ShowWindow(state->widget, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
        return 0;
      }
      case kTrayExit: {
        HWND main_window = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Elychron");
        if (main_window != nullptr) {
          PostMessage(main_window, WM_COMMAND, kMainExitCommand, 0);
        }
        SetEvent(state->stop_event);
        return 0;
      }
    }
  }
  if (message == WM_DESTROY && state->tray_added) {
    NOTIFYICONDATA icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = window;
    icon.uID = kTrayIconId;
    Shell_NotifyIcon(NIM_DELETE, &icon);
    state->tray_added = false;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

}  // namespace

int RunNativeDesktopWidget(int monitor_index, HANDLE stop_event) {
  HINSTANCE instance = GetModuleHandle(nullptr);
  WNDCLASS window_class{};
  window_class.lpfnWndProc = WidgetProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kWidgetClass;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClass(&window_class);
  State state{};
  state.monitor_index = monitor_index;
  state.stop_event = stop_event;
  state.widget_visible = ReadWidgetVisible();
  // Create the layered popup as an owned window of the desktop from its first
  // frame. Re-parenting an already rendered UpdateLayeredWindow surface drops
  // its bitmap on some Windows builds; assigning the owner at creation avoids
  // that transition while allowing Show Desktop to treat it as desktop UI.
  HWND desktop_owner = FindWindow(L"Progman", L"Program Manager");
  HWND window = CreateWindowEx(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kWidgetClass, kWidgetTitle, WS_POPUP | WS_DISABLED, 0, 0, 1, 1,
      desktop_owner, nullptr, instance, &state);
  if (window == nullptr) return EXIT_FAILURE;
  state.widget = window;
  SetWindowText(window, kWidgetTitle);
  Render(window, &state);
  if (state.widget_visible) {
    SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }
  SetTimer(window, kRefreshTimer, 500, nullptr);

  if (monitor_index == 0) {
    // Use the proven click-through widget HWND as the notification icon owner.
    // It continues receiving posted shell messages even while visually hidden.
    state.tray = window;
    NOTIFYICONDATA icon{};
    icon.cbSize = sizeof(icon);
    icon.hWnd = window;
    icon.uID = kTrayIconId;
    icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    icon.uCallbackMessage = kTrayCallback;
    icon.hIcon = LoadIcon(instance, MAKEINTRESOURCE(IDI_APP_ICON));
    wcscpy_s(icon.szTip, L"Elychron");
    state.tray_added = Shell_NotifyIcon(NIM_ADD, &icon) == TRUE;
  }
  MSG message{};
  bool running = true;
  while (running) {
    const DWORD result = MsgWaitForMultipleObjects(
        1, &stop_event, FALSE, INFINITE, QS_ALLINPUT);
    if (result == WAIT_OBJECT_0) {
      ShowWindow(window, SW_HIDE);
      break;
    }
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) {
        running = false;
        break;
      }
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
  }
  DestroyWindow(window);
  UnregisterClass(kWidgetClass, instance);
  return EXIT_SUCCESS;
}
