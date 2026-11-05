"""The look: the Mac app's, drawn with GTK (canvas "知了 Linux · 对齐 Mac"). Its palette (AGENTS.md ›
Design): ground #F3F4F6, white sheets, ink #15171C, one accent #E8552B for "live", greys #5A5F6B /
#6B7080. Sizes are the Mac's numbers in px (text() turns them into points, which GTK renders 4/3
larger); every widget the theme would draw (switches, dropdowns, title buttons) is styled here, so
Yaru's orange and its large controls never show."""
from __future__ import annotations

import math

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gio, GLib, Gtk, Pango  # noqa: E402

CSS = b"""
* { font-family: "Noto Sans", sans-serif; font-size: 13px; }
.ground { background-color: #F3F4F6; }
.sheet, .sheet viewport { background-color: #FFFFFF; }
.soft-bar { background-color: #F3F4F6; }

/* Header bars: flat, the window buttons small glyphs (the Mac's quiet chrome, not Yaru's discs). */
headerbar.cicada { background-image: none; background-color: #FFFFFF; border: none; box-shadow: none; min-height: 44px; padding: 0 6px; }
headerbar.cicada.ground-bar { background-color: #F3F4F6; }
headerbar.cicada .title { font-weight: 700; font-size: 13px; color: #15171C; }
headerbar.cicada button.titlebutton { background-image: none; background-color: transparent; border: none; box-shadow: none; min-width: 26px; min-height: 26px; padding: 0; margin: 0 1px; border-radius: 6px; color: #6B7080; -gtk-icon-shadow: none; }
headerbar.cicada button.titlebutton:hover { background-color: rgba(21,23,28,0.07); color: #15171C; }
headerbar.cicada button.titlebutton image { -gtk-icon-transform: scale(0.8); }
headerbar.cicada separator { background: none; min-width: 4px; }
headerbar.records-bar { padding-left: 0; }
.sidebar-top { background-color: #F3F4F6; border-right: 1px solid #E4E6EA; margin: 0; }

.ink { color: #15171C; }
.body { color: #3D4149; }
.secondary { color: #5A5F6B; }
.tertiary { color: #6B7080; }
.accent { color: #E8552B; }
.link { color: #B33A14; }
.warn { color: #B23A12; }
.ok { color: #1F6B3A; }
.heading { font-weight: 700; color: #15171C; }
.mono { font-family: "Ubuntu Sans Mono", monospace; }

/* Buttons: 28 px, 12 px text, 7 px corners, as on the Mac. */
button { min-height: 22px; font-size: 12px; -gtk-icon-shadow: none; text-shadow: none; }
button.pill { border-radius: 14px; padding: 3px 12px; }
button.accentbtn { background-image: none; background-color: #E8552B; color: #FFFFFF; border: none; box-shadow: none; font-weight: 500; }
button.accentbtn:hover { background-color: #D44A22; }
button.accentbtn image, button.darkbtn image { color: #FFFFFF; }
button.darkbtn { background-image: none; background-color: #15171C; color: #FFFFFF; border: none; box-shadow: none; border-radius: 7px; padding: 4px 14px; }
button.darkbtn:hover { background-color: #2A2D34; }
button.darkbtn.pill { border-radius: 14px; }
button.livepill { background-image: none; background-color: #FDEEE8; color: #B33A14; border: none; box-shadow: none; }
button.outline { background-image: none; background-color: #FFFFFF; border: 1px solid #E4E6EA; box-shadow: none; border-radius: 7px; padding: 3px 10px; color: #15171C; }
button.outline:hover { background-color: #F6F7F9; }
button.quietbtn { background-image: none; background-color: transparent; border: none; box-shadow: none; border-radius: 7px; padding: 3px 8px; color: #15171C; }
button.quietbtn:hover { background-color: rgba(21,23,28,0.06); }
button.dangertext { background-image: none; background-color: transparent; border: none; box-shadow: none; color: #B3261E; padding: 3px 10px; }
button.dangertext:hover { background-color: rgba(179,38,30,0.07); }
button.iconbtn { background-image: none; background-color: transparent; border: none; box-shadow: none; border-radius: 7px; min-width: 28px; min-height: 28px; padding: 0; color: #5A5F6B; }
button.iconbtn:hover { background-color: rgba(21,23,28,0.07); color: #15171C; }
button.iconbtn.stop { background-color: #FDEEE8; color: #E8552B; }
button.iconbtn.stop image { color: #E8552B; }
button.linkrow { background-image: none; background-color: transparent; border: none; box-shadow: none; border-radius: 0; padding: 0; }
button.linkrow:hover { background-color: #F6F7F9; }

/* The widgets the theme would draw. */
switch { background-image: none; background-color: #D5D8DE; border: none; box-shadow: none; border-radius: 10px; min-width: 15px; min-height: 18px; font-size: 0; color: transparent; }
switch:checked { background-color: #15171C; }
switch slider { background-image: none; background-color: #FFFFFF; border: none; border-radius: 8px; min-width: 14px; min-height: 14px; margin: 2px; box-shadow: 0 1px 2px rgba(0,0,0,0.25); }
switch image { color: transparent; -gtk-icon-transform: scale(0); }
combobox button, combobox button.combo { background-image: none; background-color: #FFFFFF; border: 1px solid #E4E6EA; box-shadow: none; border-radius: 6px; min-height: 22px; padding: 1px 6px 1px 8px; color: #15171C; }
combobox button:hover { background-color: #F6F7F9; }
combobox arrow { -gtk-icon-source: -gtk-icontheme("pan-down-symbolic"); min-width: 12px; min-height: 12px; color: #6B7080; }
combobox cellview, combobox button label { font-size: 12px; }
entry { background-image: none; background-color: #FFFFFF; border: 1px solid #E4E6EA; box-shadow: none; border-radius: 7px; min-height: 26px; padding: 0 9px; font-size: 13px; color: #15171C; caret-color: #15171C; }
entry:focus { border-color: #E8552B; box-shadow: 0 0 0 2px rgba(232,85,43,0.18); }
entry.search { background-color: #E8EAEE; border-color: transparent; min-height: 28px; font-size: 12px; }
entry.search:focus { background-color: #FFFFFF; }
entry selection, label selection { background-color: rgba(232,85,43,0.22); color: #15171C; }
popover, popover.background { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 10px; box-shadow: 0 8px 24px rgba(21,23,28,0.14); padding: 0; }
menu, .menu, .context-menu { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 8px; padding: 4px; }
menu menuitem, .menu menuitem { font-size: 13px; padding: 4px 10px; border-radius: 5px; min-height: 22px; color: #15171C; }
menu menuitem:hover, .menu menuitem:hover { background-color: #F2F3F5; color: #15171C; }
menu menuitem:disabled label { color: #6B7080; font-size: 11px; }
scrollbar { background-color: transparent; border: none; }
scrollbar slider { background-color: rgba(21,23,28,0.22); border: none; border-radius: 4px; min-width: 6px; min-height: 6px; }
scrollbar slider:hover { background-color: rgba(21,23,28,0.38); }
tooltip, tooltip.background { background-color: #15171C; border-radius: 6px; border: none; box-shadow: none; }
tooltip label { color: #FFFFFF; font-size: 12px; }
spinner { color: #6B7080; }

.segmented { background-color: #F2F3F5; border-radius: 8px; padding: 2px; }
.segmented button { background-image: none; background-color: transparent; border: none; box-shadow: none; border-radius: 6px; min-height: 22px; padding: 0 10px; color: #5A5F6B; font-size: 12px; }
.segmented.big { border-radius: 10px; padding: 3px; }
.segmented.big button { min-height: 28px; border-radius: 8px; font-size: 13px; }
.segmented button:checked label { font-weight: 700; color: #15171C; }
.panel.dark .segmented { background-color: #2A2C32; }
.panel.dark .segmented button:checked { background-color: #3A3D45; }
.panel.dark .segmented button:checked label { color: #F2F3F5; }
.segmented button:checked { background-color: #FFFFFF; color: #15171C; box-shadow: 0 1px 2px rgba(0,0,0,0.10); font-weight: 500; }

.endingstrip { background-color: #FDEEE8; border-radius: 12px; }
.notice { background-color: #F2F3F5; border-radius: 12px; }
dialog.endask { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 12px; }
.notice.error { background-color: #FDECEA; }
.panel.dark .endingstrip { background-color: rgba(232,85,43,0.16); }
entry.notes-search { min-height: 32px; font-size: 13px; border-radius: 9px; }
.panel.dark entry.notes-search { background-color: #2A2C32; color: #F2F3F5; }
button.iconbtn.on { background-color: #F3F4F6; color: #15171C; }
.panel.dark button.iconbtn.on { background-color: #34363D; }
.wide > scrolledwindow:first-child { border-right: 1px solid #EEF0F3; }
.boxed { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 12px; }
.prow-top { border-top: 1px solid #EEF0F3; }
.warnrow { background-color: #FFF8F3; border-radius: 0 0 12px 12px; }
.warnrow label { color: #5A2A16; }
.group-title { font-weight: 700; color: #6B7080; }

.chip { background-color: #F2F3F5; border-radius: 5px; padding: 1px 6px; color: #15171C; }
.chip.now { background-color: #E8552B; color: #FFFFFF; }
.chip.time { background-color: transparent; padding: 0; color: #B33A14; }
.badge { background-color: #FDEEE8; border-radius: 5px; padding: 0 6px; color: #B33A14; }
.softcard { background-color: #F5F6F8; border-radius: 12px; }
.summarycard { background-color: #F5F6F8; border-radius: 12px; }
.icon-tile { background-color: #FDEEE8; border-radius: 16px; }
.icon-tile image { color: #E8552B; }
.icon-tile.grey { background-color: #F3F4F6; }
.icon-tile.grey image { color: #5A5F6B; }
.icon-tile.warn { background-color: #FDEEE8; }
.icon-tile.warn image { color: #B23A12; }
.wavebar { background-color: #C9CCD3; border-radius: 3px; }
.wavebar.on { background-color: #E8552B; }
.dotstep { background-color: #C9CCD3; border-radius: 3px; min-width: 6px; min-height: 6px; }
.dotstep.on { background-color: #E8552B; min-width: 18px; }
.livedot { background-color: #E8552B; border-radius: 4px; min-width: 7px; min-height: 7px; box-shadow: 0 0 0 3px rgba(232,85,43,0.18); }
/* "Live" without blinking (BreathingDot / BreathingMark): a ring swells out and fades. GTK has no
   transforms, so the ring is a growing box-shadow; GNOME's Reduce Animation turns CSS animations off. */
@keyframes breathe-dot { from { box-shadow: 0 0 0 0 rgba(232,85,43,0.6); } to { box-shadow: 0 0 0 6px rgba(232,85,43,0); } }
/* BreathingMark scales a logo-sized rounded square 1 -> 1.7 behind the 22 px logo: what shows is a band
   growing to 7.7 px, which is what a spread shadow from the logo's own rounded edge draws. */
@keyframes breathe-mark { from { box-shadow: 0 0 0 0 rgba(232,85,43,0.55); } to { box-shadow: 0 0 0 8px rgba(232,85,43,0); } }
/* BreathingDot (6 px, ring 1 -> 2.6): a 4.8 px band. */
@keyframes breathe-dot6 { from { box-shadow: 0 0 0 0 rgba(232,85,43,0.6); } to { box-shadow: 0 0 0 5px rgba(232,85,43,0); } }
.livedot.small { min-width: 6px; min-height: 6px; border-radius: 3px; box-shadow: none; }
.livedot.small.breathing { animation: breathe-dot6 2s ease-out infinite; }
.livedot.breathing { animation: breathe-dot 2s ease-out infinite; }
.breathemark { border-radius: 6px; animation: breathe-mark 2.2s ease-out infinite; }
.breathemark.late { animation-delay: 1.1s; }
.idledot { background-color: #C9CCD3; border-radius: 4px; min-width: 7px; min-height: 7px; }

.sidebar { background-color: #F3F4F6; border-right: 1px solid #E4E6EA; }
.sidebar list, .sidebar viewport { background-color: #F3F4F6; }
.sidebar list row { border-radius: 8px; margin: 0 10px; padding: 0; }
.sidebar list row:selected, .sidebar list row:selected:hover { background-color: #E3E5EA; }
.sidebar list row:selected label { color: #15171C; }
.sidebar list row:hover { background-color: #ECEEF1; }
.group-label { font-weight: 700; color: #6B7080; }
.transcript-row { border-top: 1px solid #EEF0F3; }
.spk1 { color: #0F7B6C; } .spk2 { color: #7A4CC2; } .spk3 { color: #B03A7A; } .spk4 { color: #8A5A00; }
button.spkchip { background-image: none; background-color: #F2F3F5; border: none; box-shadow: none; border-radius: 11px; padding: 0 9px; min-height: 22px; }
button.spkchip:hover { background-color: #E8EAEE; }
button.spklabel { background-image: none; background-color: transparent; border: none; box-shadow: none; padding: 0 4px 0 0; min-height: 0; }
button.spklabel:hover { background-color: #F3F4F6; }
button.pick { background-image: none; background-color: #FFFFFF; border: 1px solid #E4E6EA; box-shadow: none; border-radius: 7px; padding: 1px 9px; min-height: 24px; }
button.pick.chosen { background-color: #15171C; color: #FFFFFF; border-color: #15171C; }
button.underline label { text-decoration-line: underline; }

/* The listening capsule in the records window's header (ListenPill.swift). */
button.listenpill { background-image: none; background-color: #FFFFFF; border: 1px solid #E4E6EA; box-shadow: none; border-radius: 16px; min-height: 30px; padding: 0 12px 0 6px; }
button.listenpill:hover { background-color: #F8F9FA; }
.listenpill.live { background-color: #15171C; border-radius: 16px; padding: 4px 4px 4px 5px; min-height: 24px; }
/* monospacedDigit: the clock and the countdown don't shift every second. */
.listenpill.live.ending { padding-left: 4px; }
label.tnum { font-feature-settings: "tnum"; }
label.err { color: #B23A12; }
/* In the header bar Yaru pads every button to 36 px; the capsule's are the Mac's 24. */
headerbar .listenpill.live button.pillshow, headerbar .listenpill.live button.pillend, headerbar .listenpill.live button.pillkeep {
  min-height: 24px; margin: 0; padding-top: 0; padding-bottom: 0; border: none; }
headerbar .listenpill.live button.pillshow { padding: 0; }
.listenpill.live label { color: #FFFFFF; }
button.pillshow { background-image: none; background-color: transparent; border: none; box-shadow: none; padding: 0; min-height: 24px; }
button.pillend { background-image: none; background-color: #2F323A; color: #FFFFFF; border: none; box-shadow: none; border-radius: 12px; min-height: 24px; padding: 0 12px; font-weight: 700; }
button.pillend:hover { background-color: #3A3D46; }
button.pillend label { color: #FFFFFF; }
button.pillkeep { background-image: none; background-color: #FFFFFF; color: #15171C; border: none; box-shadow: none; border-radius: 12px; min-height: 24px; padding: 0 12px; font-weight: 700; }
button.pillkeep:hover { background-color: #ECEEF1; }
button.pillkeep label { color: #15171C; }
.listenpill.live button.pillkeep label { color: #15171C; }
.listenpill.live label.countdown { color: #F4A58C; }
.listenpill.live label.dim { color: #BDC0C7; }
.pillsep { background-color: #E4E6EA; min-width: 1px; min-height: 14px; }
.meterbar { background-color: #E8552B; border-radius: 2px; }
.toast { background-color: #15171C; border-radius: 10px; padding: 2px 4px 2px 14px; box-shadow: 0 6px 18px rgba(0,0,0,0.22); }
.toast label { color: #F2F3F5; }
.toast button { background-image: none; background-color: rgba(255,255,255,0.12); color: #FFFFFF; border: none; box-shadow: none; border-radius: 6px; padding: 1px 10px; }
.toast button label { color: #FFFFFF; }

.notes-window { background-color: transparent; }
.panel .speakbox { background-color: #FDEEE8; border-radius: 12px; }
.panel.dark .speakbox { background-color: rgba(232,85,43,0.14); }
.panel { background-color: #FFFFFF; border-radius: 14px; border: 1px solid #E4E6EA; }
/* The live caption: a dark card at the bottom of the notes window, as on the Mac. */
.panel .livebox { background-color: #15171C; border-radius: 14px; }
.panel .livebox .ink, .panel .livebox .heading { color: #FFFFFF; }
.panel .livebox .secondary, .panel .livebox .tertiary { color: #BDC0C7; }
.panel .livebox .accent { color: #F08A6C; }
.panel .livebox .spk1 { color: #5CC8B5; } .panel .livebox .spk2 { color: #B79BF0; }
.panel .livebox .spk3 { color: #F08FBF; } .panel .livebox .spk4 { color: #E3B45C; }
.panel .livebox .icon-tile.grey { background-color: #2A2C32; }
.panel .livebox .icon-tile.grey image, .panel .livebox .icon-tile.warn image { color: #BDC0C7; }
.panel .livebox .icon-tile.warn { background-color: rgba(232,85,43,0.22); }
.panel .livebox button.outline { background-color: #2A2C32; border-color: #3A3C43; color: #F2F3F5; }
.panel .livebox.light { background-color: #F3F4F6; }
.panel .livebox.light .ink, .panel .livebox.light .heading { color: #15171C; }
.panel .livebox.light .secondary, .panel .livebox.light .tertiary { color: #5A5F6B; }
.panel .livebox.light .icon-tile.grey { background-color: #FFFFFF; }
.panel .livebox.light .icon-tile.grey image { color: #5A5F6B; }
.panel .livebox.light .icon-tile.warn image { color: #B23A12; }
.panel .livebox.light button.outline { background-color: #FFFFFF; border-color: #E4E6EA; color: #15171C; }
.panel .footer { border-top: none; }
.panel.dark .livebox.light { background-color: #2A2C32; }
.panel.dark .livebox.light .ink, .panel.dark .livebox.light .heading { color: #F2F3F5; }
.panel.dark .livebox.light .secondary, .panel.dark .livebox.light .tertiary { color: #A3A7B1; }
.panel.dark .livebox.light .icon-tile.grey { background-color: #34363D; }
.panel.dark .livebox.light .icon-tile.grey image { color: #A3A7B1; }
.panel.dark .livebox.light button.outline { background-color: #34363D; border-color: #3A3C43; color: #F2F3F5; }
.panel.dark { background-color: #1F2025; border-color: #34363D; }
.panel.dark .livebox { background-color: #2E3037; }
.panel.dark .ink, .panel.dark .heading, .panel.dark button.iconbtn, .panel.dark button.iconbtn image { color: #F2F3F5; }
.panel.dark .body { color: #D4D6DB; }
.panel.dark .secondary, .panel.dark .tertiary { color: #A3A7B1; }
.panel.dark .chip { background-color: #34363D; color: #F2F3F5; }
.panel.dark .chip.now { background-color: #E8552B; }
.panel.dark .chip.time { background-color: transparent; color: #F08A6C; }
.panel.dark .link { color: #F08A6C; }
.panel.dark .badge { background-color: rgba(232,85,43,0.18); color: #F08A6C; }
.panel.dark button.iconbtn:hover { background-color: rgba(255,255,255,0.08); }
.panel.dark button.iconbtn.stop { background-color: rgba(232,85,43,0.18); }
.panel.dark button.iconbtn.stop image { color: #E8552B; }
.panel.dark .icon-tile.grey { background-color: #34363D; }
.panel.dark .icon-tile.grey image { color: #A3A7B1; }
.panel.dark .icon-tile.warn { background-color: rgba(232,85,43,0.16); }
.panel.dark button.outline { background-color: #2A2C32; border-color: #3A3C43; color: #F2F3F5; }

levelbar trough { min-height: 6px; padding: 0; border: none; background-color: #ECEEF1; border-radius: 3px; }
levelbar block { min-height: 6px; border: none; border-radius: 3px; }
levelbar block.filled, levelbar block.low, levelbar block.high, levelbar block.full { background-color: #E8552B; }
levelbar block.empty { background-color: transparent; }
entry.keyentry { border-radius: 10px; min-height: 34px; }

/* Onboarding (Onboarding.swift): 860 x 640 on the ground, white 18 px cards, a 44 px ink button. */
.stepbar { background-color: #DDDEE2; border-radius: 2px; min-height: 4px; }
.stepbar.on { background-color: #15171C; }
.bigcard { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 18px; }
.midcard { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 12px; }
.tipcard { background-color: #FFFFFF; border-radius: 14px; }
.hair { background-color: #E4E6EA; min-height: 1px; }
.srccard { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 14px; }
.srccard.on { border: 2px solid #15171C; }
.srcbadge { background-color: #F3F4F6; border-radius: 5px; padding: 0 6px; }
.srcbadge label { color: #5A5F6B; }
.srcstep { background-color: #F3F4F6; border-radius: 6px; padding: 1px 7px 2px 7px; }
.srcstep label { color: #15171C; }
.srcstep.on { background-color: #15171C; }
.srcstep.on label { color: #FFFFFF; }
.srccard flowbox, .srccard flowboxchild { padding: 0; background: none; }
button.quietbtn.greytext label { color: #5A5F6B; }
button.ctapill { background-image: none; background-color: #15171C; border: none; box-shadow: none; border-radius: 22px; min-height: 44px; padding: 0 22px; }
button.ctapill:hover { background-color: #2A2D34; }
button.ctapill label { color: #FFFFFF; }
.ctakeys { border: 1px solid rgba(255,255,255,0.35); border-radius: 5px; }
.ctakeys label { color: #BDC0C7; }
.setupcard { background-color: #F7F8FA; border-radius: 16px; }
.setupdisc { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 13px; }
.setupdisc label { color: #3A3E48; }
.setupdisc.done { background-color: #15171C; border-color: #15171C; }
.setupdisc.done image { color: #FFFFFF; }
.setupdisc.now { background-color: #E8552B; border-color: #E8552B; }
.setupdisc.now label { color: #FFFFFF; }
.setuptag { background-color: #FFFFFF; border: 1px solid #E4E6EA; border-radius: 9px; padding: 0 7px; }
.stepnum { background-color: #15171C; border-radius: 12px; min-width: 24px; min-height: 24px; }
.stepnum label { color: #FFFFFF; }
button.bigbtn { background-image: none; background-color: #15171C; color: #FFFFFF; border: none; box-shadow: none; border-radius: 12px; min-height: 44px; padding: 0 28px; font-size: 14px; font-weight: 700; }
button.bigbtn:hover { background-color: #2A2D34; }
button.bigbtn label, button.bigbtn image { color: #FFFFFF; }
button.bigbtn.waiting { background-color: #DDDEE2; }
button.bigbtn.waiting label, button.bigbtn.waiting image { color: #5A5F6B; }
button.bigquiet { font-size: 13px; color: #5A5F6B; }
button.bigquiet label { color: #5A5F6B; }
button.midbtn { min-height: 36px; border-radius: 10px; padding: 0 16px; font-size: 13px; font-weight: 700; }
button.outline.midbtn { border-color: #D6D6D6; }
.samplestage { background-color: #23262D; border-radius: 18px; }
.stage-dim { color: #BDC0C7; }
.stage-ink { color: #FFFFFF; }
button.bigplay { min-height: 36px; border-radius: 18px; padding: 0 18px; font-size: 13px; }
button.bigplay image { color: #15171C; }
button.choicecard { background-image: none; background-color: #FFFFFF; border: 1px solid #E4E6EA; box-shadow: none; border-radius: 16px; padding: 0; }
button.choicecard:hover { border-color: #15171C; }
.keycap { background-color: #FFFFFF; border: 1px solid #D6D6D6; border-bottom-width: 4px; border-radius: 10px; }
.topbar { background-color: #1D1E22; border-radius: 17px 17px 0 0; }
.topbar-ink { color: #E9EAEE; }
.topbar-pill { background-color: #34363C; border-radius: 10px; }
.topbar-ring { background-color: rgba(232,85,43,0.22); border: 1.5px solid #E8552B; border-radius: 7px; }
"""


def install_css() -> None:
    provider = Gtk.CssProvider()
    provider.load_from_data(CSS)
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def prefers_dark() -> bool:
    """GNOME's 外观 › 深色 (org.gnome.desktop.interface color-scheme), else the GTK theme's name."""
    try:
        source = Gio.SettingsSchemaSource.get_default()
        if source and source.lookup("org.gnome.desktop.interface", True):
            s = Gio.Settings.new("org.gnome.desktop.interface")
            if "color-scheme" in s.list_keys() and s.get_string("color-scheme") == "prefer-dark":
                return True
    except GLib.Error:
        pass
    theme = Gtk.Settings.get_default().get_property("gtk-theme-name") or ""
    return theme.lower().endswith("-dark")


def classes(widget, *names):
    ctx = widget.get_style_context()
    for n in names:
        for one in (n or "").split():
            ctx.add_class(one)
    return widget


# The language text is tagged with, so fontconfig picks the matching CJK face: Japanese kanji drawn
# with the Chinese font look wrong to a Japanese reader (and the other way round). No CJK family is
# named in the CSS for that reason. Set from the UI language at start; content passes its own.
DEFAULT_LANG = "zh-cn"


def pango_lang(code: str | None) -> str:
    c = (code or "").lower()
    if c.startswith("zh"):
        return "zh-tw" if ("tw" in c or "hant" in c or "hk" in c) else "zh-cn"
    return c.split("-")[0] or DEFAULT_LANG


def text(s: str, size: int = 13, cls: str = "ink", bold: bool = False, wrap: bool = True, selectable: bool = False,
         ellipsize: bool = True, width_chars: int = 40, lang: str | None = None) -> Gtk.Label:
    l = Gtk.Label()
    l.set_xalign(0)
    l.cicada_format = (size, pango_lang(lang) if lang else DEFAULT_LANG, bold)
    retext(l, s)
    classes(l, cls)
    if wrap:
        l.set_line_wrap(True)
        l.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        # Wrapped text asks for a modest width and takes what it's given, so a long English line
        # doesn't stretch its window.
        l.set_max_width_chars(width_chars)
    elif ellipsize:
        l.set_ellipsize(Pango.EllipsizeMode.END)
    l.set_selectable(selectable)
    return l


def retext(l: Gtk.Label, s: str) -> None:
    """New text in a label made by text(), keeping its size, weight and language (set_text would drop them)."""
    size, lang, bold = l.cicada_format
    # `size` is the Mac's number, in px: Pango sizes are points (4/3 px at 96 dpi), so 0.75 of it;
    # in points, GNOME's text scaling still applies. Bold is the Mac's semibold (Noto has no 600).
    l.set_markup('<span size="%d" lang="%s"%s>%s</span>' % (round(size * 768), lang, ' weight="bold"' if bold else "", esc(s)))


def marked(s: str, terms: list, size: int = 13, cls: str = "ink", current: bool = False, lang: str | None = None) -> Gtk.Label:
    """text() with every search term highlighted in place (the current match in the accent)."""
    l = text(s, size, cls, lang=lang)
    low = s.lower()
    spans = []
    for t in terms:
        t = t.lower()
        i = low.find(t) if t else -1
        while i >= 0:
            spans.append((i, i + len(t)))
            i = low.find(t, i + len(t))
    if not spans:
        return l
    spans.sort()
    merged = []
    for a, b in spans:
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
        else:
            merged.append((a, b))
    mark = ' background="#E8552B" foreground="#FFFFFF"' if current else ' background="#FBE0D5"'
    out, at = [], 0
    for a, b in merged:
        out.append(esc(s[at:a]))
        out.append("<span%s>%s</span>" % (mark, esc(s[a:b])))
        at = b
    out.append(esc(s[at:]))
    size_, lang_, bold = l.cicada_format
    l.set_markup('<span size="%d" lang="%s"%s>%s</span>' % (round(size_ * 768), lang_, ' weight="bold"' if bold else "", "".join(out)))
    return l


def helper(s: str) -> Gtk.Label:
    return text(s, 11, "tertiary")


def heading(s: str, size: int = 16) -> Gtk.Label:
    return text(s, size, "heading", bold=True)


def esc(s: str) -> str:
    return GLib.markup_escape_text(s)


def icon(name: str, px: int = 16) -> Gtk.Image:
    img = Gtk.Image.new_from_icon_name(name, Gtk.IconSize.BUTTON)
    img.set_pixel_size(px)
    return img


def button(label: str, on_click, style: str = "outline", icon_name: str | None = None) -> Gtk.Button:
    b = Gtk.Button()
    if icon_name:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        box.pack_start(icon(icon_name, 16), False, False, 0)
        box.pack_start(Gtk.Label(label=label), False, False, 0)
        box.set_halign(Gtk.Align.CENTER)
        b.add(box)
    else:
        b.set_label(label)
    for s in style.split():
        classes(b, s)
    b.connect("clicked", lambda *_: on_click())
    return b


def icon_button(icon_name: str, tooltip: str, on_click, extra: str = "", px: int = 15, focus: bool = True) -> Gtk.Button:
    b = Gtk.Button()
    b.add(icon(icon_name, px))
    b.set_tooltip_text(tooltip)
    b.get_accessible().set_name(tooltip)
    classes(b, "iconbtn", extra)
    b.set_can_focus(focus)
    b.connect("clicked", lambda *_: on_click())
    return b


def link(label: str, on_click) -> Gtk.Button:
    """A text action inside a sentence: rendered as a flat link-coloured button."""
    b = Gtk.Button(label=label)
    classes(b, "quietbtn")
    b.set_relief(Gtk.ReliefStyle.NONE)
    b.connect("clicked", lambda *_: on_click())
    return b


def dot(live: bool) -> Gtk.Widget:
    d = Gtk.Box()
    d.set_size_request(9, 9)
    d.set_valign(Gtk.Align.CENTER)
    classes(d, "livedot" if live else "idledot")
    return d


def vbox(spacing: int = 0, *children) -> Gtk.Box:
    b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)
    for c in children:
        b.pack_start(c, False, False, 0)
    return b


def hbox(spacing: int = 0, *children) -> Gtk.Box:
    b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)
    for c in children:
        b.pack_start(c, False, False, 0)
    return b


def pad(widget, top: int, right: int | None = None, bottom: int | None = None, left: int | None = None):
    right = top if right is None else right
    bottom = top if bottom is None else bottom
    left = right if left is None else left
    widget.set_margin_top(top)
    widget.set_margin_end(right)
    widget.set_margin_bottom(bottom)
    widget.set_margin_start(left)
    return widget


def gap(widget, top: int):
    widget.set_margin_top(top)
    return widget


def clear(box: Gtk.Container) -> None:
    for c in box.get_children():
        box.remove(c)
        c.destroy()


def panel(widget, *cls) -> Gtk.EventBox:
    """A styled container (GTK 3 boxes don't draw backgrounds; an EventBox does)."""
    e = Gtk.EventBox()
    e.add(widget)
    classes(e, *cls)
    return e


def segmented(options, current, on_change) -> Gtk.Box:
    """Two or three linked toggles, one checked: GNOME's view switcher in miniature."""
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
    classes(box, "segmented")
    buttons = {}
    lock = {"busy": False}

    def toggled(btn, value):
        if lock["busy"]:
            return
        lock["busy"] = True
        for v, b in buttons.items():
            b.set_active(v == value)
        lock["busy"] = False
        on_change(value)
    for value, label in options:
        b = Gtk.ToggleButton(label=label)
        b.set_active(value == current)
        b.connect("toggled", toggled, value)
        buttons[value] = b
        box.pack_start(b, False, False, 0)
    return box


def boxed(rows) -> Gtk.Widget:
    """A boxed list: rows separated by hairlines inside one rounded white card."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    for i, r in enumerate(rows):
        if i:
            classes(r, "prow-top")
        box.pack_start(r, False, False, 0)
    return panel(box, "boxed")


def prow(title: str, control: Gtk.Widget | None = None, subtitle: str | None = None, title_widget=None) -> Gtk.Widget:
    """One preferences row: title (and a grey subtitle) on the left, its control on the right."""
    row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
    left = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
    left.set_valign(Gtk.Align.CENTER)
    left.pack_start(title_widget or text(title, 13, "ink", wrap=False, ellipsize=False), False, False, 0)
    if subtitle:
        left.pack_start(text(subtitle, 11, "tertiary", width_chars=50), False, False, 0)
    row.pack_start(left, True, True, 0)
    if control is not None:
        control.set_valign(Gtk.Align.CENTER)
        row.pack_end(control, False, False, 0)
    return panel(pad(row, 10, 14), "prow")


def icon_tile(icon_name: str, size: int = 64, glyph: int = 30, tone: str = "") -> Gtk.Widget:
    img = icon(icon_name, glyph)
    img.set_halign(Gtk.Align.CENTER)
    img.set_valign(Gtk.Align.CENTER)
    t = panel(img, "icon-tile", tone)
    t.set_size_request(size, size)
    t.set_halign(Gtk.Align.CENTER)
    t.set_valign(Gtk.Align.CENTER)
    return t


def breathing_dot(small: bool = False) -> Gtk.Widget:
    """BreathingDot: an accent dot with a ring swelling out of it ("live", without blinking).
    small: the Mac's 6 px one (the records list)."""
    d = dot(True)
    if small:
        d.set_size_request(6, 6)
        classes(d, "small")
    classes(d, "breathing")
    return d


def ring_pixbuf(fraction: float, px: int = 26, track: str = "#3A3D45", color: str = "#E8552B"):
    """The countdown ring around the logo (ListenPill's ending state), as an SVG: Ubuntu ships the SVG
    pixbuf loader but not the cairo bindings a drawn widget would need."""
    from gi.repository import GdkPixbuf
    r = 11.75
    c = 2 * math.pi * r
    f = max(0.0, min(1.0, fraction))
    svg = ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 26 26">'
           '<circle cx="13" cy="13" r="%.2f" fill="none" stroke="%s" stroke-width="2.5"/>'
           '<circle cx="13" cy="13" r="%.2f" fill="none" stroke="%s" stroke-width="2.5" stroke-linecap="round"'
           ' stroke-dasharray="%.2f %.2f" transform="rotate(-90 13 13)"%s/></svg>'
           % (px, px, r, track, r, color, c * f, c, "" if f > 0 else ' stroke-opacity="0"'))
    loader = GdkPixbuf.PixbufLoader.new_with_type("svg")
    loader.write(svg.encode())
    loader.close()
    return loader.get_pixbuf()


def chip(s: str, now: bool = False) -> Gtk.Widget:
    l = text(s, 11, "", bold=True, wrap=False, ellipsize=False)
    if now:
        pad(l, 1, 6)  # a margin: GTK 3 ignores CSS padding on an EventBox
    c = panel(l, "chip", "now" if now else "time")
    c.set_valign(Gtk.Align.BASELINE)
    return c


class Toasts:
    """GNOME-style toast at the bottom of a window: one at a time, an optional action, gone after
    a few seconds (or when the next one comes). `on_timeout` runs when it expires unacted."""

    def __init__(self, overlay: Gtk.Overlay):
        self.revealer = Gtk.Revealer()
        self.revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
        self.revealer.set_halign(Gtk.Align.CENTER)
        self.revealer.set_valign(Gtk.Align.END)
        self.revealer.set_margin_bottom(24)
        overlay.add_overlay(self.revealer)
        self._timer = None
        self._expire = None

    def show(self, message: str, action: str | None = None, on_action=None, on_timeout=None, seconds: int = 5) -> None:
        self.dismiss(run_timeout=True)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        row.pack_start(text(message, 13, "", wrap=False), False, False, 0)
        if action:
            def act(*_):
                self._expire = None
                self.dismiss(run_timeout=False)
                if on_action:
                    on_action()
            b = Gtk.Button(label=action)
            b.connect("clicked", act)
            row.pack_start(b, False, False, 0)
        box = panel(pad(row, 5, 5, 5, 14), "toast")
        for c in self.revealer.get_children():
            self.revealer.remove(c)
        self.revealer.add(box)
        box.show_all()
        self.revealer.set_reveal_child(True)
        self._expire = on_timeout
        self._timer = GLib.timeout_add_seconds(seconds, self._timed_out)

    def _timed_out(self):
        self._timer = None
        self.dismiss(run_timeout=True)
        return False

    def dismiss(self, run_timeout: bool = True) -> None:
        if self._timer is not None:
            GLib.source_remove(self._timer)
            self._timer = None
        expire, self._expire = self._expire, None
        self.revealer.set_reveal_child(False)
        if run_timeout and expire:
            expire()


def loudness(rms: float) -> float:
    """-50 dBFS (a quiet room) to 0 dBFS on a log scale, so speech sits mid-bar instead of pinning it."""
    return 0.0 if rms <= 0 else max(0.0, min(1.0, (20 * math.log10(rms) + 50) / 50))


def no_wheel(combo: Gtk.ComboBox, scroll: Gtk.ScrolledWindow) -> None:
    """A GTK 3 dropdown changes its value under the mouse wheel; scrolling a page past one would
    silently change (and save) a setting. The wheel scrolls the page instead."""
    def wheel(_w, event):
        adj = scroll.get_vadjustment()
        ok, _dx, dy = event.get_scroll_deltas()
        if not ok:
            dy = {Gdk.ScrollDirection.UP: -1, Gdk.ScrollDirection.DOWN: 1}.get(event.direction, 0)
        adj.set_value(adj.get_value() + dy * 60)
        return True
    combo.connect("scroll-event", wheel)
