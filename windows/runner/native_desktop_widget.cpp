#include "native_desktop_widget.h"

#include <shellapi.h>
#include <shlobj.h>
#include <flutter_windows.h>

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
  bool monitor_available = true;
  bool tray_added = false;
  int scale_percent = 100;
  int font_scale_percent = 100;
  int theme = 0;
};

struct WidgetPreferences {
  int scale_percent;
  int font_scale_percent;
  int theme;
};

struct Palette {
  COLORREF text;
  COLORREF secondary;
  COLORREF heading;
  COLORREF card;
  COLORREF empty_card;
  COLORREF course;
  COLORREF exam;
  COLORREF event;
  COLORREF reminder;
  COLORREF todo;
  COLORREF urgent;
  unsigned char opacity;
};

DWORD ReadPreference(const wchar_t* name, DWORD fallback) {
  DWORD value = fallback;
  DWORD size = sizeof(value);
  if (RegGetValue(HKEY_CURRENT_USER, kPreferencesKey, name,
                  RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS) {
    return fallback;
  }
  return value;
}

WidgetPreferences LoadPreferences() {
  return {
      std::clamp(
          static_cast<int>(ReadPreference(L"WidgetCardScalePercent", 100)),
          80, 160),
      std::clamp(
          static_cast<int>(ReadPreference(L"WidgetFontScalePercent", 100)),
          80, 160),
      std::clamp(static_cast<int>(ReadPreference(L"WidgetTheme", 0)), 0, 3),
  };
}

bool PreferencesMatch(const State* state, const WidgetPreferences& value) {
  return state->scale_percent == value.scale_percent &&
         state->font_scale_percent == value.font_scale_percent &&
         state->theme == value.theme;
}

Palette PaletteFor(int theme) {
  switch (theme) {
    case 1:
      return {RGB(91, 57, 72),   RGB(139, 91, 111), RGB(151, 66, 103),
              RGB(255, 239, 246), RGB(249, 229, 238), RGB(204, 82, 132),
              RGB(216, 126, 55), RGB(150, 92, 181), RGB(54, 151, 126),
              RGB(223, 91, 142), RGB(204, 54, 83), 235};
    case 2:
      return {RGB(47, 69, 84),   RGB(78, 111, 132), RGB(43, 112, 151),
              RGB(235, 247, 252), RGB(224, 241, 248), RGB(42, 132, 187),
              RGB(205, 124, 48), RGB(98, 101, 183), RGB(36, 145, 129),
              RGB(55, 142, 184), RGB(201, 55, 73), 235};
    case 3:
      return {RGB(239, 241, 245), RGB(183, 190, 201), RGB(247, 248, 251),
              RGB(47, 52, 61), RGB(39, 44, 52), RGB(91, 174, 232),
              RGB(235, 163, 76), RGB(169, 132, 224), RGB(73, 190, 155),
              RGB(231, 116, 165), RGB(242, 93, 108), 225};
    default:
      return {RGB(62, 70, 82), RGB(98, 106, 118), RGB(86, 93, 105),
              RGB(245, 246, 248), RGB(242, 243, 246), RGB(59, 130, 196),
              RGB(209, 122, 33), RGB(118, 86, 184), RGB(41, 151, 122),
              RGB(217, 87, 131), RGB(210, 55, 70), 235};
  }
}

bool ReadWidgetVisible() {
  return ReadPreference(L"WidgetVisible", 1) != 0;
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
  // Keep compatibility with snapshots written before local-time
  // normalization. A trailing Z means the parsed wall-clock fields are UTC.
  if (!value.empty() && (value.back() == L'Z' || value.back() == L'z')) {
    SYSTEMTIME local{};
    if (SystemTimeToTzSpecificLocalTime(nullptr, time, &local)) {
      *time = local;
    }
  }
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

RECT WidgetBounds(int requested_index, int scale_percent) {
  std::vector<MonitorEntry> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitors,
                      reinterpret_cast<LPARAM>(&monitors));
  if (monitors.empty()) return RECT{0, 0, 280, 600};
  std::stable_sort(monitors.begin(), monitors.end(),
                   [](const auto& left, const auto& right) {
                     return left.primary && !right.primary;
                   });
  if (requested_index < 0 ||
      requested_index >= static_cast<int>(monitors.size())) {
    return RECT{0, 0, 0, 0};
  }
  const auto& selected = monitors[requested_index];
  MONITORINFO info{sizeof(info)};
  GetMonitorInfo(selected.handle, &info);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(selected.handle);
  const int work_width = info.rcWork.right - info.rcWork.left;
  const int logical_work_width = MulDiv(work_width, 96, std::max(96u, dpi));
  // Keep the laptop/secondary-screen width that was tuned during development,
  // then give wider desktop monitors more room without changing the user's
  // global card scale. Mixed-DPI virtualization makes a 420px base on the
  // large display match the already-tuned apparent width on the laptop panel.
  const int base_width = logical_work_width >= 2400 ? 420 : 280;
  const int margin = MulDiv(MulDiv(12, scale_percent, 100), dpi, 96);
  const int requested_width =
      MulDiv(MulDiv(base_width, scale_percent, 100), dpi, 96);
  const int width = std::clamp(requested_width, 180,
                               std::max(180, work_width - margin * 2));
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

std::wstring TimeLabel(const Item& item) {
  if (item.kind == L"todo") return L"无截止日期";
  if (item.kind == L"deadline" || item.kind == L"reminder") {
    wchar_t value[32]{};
    swprintf_s(value, L"%u月%u日 %02u时%02u分", item.time.wMonth,
               item.time.wDay, item.time.wHour, item.time.wMinute);
    return value;
  }
  SYSTEMTIME today{};
  GetLocalTime(&today);
  const SYSTEMTIME tomorrow = Tomorrow(today);
  wchar_t value[32]{};
  if (SameDay(item.time, today)) {
    swprintf_s(value, L"今天 %02u:%02u", item.time.wHour, item.time.wMinute);
  } else if (SameDay(item.time, tomorrow)) {
    swprintf_s(value, L"明天 %02u:%02u", item.time.wHour, item.time.wMinute);
  } else {
    swprintf_s(value, L"%u/%u %02u:%02u", item.time.wMonth, item.time.wDay,
               item.time.wHour, item.time.wMinute);
  }
  return value;
}

std::wstring RemainingLabel(const Item& item) {
  if (item.kind != L"deadline" && item.kind != L"reminder") return {};
  SYSTEMTIME now{};
  GetLocalTime(&now);
  FILETIME now_file{};
  FILETIME due_file{};
  if (!SystemTimeToFileTime(&now, &now_file) ||
      !SystemTimeToFileTime(&item.time, &due_file)) {
    return {};
  }
  ULARGE_INTEGER now_value{now_file.dwLowDateTime, now_file.dwHighDateTime};
  ULARGE_INTEGER due_value{due_file.dwLowDateTime, due_file.dwHighDateTime};
  const bool overdue = due_value.QuadPart < now_value.QuadPart;
  const unsigned long long ticks =
      overdue ? now_value.QuadPart - due_value.QuadPart
              : due_value.QuadPart - now_value.QuadPart;
  constexpr unsigned long long kTicksPerMinute = 60ULL * 10000000ULL;
  const unsigned long long total_minutes =
      overdue ? ticks / kTicksPerMinute
              : (ticks + kTicksPerMinute - 1) / kTicksPerMinute;
  const unsigned long long days = total_minutes / (24 * 60);
  const unsigned long long hours = (total_minutes / 60) % 24;
  const unsigned long long minutes = total_minutes % 60;
  wchar_t value[48]{};
  swprintf_s(value, overdue ? L"已超时 %llu天%llu时%llu分"
                            : L"还剩 %llu天%llu时%llu分",
             days, hours, minutes);
  return value;
}

bool IsSchedule(const Item& item) {
  return item.kind == L"course" || item.kind == L"exam" ||
         item.kind == L"event";
}

COLORREF KindColor(const Item& item, const Palette& palette) {
  if (item.urgent) return palette.urgent;
  if (item.kind == L"course") return palette.course;
  if (item.kind == L"exam") return palette.exam;
  if (item.kind == L"event") return palette.event;
  if (item.kind == L"reminder") return palette.reminder;
  return palette.todo;
}

void DrawSection(HDC dc, int width, int* y, const wchar_t* title,
                 const std::vector<const Item*>& items, HFONT small_font,
                 HFONT normal, HFONT semibold, const Palette& palette,
                 double font_scale, int max_count = 7) {
  const int heading_height = static_cast<int>(18 * font_scale);
  const int card_height = static_cast<int>(48 * font_scale);
  const int card_gap = std::max(5, static_cast<int>(5 * font_scale));
  const int title_height = static_cast<int>(22 * font_scale);
  const int time_width = static_cast<int>(124 * std::max(1.0, font_scale));
  RECT heading{11, *y, width - 11, *y + heading_height};
  Text(dc, std::wstring(title) + L"  " + std::to_wstring(items.size()),
       heading, palette.secondary, small_font, DT_LEFT | DT_SINGLELINE);
  *y += heading_height + 2;
  const int count =
      std::min(max_count, static_cast<int>(items.size()));
  if (count == 0) {
    HBRUSH brush = CreateSolidBrush(palette.empty_card);
    HPEN pen = CreatePen(PS_NULL, 0, 0);
    SelectObject(dc, brush);
    SelectObject(dc, pen);
    const int empty_height = static_cast<int>(28 * font_scale);
    RoundRect(dc, 11, *y, width - 11, *y + empty_height, 10, 10);
    RECT empty{19, *y + 5, width - 19, *y + empty_height - 3};
    Text(dc, L"暂无内容", empty, palette.secondary, small_font);
    DeleteObject(pen);
    DeleteObject(brush);
    *y += empty_height + 6;
    return;
  }
  for (int index = 0; index < count; ++index) {
    const Item& item = *items[index];
    HBRUSH brush = CreateSolidBrush(palette.card);
    HPEN pen = CreatePen(PS_NULL, 0, 0);
    SelectObject(dc, brush);
    SelectObject(dc, pen);
    RoundRect(dc, 11, *y, width - 11, *y + card_height, 10, 10);
    const COLORREF kind_color = KindColor(item, palette);
    HBRUSH accent = CreateSolidBrush(kind_color);
    RECT bar{11, *y + 3, 14, *y + card_height - 3};
    FillRect(dc, &bar, accent);
    const std::wstring time = TimeLabel(item);
    RECT time_rect{20, *y + 5, 20 + time_width, *y + 5 + title_height};
    Text(dc, time, time_rect, kind_color, semibold);
    const std::wstring remaining = RemainingLabel(item);
    if (!remaining.empty()) {
      RECT remaining_rect{20, *y + 5 + title_height, 20 + time_width,
                          *y + card_height - 4};
      Text(dc, remaining, remaining_rect, palette.secondary, small_font);
    }
    const int text_left = 22 + time_width;
    RECT title_rect{text_left, *y + 5, width - 19,
                    *y + 5 + title_height};
    Text(dc, item.title, title_rect, palette.text, normal);
    std::wstring detail = item.location.empty()
                              ? (item.kind == L"todo" ? L"手动代办" : item.kind)
                              : item.location;
    RECT detail_rect{text_left, *y + 5 + title_height, width - 19,
                     *y + card_height - 4};
    Text(dc, detail, detail_rect, palette.secondary, small_font);
    DeleteObject(accent);
    DeleteObject(pen);
    DeleteObject(brush);
    *y += card_height + card_gap;
  }
  *y += 2;
}

void Render(HWND window, State* state) {
  const WidgetPreferences preferences = LoadPreferences();
  state->scale_percent = preferences.scale_percent;
  state->font_scale_percent = preferences.font_scale_percent;
  state->theme = preferences.theme;
  const Palette palette = PaletteFor(preferences.theme);
  state->items = LoadItems();
  const RECT bounds =
      WidgetBounds(state->monitor_index, preferences.scale_percent);
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  if (width <= 0 || height <= 0) {
    state->monitor_available = false;
    ShowWindow(window, SW_HIDE);
    return;
  }
  state->monitor_available = true;
  const double layout_scale = preferences.scale_percent / 100.0;
  const int logical_width =
      std::max(1, static_cast<int>(width / layout_scale));
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

  SetGraphicsMode(memory, GM_ADVANCED);
  XFORM transform{static_cast<FLOAT>(layout_scale), 0, 0,
                  static_cast<FLOAT>(layout_scale), 0, 0};
  SetWorldTransform(memory, &transform);

  const double font_scale = preferences.font_scale_percent / 100.0;
  // The world transform scales cards and spacing. Divide the logical font
  // size by that transform so the font slider remains fully independent.
  const double logical_font_scale = font_scale / layout_scale;
  HFONT small_font = Font(
      std::max(8, static_cast<int>(12 * logical_font_scale)), FW_NORMAL);
  HFONT normal = Font(
      std::max(9, static_cast<int>(14 * logical_font_scale)), FW_SEMIBOLD);
  HFONT semibold = Font(
      std::max(8, static_cast<int>(12 * logical_font_scale)), FW_BOLD);
  HFONT heading = Font(
      std::max(11, static_cast<int>(18 * logical_font_scale)), FW_SEMIBOLD);
  SYSTEMTIME today{};
  GetLocalTime(&today);
  const SYSTEMTIME tomorrow = Tomorrow(today);
  const wchar_t* weekdays[] = {L"星期日", L"星期一", L"星期二", L"星期三",
                               L"星期四", L"星期五", L"星期六"};
  wchar_t date[64]{};
  swprintf_s(date, L"%u月%u日 %s", today.wMonth, today.wDay,
             weekdays[today.wDayOfWeek]);
  const int date_height = static_cast<int>(20 * font_scale);
  const int main_heading_height = static_cast<int>(26 * font_scale);
  RECT date_rect{11, 8, logical_width - 11, 8 + date_height};
  Text(memory, date, date_rect, palette.secondary, small_font);
  RECT heading_rect{11, 8 + date_height, logical_width - 11,
                    8 + date_height + main_heading_height};
  Text(memory, L"今天与近期", heading_rect, palette.heading, heading);

  std::vector<const Item*> today_items;
  std::vector<const Item*> tomorrow_items;
  std::vector<const Item*> todos;
  for (const auto& item : state->items) {
    if (IsSchedule(item) && SameDay(item.time, today)) today_items.push_back(&item);
    else if (IsSchedule(item) && SameDay(item.time, tomorrow)) tomorrow_items.push_back(&item);
    else if (!IsSchedule(item)) todos.push_back(&item);
  }
  int y = 14 + date_height + main_heading_height;
  DrawSection(memory, logical_width, &y, L"今日课程与日程", today_items,
              small_font, normal, semibold, palette, font_scale);
  DrawSection(memory, logical_width, &y, L"明日课程与日程", tomorrow_items,
              small_font, normal, semibold, palette, font_scale);
  const int todo_heading_height = static_cast<int>(20 * font_scale);
  const int todo_row_height = std::max(1, static_cast<int>(53 * font_scale));
  const int max_todo_count = std::max(
      1, (static_cast<int>(height / layout_scale) - y - todo_heading_height - 8) /
             todo_row_height);
  DrawSection(memory, logical_width, &y, L"全部作业与代办", todos, small_font,
              normal, semibold, palette, font_scale, max_todo_count);

  auto data = static_cast<unsigned char*>(pixels);
  for (size_t index = 0; index < static_cast<size_t>(width) * height; ++index) {
    unsigned char* pixel = data + index * 4;
    if (pixel[0] || pixel[1] || pixel[2]) {
      const unsigned char alpha = palette.opacity;
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
  if (state->widget_visible && !IsWindowVisible(window)) {
    ShowWindow(window, SW_SHOWNOACTIVATE);
  }

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
        const WidgetPreferences preferences = LoadPreferences();
        const bool appearance_changed =
            !PreferencesMatch(state, preferences);
        if (!should_show) {
          if (IsWindowVisible(window)) ShowWindow(window, SW_HIDE);
        } else if (state->monitor_available &&
                   (!IsWindowVisible(window) || IsIconic(window))) {
          ShowWindow(window, SW_SHOWNOACTIVATE);
          SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                           SWP_SHOWWINDOW);
        }
        state->widget_visible = should_show;
        if (should_show && appearance_changed) {
          state->timer_ticks = 0;
          Render(window, state);
        } else if (should_show && ++state->timer_ticks >= 30) {
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
