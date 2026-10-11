#ifndef RUNNER_NATIVE_DESKTOP_WIDGET_H_
#define RUNNER_NATIVE_DESKTOP_WIDGET_H_

#include <windows.h>

// Runs the lightweight, read-only desktop widget without starting Flutter.
// The window uses UpdateLayeredWindow and has no child HWND, so
// WS_EX_TRANSPARENT reliably passes every mouse event to the desktop.
int RunNativeDesktopWidget(int monitor_index, HANDLE stop_event);

#endif  // RUNNER_NATIVE_DESKTOP_WIDGET_H_
