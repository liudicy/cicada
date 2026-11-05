#!/usr/bin/env python3
"""A stand-in for a full-screen video player: a native-Wayland GTK window, full screen, black."""
import os
os.environ["GDK_BACKEND"] = "wayland"
import gi  # noqa: E402
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402
w = Gtk.Window(title="Full-screen player (probe)")
w.override_background_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(0.05, 0.05, 0.08, 1))
l = Gtk.Label(label="FULL SCREEN VIDEO")
l.override_color(Gtk.StateFlags.NORMAL, Gdk.RGBA(1, 1, 1, 1))
w.add(l)
w.connect("destroy", Gtk.main_quit)
w.show_all()
w.fullscreen()
Gtk.main()
