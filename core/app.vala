/*
 Copyright (C) 2018 Christian Dywan <christian@twotoats.de>

 This library is free software; you can redistribute it and/or
 modify it under the terms of the GNU Lesser General Public
 License as published by the Free Software Foundation; either
 version 2.1 of the License, or (at your option) any later version.

 See the file COPYING for the full license text.
*/

namespace Midori {
    public interface AppActivatable : Peas.ExtensionBase {
        public abstract App app { owned get; set; }
        public abstract void activate ();
    }

    public class App : Gtk.Application {
        public File? exec_path { get; protected set; default = null; }

        static string? app = null;
        [CCode (array_length = false, array_null_terminated = true)]
        static string[]? execute = null;
        static bool help_execute = false;
        static bool incognito = false;
        static bool version = false;
        const OptionEntry[] options = {
            { "app", 'a', 0, OptionArg.STRING, ref app, N_("Run ADDRESS as a web application"), N_("ADDRESS") },
            { "execute", 'e', 0, OptionArg.STRING_ARRAY, ref execute, N_("Execute the specified command"), null },
            { "help-execute", 0, 0, OptionArg.NONE, ref help_execute, N_("List available commands to execute with -e/ --execute"), null },
            { "private", 'p', 0, OptionArg.NONE, ref incognito, N_("Private browsing, no changes are saved"), null },
            { "version", 'V', 0, OptionArg.NONE, ref version, N_("Display version number"), null },
            { null }
        };
        const ActionEntry[] actions = {
            { "win-incognito-new", win_incognito_new_activated },
            { "quit", quit_activated },
        };

        public App () {
            Object (application_id: "org.midori_browser.Midori",
                    flags: ApplicationFlags.HANDLES_OPEN
                         | ApplicationFlags.HANDLES_COMMAND_LINE);

            add_main_option_entries (options);
        }

        public override bool local_command_line (ref weak string[] args, out int exit_status) {
            exit_status = -1;
            // Get the executable path
            string executable = args[0];
            try {
                if (!Path.is_absolute (executable)) {
                    executable = Environment.find_program_in_path (executable);
                    if (FileUtils.test (executable, FileTest.IS_SYMLINK))
                        executable = FileUtils.read_link (executable);
                }
            } catch (FileError error) {
                debug ("Failed to look up exec path: %s", error.message);
            }
            exec_path = File.new_for_path (executable);

            return base.local_command_line (ref args, out exit_status);
        }

        public override void startup () {
            base.startup ();

            Intl.bindtextdomain (Config.PROJECT_NAME, null);
            Intl.bind_textdomain_codeset (Config.PROJECT_NAME, "UTF-8");
            Intl.textdomain (Config.PROJECT_NAME);

            Gtk.Window.set_default_icon_name (Config.PROJECT_NAME);

            var context = WebKit.WebContext.get_default ();
            context.register_uri_scheme ("internal", (request) => {
                request.ref ();
                internal_scheme.begin (request);
            });
            context.register_uri_scheme ("favicon", (request) => {
                request.ref ();
                favicon_scheme.begin (request);
            });
            context.register_uri_scheme ("stock", (request) => {
                request.ref ();
                stock_scheme.begin (request);
            });
            context.register_uri_scheme ("res", (request) => {
                try {
                    var stream = resources_open_stream (request.get_path (),
                                                        ResourceLookupFlags.NONE);
                    request.finish (stream, -1, null);
                } catch (Error error) {
                    request.finish_error (error);
                    critical ("Failed to load resource %s: %s", request.get_uri (), error.message);
                }
            });
            string config = Path.build_path (Path.DIR_SEPARATOR_S,
                Environment.get_user_config_dir (), Environment.get_prgname ());
            DirUtils.create_with_parents (config, 0700);
            string cookies = Path.build_filename (config, "cookies");
            context.get_cookie_manager ().set_persistent_storage (cookies, WebKit.CookiePersistentStorage.SQLITE);
            string cache = Path.build_path (Path.DIR_SEPARATOR_S,
                Environment.get_user_cache_dir (), Environment.get_prgname ());
            string icons = Path.build_path (Path.DIR_SEPARATOR_S, cache, "icondatabase");
            context.set_favicon_database_directory (icons);

            // Try and load web extensions from build folder
            var web_path = exec_path.get_parent ().get_child ("web");
            if (!web_path.query_exists (null)) {
                // Alternatively look for an installed path
                web_path = exec_path.get_parent ().get_parent ().get_child ("lib").get_child (Environment.get_prgname ());
            }
            context.set_web_extensions_directory (web_path.get_path ());
            context.initialize_web_extensions.connect (() => {
                context.set_web_extensions_initialization_user_data ("");
            });

            add_action_entries (actions, this);

            var action = new SimpleAction ("win-new", VariantType.STRING);
            action.activate.connect (win_new_activated);
            add_action (action);

            // Unset app menu if not handled by the shell
            if (!Gtk.Settings.get_default ().gtk_shell_shows_app_menu){
                app_menu = null;
            }

            var extensions = Plugins.get_default ().plug<AppActivatable> ("app", this);
            extensions.extension_added.connect ((info, extension) => ((AppActivatable)extension).activate ());
            extensions.foreach ((extensions, info, extension) => { extensions.extension_added (info, extension); });
        }

        async void internal_scheme (WebKit.URISchemeRequest request) {
            try {
                var shortcuts = yield HistoryDatabase.get_default ().query (null, 9);
                string content = "";
                uint index = 0;
                foreach (var shortcut in shortcuts) {
                    index++;
                    content += """
                        <div class="shortcut">
                          <a href="%s" accesskey="%u">
                            <img src="%s" />
                            <span class="title">%s</span>
                          </a>
                        </div>""".printf (shortcut.uri, index, "favicon:///" + shortcut.uri, shortcut.title);
                }
                string stylesheet = (string)resources_lookup_data ("/data/about.css",
                                                                    ResourceLookupFlags.NONE).get_data ();
                string html = ((string)resources_lookup_data ("/data/speed-dial.html",
                                                             ResourceLookupFlags.NONE).get_data ())
                    .replace ("{title}", _("Speed Dial"))
                    .replace ("{icon}", "view-grid")
                    .replace ("{content}", content)
                    .replace ("{stylesheet}", stylesheet);
                var stream = new MemoryInputStream.from_data (html.data, free);
                request.finish (stream, html.length, "text/html");
            } catch (Error error) {
                request.finish_error (error);
                critical ("Failed to render %s: %s", request.get_uri (), error.message);
            }
            request.unref ();
        }

        void request_finish_pixbuf (WebKit.URISchemeRequest request, Gdk.Pixbuf pixbuf) throws Error {
            var output = new MemoryOutputStream (null, realloc, free);
            pixbuf.save_to_stream (output, "png");
            output.close ();
            uint8[] data = output.steal_data ();
            data.length = (int)output.get_data_size ();
            var stream = new MemoryInputStream.from_data (data, free);
            request.finish (stream, -1, null);
        }

        async void favicon_scheme (WebKit.URISchemeRequest request) {
            string page_uri = request.get_path ().substring (1, -1);
            try {
                var database = WebKit.WebContext.get_default ().get_favicon_database ();
                var surface = yield database.get_favicon (page_uri, null);
                if (surface != null) {
                    var image = (Cairo.ImageSurface)surface;
                    var icon = Gdk.pixbuf_get_from_surface (image, 0, 0, image.get_width (), image.get_height ());
                    request_finish_pixbuf (request, icon);
                }
            } catch (Error error) {
                request.finish_error (error);
                debug ("Failed to render favicon for %s: %s", page_uri, error.message);
            }
            request.unref ();
        }

        async void stock_scheme (WebKit.URISchemeRequest request) {
            string icon_name = request.get_path ().substring (1, -1);
            int icon_size = 48;
            Gtk.icon_size_lookup ((Gtk.IconSize)Gtk.IconSize.DIALOG, out icon_size, null);
            try {
                var icon = Gtk.IconTheme.get_default ().load_icon (icon_name, icon_size, Gtk.IconLookupFlags.FORCE_SYMBOLIC);
                request_finish_pixbuf (request, icon);
            } catch (Error error) {
                request.finish_error (error);
                critical ("Failed to load icon %s: %s", icon_name, error.message);
            }
            request.unref ();
        }

        internal WebKit.WebContext ephemeral_context () {
            var context = new WebKit.WebContext.ephemeral ();
            context.register_uri_scheme ("internal", (request) => {
                request.ref ();
                private_scheme.begin (request);
            });
            context.register_uri_scheme ("stock", (request) => {
                request.ref ();
                stock_scheme.begin (request);
            });
            context.register_uri_scheme ("res", (request) => {
                try {
                    var stream = resources_open_stream (request.get_path (),
                                                        ResourceLookupFlags.NONE);
                    request.finish (stream, -1, null);
                } catch (Error error) {
                    request.finish_error (error);
                    critical ("Failed to load resource %s: %s", request.get_uri (), error.message);
                }
            });
            return context;
        }

        async void private_scheme (WebKit.URISchemeRequest request) {
            string[] suggestions = {
                _("No history or web cookies are being saved."),
                _("Extensions are disabled."),
                _("HTML5 storage, local database and application caches are disabled."),
            };
            string[] notes = {
                _("Referrer URLs are stripped down to the hostname."),
                _("DNS prefetching is disabled."),
                _("The language and timezone are not revealed to websites."),
                _("Flash and other Netscape plugins cannot be listed by websites."),
            };

            try {
                string description = "<ul>";
                foreach (var suggestion in suggestions) {
                    description += "<li>%s</li>".printf (suggestion);
                }
                description += "</ul>";
                description += "<b>%s</b><br>".printf (_("Midori prevents websites from tracking the user:"));
                description += "<ul>";
                foreach (var note in notes) {
                    description += "<li>%s</li>".printf (note);
                }
                description += "</ul>";
                string stylesheet = (string)resources_lookup_data ("/data/about.css",
                                                                    ResourceLookupFlags.NONE).get_data ();
                string html = ((string)resources_lookup_data ("/data/error.html",
                                                             ResourceLookupFlags.NONE).get_data ())
                    .replace ("{title}", _("Private Browsing"))
                    .replace ("{icon}", "user-not-tracked")
                    .replace ("{message}", _("Midori doesn't store any personal data:"))
                    .replace ("{description}", description)
                    .replace ("{tryagain}", "")
                    .replace ("{stylesheet}", stylesheet);
                var stream = new MemoryInputStream.from_data (html.data, free);
                request.finish (stream, html.length, "text/html");
            } catch (Error error) {
                request.finish_error (error);
                critical ("Failed to render %s: %s", request.get_uri (), error.message);
            }
            request.unref ();
        }

        void win_new_activated (Action action, Variant? parameter) {
            var browser = incognito
                ? new Browser.incognito (this)
                : new Browser (this);
            string? uri = parameter.get_string () != "" ? parameter.get_string () : null;
            browser.add (new Tab (null, browser.web_context, uri));
            browser.show ();
        }

        void win_incognito_new_activated () {
            var browser = new Browser.incognito (this);
            browser.add (new Tab (null, browser.web_context));
            browser.show ();
        }

        void quit_activated () {
            quit ();
        }

        protected override void activate () {
            if (incognito) {
                activate_action ("win-incognito-new", null);
                return;
            }
            activate_action ("win-new", "");
        }

        protected override void open (File[] files, string hint) {
            var browser = incognito
                ? new Browser.incognito (this)
                : (active_window as Browser ?? new Browser (this));
            foreach (File file in files) {
                browser.add (new Tab (browser.tab, browser.web_context, file.get_uri ()));
            }
            browser.show ();
        }

        protected override int handle_local_options (VariantDict options) {
            if (version) {
                stdout.printf ("%s %s\n" +
                               "Copyright 2007-2018 Christian Dywan\n" +
                               "Please report comments, suggestions and bugs to:\n" +
                               "    %s\n" +
                               "Check for new versions at:\n" +
                               "    %s\n ",
                    Config.PROJECT_NAME, Config.CORE_VERSION,
                    Config.PROJECT_BUGS, Config.PROJECT_WEBSITE);
                return 0;
            }

            // Propagate options processed in the primary instance
            options.insert_value ("app", app ?? "");
            options.insert_value ("execute", execute);
            options.insert_value ("help-execute", help_execute);
            options.insert_value ("private", incognito);
            return -1;
        }

        protected override int command_line (ApplicationCommandLine command_line) {
            hold ();

            // Retrieve values for options passed from another process
            var options = command_line.get_options_dict ();
            app = options.lookup_value ("app", VariantType.STRING).get_string ();
            execute = options.lookup_value ("execute", VariantType.STRING_ARRAY).dup_strv ();
            help_execute = options.lookup_value ("help-execute", VariantType.BOOLEAN).get_boolean ();
            incognito = options.lookup_value ("private", VariantType.BOOLEAN).get_boolean ();
            debug ("Processing remote command line %s/ %s\n",
                   string.joinv (", ", command_line.get_arguments ()), options.end ().print (true));

            if (help_execute) {
                foreach (string action in list_actions ()) {
                    command_line.print ("%s\n", action);
                }
                var browser = incognito ? new Browser.incognito (this) : new Browser (this);
                foreach (string action in browser.list_actions ()) {
                    command_line.print ("%s\n", action);
                }
            }

            if (app != "") {
                var browser = new Browser (this);
                browser.is_locked = true;
                var tab = new Tab (null, browser.web_context, app);
                tab.pinned = true;
                browser.add (tab);
                browser.show ();
            }

            uint argc = command_line.get_arguments ().length;
            if (argc <= 1) {
                if (active_window == null) {
                    activate ();
                }
            } else {
                var files = new File[argc - 1];
                uint i = 0;
                foreach (string argument in command_line.get_arguments ()) {
                    // Skip program name
                    if (i > 0) {
                        files[i - 1] = File.new_for_commandline_arg (argument);
                    }
                    i++;
                }
                open (files, "");
            }

            var action_group = active_window as ActionGroup;
            foreach (string action_ in execute) {
                // Accept action names regardless of case
                string action = action_.down ();
                debug ("Executing %s\n", action);
                if (action_group.has_action (action)) {
                    action_group.activate_action (action, null);
                } else {
                    warning (_("Unexpected action '%s'.").printf (action));
                }
            }

            release ();
            return  0;
        }
    }
}
