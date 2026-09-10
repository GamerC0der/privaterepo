/* Minimal fullscreen kiosk browser: one window, one WebView, no chrome. */
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <stdlib.h>

static gboolean on_close(WebKitWebView *view, GtkWidget *win) {
    (void)view; (void)win;
    return TRUE; /* kiosk: ignore window.close(), never let the page exit us */
}

static gboolean on_context_menu(WebKitWebView *view, GtkWidget *menu,
                                 WebKitHitTestResult *hit, gboolean kb,
                                 gpointer data) {
    (void)view; (void)menu; (void)hit; (void)kb; (void)data;
    return TRUE; /* suppress right-click menu */
}

static gboolean on_decide_policy(WebKitWebView *view, WebKitPolicyDecision *decision,
                                  WebKitPolicyDecisionType type, gpointer data) {
    (void)view; (void)data;
    if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
        /* kiosk: never spawn extra windows, load in the same view instead */
        WebKitNavigationPolicyDecision *nd = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
        WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(nd);
        WebKitURIRequest *req = webkit_navigation_action_get_request(action);
        const char *uri = webkit_uri_request_get_uri(req);
        webkit_web_view_load_uri(view, uri);
        webkit_policy_decision_ignore(decision);
        return TRUE;
    }
    return FALSE;
}

int main(int argc, char **argv) {
    gtk_init(&argc, &argv);

    const char *home = g_getenv("KIOSK_HOME");
    if (!home) home = "file:///usr/local/share/kiosk/welcome.html";

    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_decorated(GTK_WINDOW(win), FALSE);
    gtk_window_fullscreen(GTK_WINDOW(win));
    gtk_window_set_title(GTK_WINDOW(win), "kiosk");

    WebKitWebView *view = WEBKIT_WEB_VIEW(webkit_web_view_new());
    WebKitSettings *settings = webkit_web_view_get_settings(view);
    webkit_settings_set_enable_javascript(settings, TRUE);
    webkit_settings_set_enable_developer_extras(settings, FALSE);
    webkit_settings_set_enable_write_console_messages_to_stdout(settings, TRUE);
    webkit_settings_set_default_charset(settings, "utf-8");
    webkit_settings_set_hardware_acceleration_policy(settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);

    g_signal_connect(view, "close", G_CALLBACK(on_close), win);
    g_signal_connect(view, "context-menu", G_CALLBACK(on_context_menu), NULL);
    g_signal_connect(view, "decide-policy", G_CALLBACK(on_decide_policy), NULL);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

    gtk_container_add(GTK_CONTAINER(win), GTK_WIDGET(view));
    gtk_widget_show_all(win);

    webkit_web_view_load_uri(view, home);

    gtk_main();
    return 0;
}
