#include "my_application.h"
#include <cstring>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* window_channel;
  gboolean tray_available;
  gboolean custom_frame;
  FlMethodChannel* chrome_channel;
  GdkEvent* drag_event;
  FlMethodChannel* party_channel;
  gchar* pending_link;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// A hidden window keeps its Flutter view and audio engine alive. If no tray
// host is available, minimize instead so the taskbar remains a way back in.
static gboolean window_delete_cb(GtkWidget* widget, GdkEvent* event,
                                 MyApplication* self) {
  if (self->tray_available) {
    gtk_widget_hide(widget);
  } else {
    gtk_window_iconify(GTK_WINDOW(widget));
  }
  return TRUE;
}

static void show_window(MyApplication* self) {
  if (self->window == nullptr) return;
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_deiconify(self->window);
  gtk_window_present(self->window);
}

static gboolean quit_application_cb(gpointer data) {
  g_application_quit(G_APPLICATION(data));
  return G_SOURCE_REMOVE;
}

// Capture the real pointer event before Flutter consumes it. Native move/resize
// needs its seat timestamp on Wayland; inventing coordinates or GDK_CURRENT_TIME
// loses the compositor's interaction serial.
static gboolean view_event_cb(GtkWidget* widget, GdkEvent* event,
                              MyApplication* self) {
  if (!self->custom_frame) return FALSE;
  if (event->type == GDK_BUTTON_PRESS && event->button.button == 1) {
    if (self->drag_event != nullptr) gdk_event_free(self->drag_event);
    self->drag_event = gdk_event_copy(event);
  }
  if (event->type == GDK_BUTTON_RELEASE && event->button.button == 1) {
    g_clear_pointer(&self->drag_event, gdk_event_free);
  }
  if (event->type != GDK_BUTTON_PRESS && event->type != GDK_MOTION_NOTIFY)
    return FALSE;
  gdouble x, y;
  if (!gdk_event_get_coords(event, &x, &y)) return FALSE;
  const gint width = gtk_widget_get_allocated_width(widget);
  const gint height = gtk_widget_get_allocated_height(widget);
  const gboolean left = x < 6, right = x >= width - 6;
  const gboolean top = y < 6, bottom = y >= height - 6;
  const gboolean resize = !gtk_window_is_maximized(self->window) &&
                          (left || right || top || bottom);
  GdkWindowEdge edge = GDK_WINDOW_EDGE_NORTH;
  const gchar* cursor_name = "default";
  if (resize) {
    if (top && left) { edge = GDK_WINDOW_EDGE_NORTH_WEST; cursor_name = "nw-resize"; }
    else if (top && right) { edge = GDK_WINDOW_EDGE_NORTH_EAST; cursor_name = "ne-resize"; }
    else if (bottom && left) { edge = GDK_WINDOW_EDGE_SOUTH_WEST; cursor_name = "sw-resize"; }
    else if (bottom && right) { edge = GDK_WINDOW_EDGE_SOUTH_EAST; cursor_name = "se-resize"; }
    else if (left) { edge = GDK_WINDOW_EDGE_WEST; cursor_name = "w-resize"; }
    else if (right) { edge = GDK_WINDOW_EDGE_EAST; cursor_name = "e-resize"; }
    else if (bottom) { edge = GDK_WINDOW_EDGE_SOUTH; cursor_name = "s-resize"; }
    else { cursor_name = "n-resize"; }
  }
  if (event->type == GDK_MOTION_NOTIFY) {
    g_autoptr(GdkCursor) cursor = gdk_cursor_new_from_name(
        gtk_widget_get_display(widget), cursor_name);
    gdk_window_set_cursor(gtk_widget_get_window(widget), cursor);
  }
  if (resize && event->type == GDK_BUTTON_PRESS && event->button.button == 1) {
    gtk_window_begin_resize_drag(self->window, edge, 1,
        event->button.x_root, event->button.y_root, event->button.time);
    return TRUE;
  }
  return FALSE;
}

// FlView contains a GtkEventBox that consumes pointer events before they can
// bubble to FlView itself. Listen to the generic event signal on that child,
// which runs before Flutter's button-press handler. Include the view and other
// descendants so this also works if the embedder changes its event receiver.
static void connect_pointer_events(GtkWidget* widget, gpointer user_data) {
  gtk_widget_add_events(widget, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                                   GDK_POINTER_MOTION_MASK);
  g_signal_connect(widget, "event", G_CALLBACK(view_event_cb), user_data);
  if (GTK_IS_CONTAINER(widget)) {
    gtk_container_foreach(GTK_CONTAINER(widget), connect_pointer_events,
                          user_data);
  }
}

static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                 MyApplication* self) {
  if (self->chrome_channel != nullptr) {
    g_autoptr(FlValue) maximized = fl_value_new_bool(
        (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0);
    fl_method_channel_invoke_method(self->chrome_channel, "maximizedChanged",
                                    maximized, nullptr, nullptr, nullptr);
  }
  return FALSE;
}

static void window_method_call_cb(FlMethodChannel* channel,
                                  FlMethodCall* method_call,
                                  gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "show") == 0) {
    show_window(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "enableCustomFrame") == 0) {
    self->custom_frame = TRUE;
    gtk_window_set_decorated(self->window, FALSE);
    g_autoptr(FlValue) maximized = fl_value_new_bool(
        gtk_window_is_maximized(self->window));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(maximized));
  } else if (g_strcmp0(method, "minimize") == 0) {
    gtk_window_iconify(self->window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "toggleMaximize") == 0) {
    if (gtk_window_is_maximized(self->window)) gtk_window_unmaximize(self->window);
    else gtk_window_maximize(self->window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "close") == 0) {
    gtk_window_close(self->window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "beginDrag") == 0) {
    if (self->drag_event != nullptr) {
      const GdkEventButton* event = &self->drag_event->button;
      gdk_window_begin_move_drag_for_device(
          gtk_widget_get_window(GTK_WIDGET(self->window)),
          gdk_event_get_device(self->drag_event), event->button,
          event->x_root, event->y_root, event->time);
      g_clear_pointer(&self->drag_event, gdk_event_free);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "no-pointer-press", "Window dragging needs an active pointer press.",
          nullptr));
    }
  } else if (g_strcmp0(method, "setTrayAvailable") == 0) {
    FlValue* value = fl_method_call_get_args(method_call);
    if (fl_value_get_type(value) != FL_VALUE_TYPE_BOOL) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid-arguments", "Expected tray availability.", nullptr));
    } else {
      self->tray_available = fl_value_get_bool(value);
      // A desktop-panel restart must not strand gaze in an invisible window.
      if (!self->tray_available && self->window != nullptr &&
          !gtk_widget_get_visible(GTK_WIDGET(self->window))) {
        show_window(self);
      }
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (g_strcmp0(method, "quit") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    // Dart has flushed the listening state before requesting a real exit.
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, quit_application_cb,
                    g_object_ref(self), g_object_unref);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void party_method_cb(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if (g_strcmp0(fl_method_call_get_name(call), "initialLink") == 0) {
    g_autoptr(FlValue) value = self->pending_link == nullptr ? fl_value_new_null() : fl_value_new_string(self->pending_link);
    fl_method_call_respond_success(call, value, nullptr);
    g_clear_pointer(&self->pending_link, g_free);
  } else fl_method_call_respond_not_implemented(call, nullptr);
}

static void open_party_cb(GSimpleAction* action, GVariant* parameter, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  const gchar* link = g_variant_get_string(parameter, nullptr);
  if (!g_str_has_prefix(link, "gaze://party/") || strlen(link) > 2048) return;
  if (self->window != nullptr && self->party_channel != nullptr) {
    show_window(self);
    g_autoptr(FlValue) value = fl_value_new_string(link);
    fl_method_channel_invoke_method(self->party_channel, "openLink", value, nullptr, nullptr, nullptr);
  } else {
    g_free(self->pending_link); self->pending_link = g_strdup(link);
    g_application_activate(G_APPLICATION(self));
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    show_window(self);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  GdkVisual* visual = gdk_screen_get_rgba_visual(gtk_widget_get_screen(GTK_WIDGET(window)));
  if (visual != nullptr) gtk_widget_set_visual(GTK_WIDGET(window), visual);
  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  gtk_widget_set_name(GTK_WIDGET(window), "gaze-window");
  g_autoptr(GtkCssProvider) css = gtk_css_provider_new();
  gtk_css_provider_load_from_data(css,
      "#gaze-window { background-color: transparent; }", -1, nullptr);
  gtk_style_context_add_provider(gtk_widget_get_style_context(GTK_WIDGET(window)),
      GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                           reinterpret_cast<gpointer*>(&self->window));
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_cb), self);

  // Wayland decoration mode must be chosen before the surface is mapped;
  // changing it after Flutter's first frame can leave a duplicate system bar.
  // An empty, hidden custom titlebar explicitly negotiates client decoration
  // with KDE; Flutter draws the visible header inside the content surface.
  gtk_window_set_titlebar(window, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));
  gtk_window_set_decorated(window, FALSE);
  gtk_window_set_title(window, "gaze");
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb), self);

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  connect_pointer_events(GTK_WIDGET(view), self);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "gaze/desktop_window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_channel, window_method_call_cb, self, nullptr);

  self->chrome_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "gaze/window_chrome", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->chrome_channel, window_method_call_cb, self, nullptr);

  self->party_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "gaze/party_links", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->party_channel, party_method_cb, self, nullptr);
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  const gchar* link = (*arguments)[1];
  if (link != nullptr && g_str_has_prefix(link, "gaze://party/") && strlen(link) <= 2048) {
    g_action_group_activate_action(G_ACTION_GROUP(application), "open-party", g_variant_new_string(link));
  } else g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

static void request_quit_cb(GSimpleAction* action, GVariant* parameter,
                            gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->window_channel != nullptr) {
    fl_method_channel_invoke_method(self->window_channel, "quitRequested",
                                    nullptr, nullptr, nullptr, nullptr);
  }
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  g_autoptr(GSimpleAction) party_action = g_simple_action_new("open-party", G_VARIANT_TYPE_STRING);
  g_signal_connect(party_action, "activate", G_CALLBACK(open_party_cb), application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(party_action));
  g_autoptr(GSimpleAction) quit_action = g_simple_action_new("quit", nullptr);
  g_signal_connect(quit_action, "activate", G_CALLBACK(request_quit_cb),
                    application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(quit_action));
  const gchar* quit_accels[] = {"<Primary>q", nullptr};
  gtk_application_set_accels_for_action(GTK_APPLICATION(application),
                                        "app.quit", quit_accels);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->window_channel);
  g_clear_object(&self->chrome_channel);
  g_clear_object(&self->party_channel);
  g_clear_pointer(&self->pending_link, g_free);
  g_clear_pointer(&self->drag_event, gdk_event_free);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(0), nullptr));
}
