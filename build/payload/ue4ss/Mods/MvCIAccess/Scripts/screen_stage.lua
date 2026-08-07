-- screen_stage.lua
-- Reader for STAGE SELECT.
-- The select screens are built from ACTORS (not widgets):
--   BP_Stage_Cursor_C : the moving cursor (exists only on the select screens)
--   BP_Stage_Name_C   : holds StageName (the current stage's name)
--   BP_Stage_C x16    : the stage cells, each with UniqId
-- PERF: only cheap, specific reads - one FindAllOf for the cursor, one for the
-- name actor. No scanning of all TextBlocks (that made the game sluggish).

local M = {}
local ann = nil
local last_key = nil

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function valid(o)
    return o and safe(function() return o:IsValid() end) and true or false
end

local function ftext(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s = safe(function() return v:ToString() end)
    if type(s) == "string" and s ~= "" then return s end
    return nil
end

-- Unpopulated widgets hold placeholder text like "Text Blockg".
local function is_placeholder(s)
    return (not s) or s == "" or s:find("Text Block", 1, true) ~= nil
end

local function first_valid(cls)
    local arr = safe(function() return FindAllOf(cls) end)
    if not arr then return nil end
    for i = 1, #arr do
        if valid(arr[i]) then return arr[i] end
    end
    return nil
end

-- Text of a widget via SPECIFIC known properties only (no global scans).
local TB_PROPS = {
    "TextBlock_StageName",   -- WD_StageName_C
    "TextTextBlock_Title",   -- WD_SelectTitle_C
    "TextBlock_Name", "TextBlock_Label", "TextBlock_Caption",
}

local function widget_text(w)
    if not w then return nil end
    for _, name in ipairs(TB_PROPS) do
        local tb = safe(function() return w[name] end)
        if tb then
            local t = ftext(safe(function() return tb:GetText() end))
            if not is_placeholder(t) then return t end
        end
    end
    return nil
end

-- Current stage name: prefer the actor's own StageName, else its widget.
local function current_stage_name()
    local a = first_valid("BP_Stage_Name_C")
    if not a then return nil end
    local s = ftext(safe(function() return a.StageName end))
    if not is_placeholder(s) then return s end
    local w = safe(function() return a.WD_StageName end)
    local t = widget_text(w)
    if not is_placeholder(t) then return t end
    return nil
end

-- Stage select and CHARACTER select share the same level, so the stage actors
-- exist on both. The only reliable discriminator is the screen title.
local function select_title()
    local arr = safe(function() return FindAllOf("WD_SelectTitle_C") end)
    if not arr then return nil end
    for i = 1, #arr do
        local w = arr[i]
        if valid(w) and safe(function() return w:IsVisible() end) == true then
            local tb = safe(function() return w.TextTextBlock_Title end)
            local t = tb and ftext(safe(function() return tb:GetText() end))
            if t and t ~= "" then return t:upper() end
        end
    end
    return nil
end

local function announce(force)
    -- Only claim the STAGE screen (character select uses the same actors).
    local title = select_title()
    if not title or not title:find("STAGE", 1, true) then
        last_key = nil
        return false
    end
    local cursor = first_valid("BP_Stage_Cursor_C")
    if not cursor then
        last_key = nil
        return false
    end
    local stage = current_stage_name()
    if not stage then
        -- On the select screen but the name is not populated (e.g. we are on
        -- character select, which comes after). Stay silent but claim nothing.
        return false
    end
    if (not force) and stage == last_key then return true end
    local first = (last_key == nil)
    last_key = stage
    if ann then ann.speak(first and ("Select stage. " .. stage) or stage, true) end
    return true
end

function M.announce_now(force)
    return announce(force)
end

function M.init(announcer)
    ann = announcer
    return M
end

return M
