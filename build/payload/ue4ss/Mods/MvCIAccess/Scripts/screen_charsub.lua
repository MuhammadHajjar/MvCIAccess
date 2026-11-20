-- screen_charsub.lua
-- The two sub-screens that open ON TOP of character select, both silent until now:
--
--   WD_Menu_Con_C         the costume / color panel, after you pick a fighter
--   WD_Menu_Gem_Button_C  the Infinity Stone picker
--
-- Neither is a normal option list, which is why the generic reader in
-- screen_options.lua never matched them (they fail its has_list() check).
--
-- COSTUME PANEL. FocusMenu is the row index, and the rows are exposed directly
-- as named properties rather than as panel children:
--     FocusMenu 0 -> WD_ListItem00   "Costume", value in TextBlock_Subitem
--     FocusMenu 1 -> WD_ListItem01   "Color",   value in ColorFocus (0 based)
-- Verified 2026-08-12: FocusMenu was 1 at the same moment the color row's own
-- bFocus was true, which is what pins FocusMenu down as the selection.
--
-- STONE PICKER. The picker widget carries NO selection index whatsoever, only
-- buttons and canvases. What actually tracks the cursor is WD_GemDetail_C, whose
-- text is rewritten to the highlighted stone's description. Confirmed by two
-- dumps one cursor move apart: the text went from "Unleashes a different
-- elemental attack..." to "Raises attack power...".
--
-- There are two detail panels, 1P and 2P, and the inactive one is filled with
-- icon-font placeholder glyphs, so we take whichever one holds real words.
--
-- The stones are never NAMED in text anywhere on this screen, only described,
-- so the name is recovered from the description itself (see STONE_SIGNATURES).
-- A description we do not recognise is read out WITHOUT a name rather than
-- guessed at, the same rule the character grid follows: a confident wrong name
-- is worse than no name.

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

local function visible(o)
    return o ~= nil and safe(function() return o:IsVisible() end) == true
end

local function ftext(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s = safe(function() return v:ToString() end)
    if type(s) == "string" and s ~= "" then return s end
    return nil
end

local function text_of(w)
    if not w then return nil end
    return ftext(safe(function() return w:GetText() end))
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

local C = require("core")

-- Every live widget of a class, through core.lua's fast lookup (no FindAllOf).
local function all_valid(cls)
    return C.find(cls)
end

-- Collapse the newlines the game puts inside its description text, so it speaks
-- as one sentence instead of being chopped up.
local function clean(s)
    if not s then return nil end
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

-- The inactive detail panel holds icon-font placeholders that render as repeated
-- "Àg" glyphs. Real copy has ASCII letters and none of that.
local function looks_real(s)
    if not s or s == "" then return false end
    if s:find("\195\128", 1, true) then return false end  -- UTF-8 "À"
    return s:find("%a") ~= nil
end

-- Infinity Stone names.
--
-- The picker never puts a stone's name in text, only a picture and its two
-- descriptions, so the name has to be recovered from the description. Each
-- entry is a distinctive fragment of that stone's Storm (Trigger) line.
--
-- Contributed by Xvordan on audiogames.net 2026-08-12. Two of the six were
-- then checked against text captured from this game here earlier and matched
-- word for word: the "different elemental attack" line really is Reality, and
-- the "raises attack power" line really is Power. The other four come from the
-- same list, given in the same format, alongside those two.
--
-- If nothing matches, because the game is in another language or the wording
-- changed, we read the description with no name rather than announce a wrong
-- one. An unmatched line is logged once so a signature can be added later.
local STONE_SIGNATURES = {
    { "different elemental attack", "Reality Stone" },
    { "raises attack power",        "Power Stone"   },
    { "force cage",                 "Space Stone"   },
    { "active switch speed",        "Time Stone"    },
    { "hc gauge rises",             "Mind Stone"    },
    { "revive a fallen partner",    "Soul Stone"    },
}

local unknown_stones = {}

local function log_unknown_stone(storm)
    if not storm or unknown_stones[storm] then return end
    unknown_stones[storm] = true
    pcall(function()
        local f = io.open(require("paths").file("unknown_stones.txt"), "a")
        if not f then return end
        f:write(storm .. "\n")
        f:close()
    end)
end

local function stone_name(storm)
    if not storm then return nil end
    local s = storm:lower()
    for _, sig in ipairs(STONE_SIGNATURES) do
        if s:find(sig[1], 1, true) then return sig[2] end
    end
    log_unknown_stone(storm)
    return nil
end

-- ---------------------------------------------------------------- costume

local function costume_panel()
    local list = all_valid("WD_Menu_Con_C")
    local first = nil
    for i = 1, #list do
        if visible(list[i]) then
            first = first or list[i]
            if num_prop(list[i], "teamNo") == 0 then return list[i] end
        end
    end
    return first
end

local function announce_costume(force)
    local w = costume_panel()
    if not w then return false end

    local idx = num_prop(w, "FocusMenu") or 0
    local row = safe(function()
        if idx == 0 then return w.WD_ListItem00 end
        return w.WD_ListItem01
    end)
    if not row then return false end

    local label = clean(text_of(safe(function() return row.TextBlock_Label end)))
    local value
    if idx == 0 then
        value = clean(text_of(safe(function() return row.TextBlock_Subitem end)))
    else
        -- ColorFocus is 0 based; the chips are labelled 1 upwards on screen.
        local c = num_prop(row, "ColorFocus")
        if c then value = tostring(c + 1) end
    end

    local key = "con#" .. tostring(idx) .. "#" .. tostring(value)
    if (not force) and key == last_key then return true end
    last_key = key

    local msg = label or ("item " .. tostring(idx))
    if value then msg = msg .. ", " .. value end
    if ann then ann.speak(msg, true) end
    return true
end

-- ------------------------------------------------------------- stone picker

local function announce_gem(force)
    local open = false
    for _, w in ipairs(all_valid("WD_Menu_Gem_Button_C")) do
        if visible(w) then open = true break end
    end
    if not open then return false end

    local storm, surge
    for _, d in ipairs(all_valid("WD_GemDetail_C")) do
        if visible(d) then
            local t = clean(text_of(safe(function() return d.TriggerEffectText end)))
            local p = clean(text_of(safe(function() return d.PossessionEffectText end)))
            if looks_real(t) or looks_real(p) then
                if looks_real(t) then storm = t end
                if looks_real(p) then surge = p end
                break
            end
        end
    end
    if not storm and not surge then return false end

    local parts = {}
    if storm then parts[#parts + 1] = "Storm, " .. storm end
    if surge then parts[#parts + 1] = "Surge, " .. surge end
    local msg = table.concat(parts, " ")

    -- Lead with the stone's name whenever it can be recognised. The
    -- descriptions still follow, since they are what actually tell you what the
    -- stone does, and speech is interrupted on every cursor move so scanning
    -- quickly down the list costs nothing.
    local name = stone_name(storm)
    if name then msg = name .. ". " .. msg end

    local key = "gem#" .. msg
    if (not force) and key == last_key then return true end
    last_key = key

    if ann then ann.speak(msg, true) end
    return true
end

-- ------------------------------------------------------------------- public

-- ------------------------------------------------------------ battle settings
-- Opened from the roster (C on the keyboard): Difficulty, Time, Damage, Fight
-- Request, Region, Connection Strength. The character picker says when it is
-- open (BattleSettingActive); the list widget (WD_BattleSettig_New_C, the
-- game's own spelling) keeps its rows in ButtonArray and its cursor in
-- FocusMenu, and each row has a label and a value TextBlock.
local function announce_battle_settings(force)
    local flow = C.flow()
    local picker = flow and C.obj(flow, "CharaSelectObj")
    if not picker or C.bool(picker, "BattleSettingActive") ~= true then return false end
    local list = C.shown("WD_BattleSettig_New_C")
    if not list then return false end
    local idx = C.num(list, "FocusMenu") or 0
    local row = C.aprop(list, "ButtonArray", idx + 1)
    if not C.valid(row) then return false end
    local label_tb, value_tb = C.obj(row, "TextBlock_Label"), C.obj(row, "TextBlock_Subitem")
    local label = label_tb and C.text(label_tb)
    if not label then return false end
    local value = value_tb and C.text(value_tb)

    local key = "bs#" .. idx .. "#" .. tostring(value)
    if (not force) and key == last_key then return true end
    local first = not (last_key and last_key:sub(1, 3) == "bs#")
    last_key = key

    local msg = label
    if value then msg = msg .. ": " .. value end
    msg = msg .. ", " .. (idx + 1) .. " of " .. (C.aprop_len(list, "ButtonArray") or 0) .. "."
    if first or force then msg = "Battle settings. " .. msg end
    if ann then ann.speak(msg, true) end
    return true
end

-- Which panel is open comes from the select level's flow actor, not from what
-- is visible: both panels stay "visible" after they close, so on a second
-- visit a stale costume panel used to answer for the roster and for the stone
-- picker alike. NaviType: 1 stage select, 2 roster, 4 stone picker, 6 costume
-- and colour panel.
local NAVI_STONE, NAVI_COSTUME = 4, 6

function M.announce_now(force)
    if announce_battle_settings(force) then return true end
    local flow = C.flow()
    local navi = flow and C.num(flow, "NaviType")
    if navi == NAVI_COSTUME then
        if announce_costume(force) then return true end
    elseif navi == NAVI_STONE then
        if announce_gem(force) then return true end
    elseif navi == nil then
        -- a flow without NaviType (Team Setup): fall back to what is showing
        if announce_costume(force) then return true end
        if announce_gem(force) then return true end
    end
    last_key = nil   -- neither is open, so re-entering announces again
    return false
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
