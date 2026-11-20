-- screen_stage.lua
-- Reader for STAGE SELECT.
--
-- Stage select and character select share one level, and each one's widgets
-- stay "visible" on the other, so neither the actors nor the screen title can
-- tell them apart. The level's flow actor can: its InputObj is the actor that
-- has input right now, the stage picker or the character picker.
--
-- The stage name is the text of the WD_StageName_C widget. An unfilled one
-- shows the designer's placeholder ("Text Block"), which is skipped.

local M = {}
local C = require("core")
local ann = nil
local last_key = nil

local function current_stage_name()
    for _, w in ipairs(C.find("WD_StageName_C")) do
        if C.visible(w) then
            local tb = C.obj(w, "TextBlock_StageName")
            local t = tb and C.text(tb)
            if t and not t:find("Text Block", 1, true) then return t end
        end
    end
    return nil
end

local function announce(force)
    local flow = C.flow()
    if not flow or C.flow_name():sub(1, 14) ~= "GF_CharaSelect" then
        last_key = nil
        return false
    end
    local stage_picker = C.obj(flow, "StageSelect_Obj")
    local input = C.obj(flow, "InputObj")
    if not stage_picker or not input or C.cname(input) ~= C.cname(stage_picker) then
        last_key = nil
        return false
    end
    local stage = current_stage_name()
    -- on the stage screen, but the name is not filled in yet
    if not stage then return true end
    if (not force) and stage == last_key then return true end
    local first = (last_key == nil)
    last_key = stage
    if ann then ann.speak(first and ("Select stage. " .. stage) or stage, true) end
    return true
end

function M.announce_now(force)
    return announce(force)
end

-- Another reader has the screen: forget the last announcement.
function M.closed()
    last_key = nil
end

function M.init(announcer)
    ann = announcer
    return M
end

return M
