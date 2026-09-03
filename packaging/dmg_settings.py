# dmgbuild settings: the classic drag-to-Applications window with a background hint.
# Invoked by package.sh: dmgbuild -s packaging/dmg_settings.py -D app=... -D bg=... -D icon=... "ArxivFeed" out.dmg
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["bg"]  # noqa: F821

format = "UDZO"
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (170, 165), "Applications": (490, 165)}
