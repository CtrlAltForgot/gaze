#include "my_application.h"

int main(int argc, char** argv) {
  // Desktop launchers can inherit GDK_BACKEND=x11 from another GTK app. Prefer
  // gaze's native Wayland path, with an app-specific compatibility override.
  const gchar* backend = g_getenv("GAZE_DISPLAY_BACKEND");
  if (backend != nullptr && backend[0] != '\0')
    g_setenv("GDK_BACKEND", backend, TRUE);
  else if (g_getenv("WAYLAND_DISPLAY") != nullptr)
    g_setenv("GDK_BACKEND", "wayland", TRUE);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
