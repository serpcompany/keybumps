# dmgbuild settings for the release disk image (#437): a fixed window with Keybumps on the left
# and an Applications link on the right, over background.png. render-background.swift draws the
# arrow between these icon positions, so keep the two in step.
#
# build-update-release.sh passes: -D app=<Keybumps.app> -D background=<background.png>
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides defines)
app_name = os.path.basename(app)

format = "ULFO"
filesystem = "HFS+"
size = None

files = [app]
symlinks = {"Applications": "/Applications"}
# The volume shows the app's own icon.
icon = os.path.join(app, "Contents", "Resources", "Keybumps.icns")
# No hide_extensions: it sets Finder info on the bundle, which breaks its strict signature check.

# background.png has a background@2x.png beside it, which dmgbuild combines into a Retina image.
background = defines["background"]  # noqa: F821
# The frame includes the title bar (28pt), so the content area matches the 640x400 background.
window_rect = ((200, 120), (640, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (170, 190),
    "Applications": (470, 190),
}
