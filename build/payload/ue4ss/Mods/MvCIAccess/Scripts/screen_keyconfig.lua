-- screen_keyconfig.lua
-- Reader for KEYBOARD SETTINGS (WD_KeyboardConf_C) and CONTROLLER SETTINGS
-- (WD_KeyConf_C). Both share the same layout:
--   TextBlock_Label     : the screen title ("KEYBOARD SETTINGS" / "CONTROLLER 1")
--   ButtonFocusID (int) : index of the focused binding
--   ButtonItemArray     : the binding widgets, in focus order
--   ButtonItemSubArray  : the sub-panel widgets (used when IsActiveMainPanel is false)
--   IsActiveMainPanel   : which panel currently has focus
-- Each binding widget (WD_KCbuttonParts*) has:
--   TextBlock_Label   : the command ("Light Punch", "Right", "Pause Type", "Exit")
--   TextBlock_Subitem : the value for option rows ("Type A", "On")
-- NOTE: the actual bound key/button is drawn as an icon (KeyboardIconMaterial /
-- MI_buttonIconArray), so it is not readable as text; we announce the command and
-- its value. Must be checked BEFORE the options reader, because the Settings list
-- stays active underneath.

local M = {}
local ann = nil
local last_key = nil

local CLASSES = { "WD_KeyboardConf_C", "WD_KeyConf_C" }

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

local function num_prop(obj, name)
    local v = safe(function() return obj[name] end)
    if type(v) == "number" then return v end
    if type(v) == "userdata" then
        local n = safe(function() return v:get() end)
        if type(n) == "number" then return n end
    end
    return nil
end

local function block_text(obj, name)
    local tb = safe(function() return obj[name] end)
    if not tb then return nil end
    return ftext(safe(function() return tb:GetText() end))
end

-- bounds-checked object element (OOB indexing crashes the game natively)
local function arr_count(a)
    for _, g in ipairs({
        function() return #a end,
        function() return a:GetArrayNum() end,
        function() return a:Num() end,
    }) do
        local n = safe(g)
        if type(n) == "number" then return n end
    end
    return nil
end

local function array_obj(obj, name, i0)
    local a = safe(function() return obj[name] end)
    if not a then return nil, nil end
    local n = arr_count(a)
    if type(n) ~= "number" or i0 < 0 or i0 >= n then return nil, n end
    for _, g in ipairs({
        function() return a[i0 + 1] end,
        function() return a[i0] end,
        function() return a:get(i0) end,
    }) do
        local v = safe(g)
        if type(v) == "userdata" then return v, n end
    end
    return nil, n
end

local Core = require("core")

-- The open key-config screen, or nil (core.lua's fast lookup, no FindAllOf).
local function get_conf()
    for _, cls in ipairs(CLASSES) do
        local arr = Core.find(cls)
        if arr then
            for i = 1, #arr do
                local w = arr[i]
                if valid(w) and safe(function() return w:IsVisible() end) == true then
                    return w
                end
            end
        end
    end
    return nil
end

local function announce(force)
    local conf = get_conf()
    if not conf then
        last_key = nil
        return false
    end
    local focus = num_prop(conf, "ButtonFocusID") or 0
    local main = safe(function() return conf.IsActiveMainPanel end) ~= false
    local arr_name = main and "ButtonItemArray" or "ButtonItemSubArray"
    local btn, total = array_obj(conf, arr_name, focus)

    local label = btn and block_text(btn, "TextBlock_Label") or nil
    local value = btn and block_text(btn, "TextBlock_Subitem") or nil

    local key = tostring(arr_name) .. "#" .. tostring(focus) .. "#" ..
        tostring(label) .. "#" .. tostring(value)
    if (not force) and key == last_key then return true end
    local first = (last_key == nil)
    last_key = key

    local msg
    if label and label ~= "" then
        msg = label
        if value and value ~= "" then msg = msg .. ": " .. value end
        if total then msg = msg .. ", " .. (focus + 1) .. " of " .. total end
    else
        msg = "binding " .. (focus + 1)
    end
    if first then
        local title = block_text(conf, "TextBlock_Label")
        if title and title ~= "" then msg = title .. ". " .. msg end
    end
    if ann then ann.speak(msg, true) end
    return true
end

function M.announce_now(force)
    return announce(force)
end

-- Another screen has input: the next time key config opens, announce it afresh.
function M.closed()
    last_key = nil
end

function M.init(announcer)
    ann = announcer
    return M
end

return M
