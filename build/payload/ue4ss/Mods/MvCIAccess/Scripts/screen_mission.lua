-- screen_mission.lua
-- Mission Mode: the mission list (the tutorial and every fighter's ten
-- missions) and, inside a mission, the task the game prints at the top of the
-- screen.
--
-- The list (WD_MissionMain_C and its Update1/Update2 children) is a grid: one
-- row per tutorial category or fighter, one box per mission. It has four tabs,
-- turned with the shoulder buttons (X and C on the keyboard); ViewState says
-- which, and each tab keeps its own cursor:
--   ViewState 0 CAPCOM    IndexFocus_C   / IndexFocusX_C    rows = CharIDTable_C
--   ViewState 1 MARVEL    IndexFocus_M   / IndexFocusX_M    rows = CharIDTable_M
--   ViewState 2 ALL       IndexFocus_All / IndexFocusX_All
--   ViewState 3 TUTORIAL  IndexFocus_T   / IndexFocusX_T    rows = ArrTutorialCategory,
--                                                           sizes = ArrTutorialStageNum
-- The row widgets (ListCharArray_C / _M / _T) carry the "Completed: 0/5" text.
-- Pressing S shows the mission's instructions in WD_MissionPopupTTL.

local M = {}
local C = require("core")
local ann = nil
local last_key = nil
local last_tab = nil
local last_hud = nil

local TAB_SUFFIX = { [0] = "C", [1] = "M", [2] = "All", [3] = "T" }

local function say(text)
    if ann and text and text ~= "" then ann.speak(text, true) end
end

local function fighter_name(id)
    local names = require("screen_fight").NAMES
    return (names and names[id]) or ("fighter " .. tostring(id))
end

-- The list ---------------------------------------------------------------------

local function read_list(w, force)
    local tab = C.num(w, "ViewState")
    local sfx = tab and TAB_SUFFIX[tab]
    if not sfx then return false end
    local row = C.num(w, "IndexFocus_" .. sfx)
    local box = C.num(w, "IndexFocusX_" .. sfx)
    if not row or not box then return false end

    -- the instructions panel, when it is showing
    local detail
    local popup = C.obj(w, "WD_MissionPopupTTL")
    if popup and C.visible(popup) then
        local texts = C.texts(popup, 60)
        if #texts > 0 then detail = table.concat(texts, " ") end
    end

    local key = tab .. "#" .. row .. "#" .. box .. "#" .. tostring(detail)
    if (not force) and key == last_key then return true end
    last_key = key

    local parts = {}
    if tab ~= last_tab or force then
        local cap = C.tostr(C.aprop(w, "ViewCaptionTextArray", tab + 1))
        if cap and cap ~= "" then
            parts[#parts + 1] = "Mission mode, " .. cap:lower():gsub("^%l", string.upper) .. "."
        end
        last_tab = tab
    end

    local label, total
    if tab == 3 then
        label = C.tostr(C.aprop(w, "ArrTutorialCategory", row + 1))
        total = C.aprop(w, "ArrTutorialStageNum", row + 1)
    elseif tab == 0 or tab == 1 then
        local id = C.aprop(w, "CharIDTable_" .. sfx, row + 1)
        if type(id) == "number" then label = fighter_name(id) end
        total = 10
    end
    if not label then
        -- the ALL tab: the fighter's name is the text of the row's name widget
        local nw = C.aprop(w, "ListNameArray", row + 1)
        if C.valid(nw) then label = C.texts(nw, 20)[1] end
        if label and not total then total = 10 end
    end
    local line = (label or ("row " .. (row + 1))) .. ", mission " .. (box + 1)
    if type(total) == "number" then line = line .. " of " .. total end
    parts[#parts + 1] = line .. "."

    -- "Completed: 0/5", from the row's own widget
    local rw = C.aprop(w, "ListCharArray_" .. sfx, row + 1)
    if C.valid(rw) then
        local tb = C.obj(rw, "TextBlock_Clear")
        local done = tb and C.text(tb)
        if done then parts[#parts + 1] = done .. "." end
    end
    if detail then parts[#parts + 1] = detail end
    say(table.concat(parts, " "))
    return true
end

-- True if the mission list is the active screen (and was spoken).
function M.announce_now(force)
    local m = C.active_menu()
    if m and m.cls:sub(1, 14) == "WD_MissionMain" then
        return read_list(m.w, force)
    end
    last_key, last_tab = nil, nil
    return false
end

-- Inside a mission ---------------------------------------------------------------
-- WD_MissionHUD_C: "MISSION 1" and the task ("Move forward or backward.").
-- Spoken when it appears and whenever it changes. Never claims the screen.
function M.announce_hud(force)
    if not C.in_fight() then
        last_hud = nil
        return
    end
    local hud = C.shown("WD_MissionHUD_C")
    if not hud then
        last_hud = nil
        return
    end
    local num = C.obj(hud, "TextBlock_Number")
    local spec = C.obj(hud, "TextBlock_Spec")
    local a, b = num and C.text(num), spec and C.text(spec)
    if not (a or b) then return end
    local text = (a and (a:lower():gsub("^%l", string.upper) .. ". ") or "") .. (b or "")
    if (not force) and text == last_hud then return end
    last_hud = text
    -- queued behind other speech, unless asked for (Ctrl+Shift+A)
    if ann then ann.speak(text, force == true) end
end

-- Another screen has input: forget the list position, so coming back reads it.
function M.closed()
    last_key, last_tab = nil, nil
end

function M.init(announcer)
    ann = announcer
    return M
end

return M
