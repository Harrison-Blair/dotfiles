-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- GPU selection: hybrid graphics (Intel UHD iGPU drives the eDP-1 panel,
-- NVIDIA RTX 3080 Mobile drives the external DP/HDMI ports). Not pinned:
-- aquamarine picks the iGPU for the internal panel on its own. If it ever
-- picks wrong, set AQ_DRM_DEVICES with the iGPU's resolved node first
-- (e.g. "/dev/dri/card1:/dev/dri/card0" — check /dev/dri/by-path, numbering
-- can change) AND add yourself to the `video` group.
-- To run a specific app on the dGPU:
--   __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>

-- Intel hardware video decode via intel-media-driver (Firefox, mpv, OBS)
hl.env("LIBVA_DRIVER_NAME", "iHD")

-- Toolkit Backend
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("SDL_VIDEODRIVER", "wayland")
hl.env("CLUTTER_BACKEND", "wayland")

-- XDG Specifications
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- QT
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")

-- Mozilla (Firefox)
hl.env("MOZ_ENABLE_WAYLAND", "1")