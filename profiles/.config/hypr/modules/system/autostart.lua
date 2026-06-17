-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- Or execute your favorite apps at launch like this:
--
-- hl.on("hyprland.start", function () 
--   hl.exec_cmd(terminal)
--   hl.exec_cmd("nm-applet")
--   hl.exec_cmd("waybar & hyprpaper & firefox")
-- end)

hl.on("hyprland.start", function ()
    -- Push the Wayland env into dbus + systemd, then bring up the graphical
    -- session target. Without this, graphical-session.target stays inactive and
    -- xdg-desktop-portal (Requisite=graphical-session.target) never starts, so
    -- no app can read color-scheme=prefer-dark and everything renders light.
    -- Chain these: the env must land in the systemd user environment BEFORE the
    -- target starts, or units pulled in by it (hyprpolkitagent, a Qt/wayland app)
    -- race the Wayland socket and crash. hyprpolkitagent is enabled (WantedBy
    -- graphical-session.target), so the target activation starts it for us.
    hl.exec_cmd("dbus-update-activation-environment --systemd --all && systemctl --user start hyprland-session.target")

    hl.exec_cmd("qs -d")
    hl.exec_cmd("wl-paste --watch clipvault store")

    -- HyperX QuadCast 2 S RGB: solid white (needs the 99-quadcastrgb.rules udev rule)
    hl.exec_cmd("quadcastrgb solid ffffff")

    hl.exec_cmd("gsettings set org.gnome.desktop.interface color-scheme \"prefer-dark\"")
    hl.exec_cmd("gsettings set org.gnome.desktop.interface gtk-theme \"adw-gtk3\"")
end)