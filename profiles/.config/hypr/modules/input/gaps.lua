----------------------------
---- PER-WS GAP CYCLING ----
----------------------------

local IN  = { 5, 30, 45 }   -- gaps_in cycle
local OUT = { 10, 60, 90 }  -- gaps_out cycle

local state = {}  -- [workspace id] = { in_idx, out_idx }, 1-based

local function get_state(id)
    if not state[id] then
        state[id] = { in_idx = 1, out_idx = 1 }
    end
    return state[id]
end

local M = {}

function M.cycle_both()
    local ws = hl.get_active_workspace()
    if not ws or ws.special then return end
    local s = get_state(ws.id)
    s.in_idx  = s.in_idx % 3 + 1
    s.out_idx = s.in_idx
    hl.workspace_rule({
        workspace = tostring(ws.id),
        gaps_in   = IN[s.in_idx],
        gaps_out  = OUT[s.out_idx],
    })
end

function M.cycle_inner()
    local ws = hl.get_active_workspace()
    if not ws or ws.special then return end
    local s = get_state(ws.id)
    s.in_idx = s.in_idx % 3 + 1
    hl.workspace_rule({
        workspace = tostring(ws.id),
        gaps_in   = IN[s.in_idx],
    })
end

function M.cycle_outer()
    local ws = hl.get_active_workspace()
    if not ws or ws.special then return end
    local s = get_state(ws.id)
    s.out_idx = s.out_idx % 3 + 1
    hl.workspace_rule({
        workspace = tostring(ws.id),
        gaps_out  = OUT[s.out_idx],
    })
end

return M
