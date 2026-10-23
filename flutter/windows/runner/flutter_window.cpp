#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Destroy through OnDestroy before member destruction: destroying the Flutter
  // child can synchronously send messages back to this window.
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetBackground(RGB(0xF6, 0xF4, 0xEF));
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "easypub/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setBackground" || !call.arguments()) {
          result->NotImplemented();
          return;
        }
        // A Dart ARGB int arrives as int32 when it fits, otherwise int64.
        int64_t argb = 0;
        if (const auto* v = std::get_if<int32_t>(call.arguments())) {
          argb = static_cast<uint32_t>(*v);
        } else if (const auto* w = std::get_if<int64_t>(call.arguments())) {
          argb = *w;
        } else {
          result->Error("bad_argument", "expected ARGB integer");
          return;
        }
        SetBackground(RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF,
                          argb & 0xFF));
        result->Success();
      });
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    RegisterPlugins(flutter_view_controller->engine());
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetBackground(COLORREF color) {
  HBRUSH next = CreateSolidBrush(color);
  if (!next) {
    return;
  }
  // Use it for both the top-level and the Flutter view window classes;
  // install the new brush before releasing the old one.
  SetClassLongPtr(GetHandle(), GCLP_HBRBACKGROUND,
                  reinterpret_cast<LONG_PTR>(next));
  if (flutter_controller_ && flutter_controller_->view()) {
    SetClassLongPtr(flutter_controller_->view()->GetNativeWindow(),
                    GCLP_HBRBACKGROUND, reinterpret_cast<LONG_PTR>(next));
  }
  if (background_) {
    DeleteObject(background_);
  }
  background_ = next;
  InvalidateRect(GetHandle(), nullptr, TRUE);
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  if (background_) {
    DeleteObject(background_);
    background_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  TrackWindowState(message, wparam);
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
    if (message == WM_FONTCHANGE) {
      flutter_controller_->engine()->ReloadSystemFonts();
    }
  }
  // Erase with the window background instead of leaving black (background_).
  if (message == WM_ERASEBKGND && background_) {
    RECT area;
    GetClientRect(hwnd, &area);
    FillRect(reinterpret_cast<HDC>(wparam), &area, background_);
    return 1;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
