-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- GPU selection: not pinned. All displays are wired to the dGPU's DP outputs,
-- so aquamarine picks the RX 9070 on its own. Setting AQ_DRM_DEVICES to the
-- by-path symlink killed the session on fresh login (open path bypasses logind
-- grant). If you ever need to force it, use the resolved node (e.g. /dev/dri/card1)
-- AND add yourself to the `video` group: `sudo usermod -aG video penguin`.

-- AMD hardware video decode (Firefox, mpv, OBS)
hl.env("LIBVA_DRIVER_NAME", "radeonsi")
hl.env("VDPAU_DRIVER",      "radeonsi")

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