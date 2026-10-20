#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

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

  std::string party_link;
  if (!command_line_arguments.empty() && command_line_arguments.front().rfind("gaze://party/", 0) == 0 && command_line_arguments.front().size() <= 2048) {
    party_link = command_line_arguments.front();
    HWND existing = FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"gaze");
    if (existing != nullptr) {
      COPYDATASTRUCT packet{}; packet.dwData = 0x47415A45;
      packet.cbData = static_cast<DWORD>(party_link.size()); packet.lpData = party_link.data();
      DWORD_PTR result = 0;
      if (SendMessageTimeout(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&packet), SMTO_ABORTIFHUNG, 3000, &result) && result) { ::CoUninitialize(); return EXIT_SUCCESS; }
    }
  }
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetInitialPartyLink(party_link);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"gaze", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
