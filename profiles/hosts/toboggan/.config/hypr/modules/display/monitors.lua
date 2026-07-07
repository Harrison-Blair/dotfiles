------------------
---- MONITORS ----
------------------

-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- VRR/FreeSync is configured globally in modules/misc.lua (misc.vrr = 2).

-- Built-in panel (Razer Blade 15 Advanced 2021, FHD)
hl.monitor({
    output   = "eDP-1",
    mode     = "1920x1080@60",
    position = "0x0",
    scale    = "1",
})
