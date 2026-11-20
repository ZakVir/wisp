# dmgbuild settings for Wisp's installer window. Used by tools/release.sh:
#   uvx --from dmgbuild dmgbuild -s tools/dmg_settings.py -D app=<Wisp.app> "Wisp <version>" <out.dmg>
import os

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()
root = os.path.join(here, "..") if os.path.basename(here) == "tools" else here

format = "ULFO"
filesystem = "HFS+"  # hide_extension needs HFS+
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (170, 180), "Applications": (490, 180)}
background = os.path.join(root, "design/dmg/background.tiff")

window_rect = ((200, 140), (660, 460))  # 400 pt of content below the title bar, plus a possible bottom bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
arrange_by = None
hide_extension = [os.path.basename(app)]
