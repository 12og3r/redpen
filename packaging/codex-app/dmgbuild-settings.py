# dmgbuild settings for the Red Pen installer .dmg.
# dmgbuild writes the .DS_Store layout directly (no Finder/AppleScript), so this
# runs headless on CI runners. Geometry + paths come from make-dmg.sh via env.
import os

def _i(k):
    return int(os.environ[k])

app = os.environ["APP"]              # path to "Red Pen(Codex).app"
background = os.environ["BG"]        # path to background.tiff
app_name = os.path.basename(app)     # name shown in the volume

format = "UDZO"
compression_level = 9

files = [app]
symlinks = {"Applications": "/Applications"}

icon_locations = {
    app_name: (_i("APP_X"), _i("APP_Y")),
    "Applications": (_i("APPS_X"), _i("APPS_Y")),
}

window_rect = ((_i("WIN_X"), _i("WIN_Y")), (_i("WIN_W"), _i("WIN_H")))
default_view = "icon-view"
icon_size = _i("ICON")
text_size = 13

show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
