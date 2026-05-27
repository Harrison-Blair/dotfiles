------------------
---- MONITORS ----
------------------

-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- VRR/FreeSync is configured globally in modules/misc.lua (misc.vrr = 2).

-- Main
hl.monitor({
    output   = "DP-1",
    mode     = "2560x1440@240",
    position = "0x0",
    scale    = "1",
})

-- Left
hl.monitor({
    output   = "DP-2",
    mode     = "2560x1440@180",
    position = "-2560x0",
    scale    = "1",
})

-- Right
hl.monitor({
    output      = "DP-3",
    mode        = "2560x1440@180",
    position    = "2560x-1120",
    scale       = "1",
    transform   =  3,
})