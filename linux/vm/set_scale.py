#!/usr/bin/env python3
"""Sets the VM's monitor scale through Mutter's DisplayConfig D-Bus API (fractional scaling must be
on: org.gnome.mutter experimental-features 'scale-monitor-framebuffer').  set_scale.py 1.25"""
import sys
from gi.repository import Gio, GLib
want = float(sys.argv[1])
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
def call(method, args=None):
    return bus.call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig", "org.gnome.Mutter.DisplayConfig",
                         method, args, None, Gio.DBusCallFlags.NONE, 5000, None).unpack()
serial, monitors, logical, _props = call("GetCurrentState")
(connector, *_), modes, _mprops = monitors[0]
mode = next(m for m in modes if m[6].get("is-current"))
scales = mode[5]
scale = min(scales, key=lambda s: abs(s - want))
print("connector", connector, "mode", mode[0], "scales", [round(s, 3) for s in scales], "->", scale)
call("ApplyMonitorsConfig", GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})",
     (serial, 1, [(0, 0, scale, 0, True, [(connector, mode[0], {})])], {})))
