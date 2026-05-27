-- This is an example Hyprland Lua config file.
-- Refer to the wiki for more information.
-- https://wiki.hypr.land/Configuring/Start/

-- Please note not all available settings / options are set here.
-- For a full list, see the wiki

-- You can (and should!!) split this configuration into multiple files
-- Create your files separately and then require them like this:
-- require("myColors")

-- Monitors
require("modules.display.monitors")

-- System
require("modules.system.programs")
require("modules.system.autostart")
require("modules.system.env")
require("modules.system.permissions")

-- Styling
require("modules.style.decorations")
require("modules.style.animations")

-- Workspaces
require("modules.display.workspaces")

-- Misc
require("modules.misc")

-- Input
require("modules.input.input")
require("modules.input.keybindings")