# dmgbuild settings for the SilkNest installer window.
import os
app = defines["app"]
format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = None
icon = os.path.join(defines["root"], "Assets/AppIcon.icns")
background = None
window_rect = ((200, 160), (600, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (160, 170), "Applications": (440, 170)}
