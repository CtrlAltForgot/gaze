# Desktop window and tray behavior

On Linux, the title-bar X preserves the Flutter view and playback engine. With a
registered StatusNotifier host, it hides the window into the system tray. With no
supported tray or a failed registration, it minimizes to the taskbar instead. If
the desktop panel goes away while gaze is hidden, the runner brings the window
back so there is always a way to reach it.

The tray exposes Show gaze, Play/Pause, Previous, Next, and Quit gaze through the
host's native DBusMenu. Clicking the icon restores the same window. Starting gaze
again also activates the existing window through GtkApplication's single-instance
registration. Quit gaze saves the listening position before pausing and exiting;
X never invokes this path. Ctrl+Q also quits explicitly, including when the
desktop has no tray host.

The adapter uses the existing Dart dbus dependency and GTK runner; no additional
runtime package is required. Playback commands use the same playback and queue
controllers as the interface and preserve paused skipping. A small bundled icon
avoids image-cache or icon-theme dependence. It exports no authenticated media URL
or credential. Native window calls stay behind DesktopWindow, keeping a separate
adapter seam for Windows and macOS; those platforms' tray behavior is not yet
implemented or tested.

Acceptance: on Nobara/KDE, play music, press X, reopen from the tray, use each tray
control, launch the app a second time, then choose Quit gaze. Confirm one process,
continuous music on X, the preserved queue/position, and actual exit only on Quit.
Automated isolated-bus tests cover menu transport, malformed calls, live playback
labels, missing or disappearing panel hosts, and re-registration. Native visual
and interaction approval remains a separate check after a full application
restart because this change modifies the Linux runner.

Protocol references: [StatusNotifierItem](https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-item.html)
and [GTK delete-event](https://docs.gtk.org/gtk3/signal.Widget.delete-event.html).

## Integrated Linux window controls (October 20)

The Linux runner now negotiates an application frame with Flutter. Once the
36-pixel header is ready, GTK removes the separate system title bar. The header
contains gaze branding and minimize, maximize/restore, and close controls;
the sidebar no longer repeats the branding. Drag the empty header to move the
window and double-click it to maximize or restore. Six-pixel edges and corners
use GTK's compositor-managed resize operation. Native pointer timestamps are
preserved for Wayland move/resize. The maximize icon follows window-state events,
including changes made by desktop shortcuts. X still uses the existing tray
behavior; Ctrl+Q and Quit gaze remain explicit exit actions.

Window chrome uses a separate desktop method channel so tray lifecycle and
playback remain independent. Older runners keep the system frame if capability
negotiation is unavailable. Windows and macOS retain their existing native frames;
no support or test claims for custom controls on those platforms are implied.

Acceptance: automated interaction checks, Linux debug/release builds, then a full
restart and visual review on KDE. Check move, every resize edge, maximize/restore,
minimize/taskbar restore, X/tray restore, and explicit Quit. Compilation alone is
not evidence of native pointer behavior or user approval.

Native API references: [GTK move](https://docs.gtk.org/gtk3/method.Window.begin_move_drag.html),
[GTK resize](https://docs.gtk.org/gtk3/method.Window.begin_resize_drag.html), and
[GTK event dispatch](https://docs.gtk.org/gtk3/signal.Widget.event.html).

Header drag follow-up: the runner observes the embedder's child pointer event
receiver as well as FlView. Flutter consumes button presses in its GtkEventBox,
so listening only on FlView leaves no valid event for a Wayland window move.
The move uses the original GDK device and press timestamp, and releases clear
any cached press. A missing press returns an error rather than silently reporting
success. Verify with real desktop pointer input and window geometry before and
after the drag; invoking the method channel alone cannot validate this path.
