-- screen_commandlist.lua
-- Reader for the COMMAND LIST (move list), reached from the pause menu.
-- Discovered structure:
--   WD_CommandList_C (visible + IsMenuBaseInput when open)
--     TextBlock_CharName : the character ("RYU")
--     FocusIndex   (int) : scroll position; goes 0, -1, -2 ... as you scroll down
--     ListMax      (int) : number of entries for this character (21, 24, ...)
--     ListShowMax  (int) : rows visible at once (6)
--     CmdNameArray / CmdTextArray : per-entry move name and input notation
--   WD_CmdListButton_C  : one move row -> TextBlock_Name, CommandName, CommandText
--   WD_CmdListCategory_C: a heading row -> TextBlock_Caption ("Special Moves")
-- The list has no per-move highlight; you scroll it. So we announce the entry at
-- the current scroll position whenever it changes, which reads move-by-move.
-- IMPORTANT: the pause menu stays visible underneath, so this must be checked
-- BEFORE the options/pause reader.

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

local function num_prop(obj, name)
    local v = safe(function() return obj[name] end)
    if type(v) == "number" then return v end
    if type(v) == "userdata" then
        local n = safe(function() return v:get() end)
        if type(n) == "number" then return n end
    end
    return nil
end

-- Text of a TextBlock-ish property (e.g. TextBlock_CharName).
local function block_text(obj, name)
    local tb = safe(function() return obj[name] end)
    if not tb then return nil end
    return ftext(safe(function() return tb:GetText() end))
end

-- ---- bounds-checked array access (OOB indexing crashes the game natively) ----
local function arr_count(a)
    for _, getter in ipairs({
        function() return #a end,
        function() return a:GetArrayNum() end,
        function() return a:Num() end,
    }) do
        local n = safe(getter)
        if type(n) == "number" then return n end
    end
    return nil
end

local function array_element(obj, name, i0)
    local a = safe(function() return obj[name] end)
    if not a then return nil end
    local n = arr_count(a)
    if type(n) ~= "number" or i0 < 0 or i0 >= n then return nil end
    for _, getter in ipairs({
        function() return a[i0 + 1] end,
        function() return a[i0] end,
        function() return a:get(i0) end,
    }) do
        local s = ftext(safe(getter))
        if s then return s end
    end
    return nil
end

local Core = require("core")

-- The open command list, or nil: core.lua's active menu (valid, visible, has
-- input, nothing open above it). No FindAllOf on every tick.
local function get_list()
    local m = Core.active_menu()
    if m and m.cls == "WD_CommandList_C" then return m.w end
    return nil
end

-- Fallback when the arrays are unreadable: the topmost visible move row.
local function topmost_row()
    local arr = safe(function() return FindAllOf("WD_CmdListButton_C") end)
    if not arr then return nil end
    local best, best_y = nil, nil
    for i = 1, #arr do
        local w = arr[i]
        if valid(w) and safe(function() return w:IsVisible() end) == true then
            local slot = safe(function() return w.Slot end)
            local pos = slot and safe(function() return slot:GetPosition() end)
            local y = pos and safe(function() return pos.Y end)
            if type(y) == "number" then
                if not best_y or y < best_y then best, best_y = w, y end
            elseif not best then
                best = w
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Input-icon decoding.
-- The game stores command notation with icon placeholders like "$ff73$$ff80$or$ff81$"
-- (Shoryuken = dragon-punch motion, Light Punch or Heavy Punch). Each $ffXX$ is an
-- icon slot. Confirmed from known Ryu moves; motions are ff7x, buttons ff8x.
-- Unmapped codes are spoken as "icon NN" and logged to unknown_icons.txt so the
-- table can be completed.
local ICONS = {
    -- attack buttons (confirmed: Ryu/Arthur/Zero/Thor/Ghost Rider)
    ff80 = "Light Punch",
    ff81 = "Heavy Punch",
    ff82 = "Light Kick",
    ff83 = "Heavy Kick",
    -- motions (confirmed by cross-referencing known movesets)
    ff71 = "quarter circle forward",  -- Hadoken, Dagger Toss, Mighty Spark
    ff72 = "quarter circle back",     -- Tatsumaki, Scatter Crossbow, Chaos Bringer
    ff73 = "dragon punch",            -- Ryu's Shoryuken (composite icon)
    ff76 = "full circle",             -- Thor's Mighty Hurricane (command grab)
    -- directions (from command normals + air-only moves)
    ff7a = "forward",                 -- Shippuuga, Hammer Straight, Cross Sword
    ff7b = "back",                    -- Koketsuga, Shoulder Slam (least certain)
    ff7c = "down",                    -- air Divine Drop / Damnation Whip
}

-- Multi-token sequences decoded before the single-token pass, so a repeated
-- direction reads naturally ("down, down" not "down down").
local SEQUENCES = {
    { "%$ff7c%$%$ff7c%$", "down, down" },  -- Ryuenjin, Mighty Smash, Heavenly Slash
}

local ICON_LOG = require("paths").file("unknown_icons.txt")
local logged = {}

local function log_unknown(code, ctx, raw)
    if logged[code] then return end
    logged[code] = true
    local f = io.open(ICON_LOG, "a")
    if f then
        f:write(code .. "\t" .. tostring(ctx) .. "\t" .. tostring(raw) .. "\n")
        f:close()
    end
end

-- Replace every $ffXX$ placeholder with a spoken name.
local function decode_command(s, ctx)
    if not s or s == "" then return s end
    -- "<>" marks a category heading row (no command)
    if s == "<>" then return nil end
    local raw = s
    for _, seq in ipairs(SEQUENCES) do
        s = s:gsub(seq[1], " " .. seq[2] .. " ")
    end
    local out = s:gsub("%$(%x+)%$", function(code)
        code = code:lower()
        local name = ICONS[code]
        if name then return " " .. name .. " " end
        log_unknown(code, ctx, raw)
        return " icon " .. code:sub(-2) .. " "
    end)
    out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return out
end

local function row_text(w)
    if not w then return nil end
    local name = ftext(safe(function() return w.CommandName end))
        or block_text(w, "TextBlock_Name")
    local cmd = ftext(safe(function() return w.CommandText end))
    if not name or name == "" then return nil end
    name = decode_command(name, "name")
    if cmd and cmd ~= "" then return name .. ", " .. decode_command(cmd, name) end
    return name
end

-- Announce the entry at the current scroll position.
local function announce(force)
    local cl = get_list()
    if not cl then
        last_key = nil
        return false
    end
    local idx = num_prop(cl, "FocusIndex") or 0
    local total = num_prop(cl, "ListMax")
    local chara = block_text(cl, "TextBlock_CharName")
    local i0 = math.abs(idx) -- scroll goes negative as you move down

    local key = tostring(chara) .. "#" .. tostring(idx) .. "#" .. tostring(total)
    if (not force) and key == last_key then return true end
    local first = (last_key == nil)
    last_key = key

    -- entry text: prefer the arrays, else the topmost visible row
    local name = array_element(cl, "CmdNameArray", i0)
    local cmd = array_element(cl, "CmdTextArray", i0)
    local line = nil
    if name and name ~= "" then
        name = decode_command(name, "name") or name
        local dcmd = cmd and decode_command(cmd, name) or nil
        if dcmd and dcmd ~= "" then
            line = name .. ", " .. dcmd
        else
            -- no command text: this is a category heading row
            line = name .. ", heading"
        end
    else
        line = row_text(topmost_row())
    end

    local msg
    if first then
        msg = "Command list"
        if chara then msg = msg .. ", " .. chara end
        if total then msg = msg .. ", " .. total .. " moves" end
        if line then msg = msg .. ". " .. line end
    else
        msg = line
        if not msg then
            msg = "move " .. (i0 + 1) .. (total and (" of " .. total) or "")
        end
    end
    if msg and ann then ann.speak(msg, true) end
    return true
end

function M.announce_now(force)
    return announce(force)
end

-- Another screen has input: the next time the list opens, announce it afresh.
function M.closed()
    last_key = nil
end

function M.init(announcer)
    ann = announcer
    return M
end

return M
