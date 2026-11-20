-- screen_charselect.lua
-- Reader for CHARACTER SELECT. This screen is built from ACTORS, not widgets.
-- Everything is reached from the level's flow actor (core.flow()), with no
-- searching:
--   flow.InputObj                      the actor that has input right now: the
--                                      stage picker or the character picker
--   flow.CharaSelectObj.SelectParentObj  BP_Select_Parent_C, which holds
--       FocusUniqId        array, one focused roster cell per team (-1 = none)
--       ArrSelectCursor    the two cursors (teamNo 0 = player 1, 1 = the other
--                          side); the one that is NOT hidden is choosing
-- Stage select shares this level and its widgets linger, which is why the
-- screen title is useless as a test: on a second visit both "SELECT STAGE" and
-- "SELECT CHARACTERS" are visible at once and the roster went silent.
--
-- Fighter names are not text on this screen: every cell shares one mesh and
-- its portrait is a runtime material. They are in the table below, verified by
-- ear. Names are never guessed - a wrong name would send you to the wrong
-- fighter.

local M = {}
local C = require("core")
local ann = nil
local last_key = nil

-- UniqId (roster cell) -> character name.
-- Verified in game 2026-08-06 by stepping the roster and listening to the name
-- the game announces on select. Layout confirmed: LEFT half = Capcom (0-14),
-- RIGHT half = Marvel (15-29), bottom row = DLC (30-35, contributed by an owner
-- of the DLC 2026-08-07). The DLC row is 2 Capcom + 4 Marvel, so it does NOT
-- follow the left/right split - see SIDES below.
-- An optional charnames.txt (lines of "<UniqId> = <Name>") overrides entries.
local NAMES = {
    -- Capcom side (left), row-major, 3 per row
    [0]  = "Strider Hiryu",
    [1]  = "Arthur",
    [2]  = "Frank West",
    [3]  = "Chris Redfield",
    [4]  = "Mega Man X",
    [5]  = "Zero",
    [6]  = "Nemesis",
    [7]  = "Dante",
    [8]  = "Ryu",
    [9]  = "Spencer",
    [10] = "Chun-Li",
    [11] = "Morrigan",
    [12] = "Jedah",
    [13] = "Firebrand",
    [14] = "Haggar",
    -- Marvel side (right), row-major, 3 per row
    [15] = "Rocket Raccoon",
    [16] = "Doctor Strange",
    [17] = "Hawkeye",
    [18] = "Ultron",
    [19] = "Gamora",
    [20] = "Ghost Rider",
    [21] = "Iron Man",
    [22] = "Thanos",
    [23] = "Nova",
    [24] = "Hulk",
    [25] = "Captain Marvel",
    [26] = "Thor",
    [27] = "Captain America",
    [28] = "Spider-Man",
    [29] = "Dormammu",
    -- DLC bottom row, reported by Kong on audiogames.net 2026-08-07 (his column
    -- numbers match the cell positions measured here exactly).
    [30] = "Sigma",
    [32] = "Monster Hunter",
    [34] = "Winter Soldier",
    [35] = "Black Widow",
    [33] = "Venom",
    [31] = "Black Panther",
}

-- Which half of the roster a fighter belongs to. The base roster follows the
-- screen (Capcom left, Marvel right); the DLC row does not: it is 2 Capcom and
-- 4 Marvel, so e.g. Winter Soldier sits on the left despite being Marvel.
local SIDES = {
    [30] = "Capcom", [32] = "Capcom",
    [31] = "Marvel", [33] = "Marvel", [34] = "Marvel", [35] = "Marvel",
}

-- Column of each DLC cell, left to right, on the bottom row.
local DLC_COLUMN = { [30] = 1, [32] = 2, [34] = 3, [35] = 4, [33] = 5, [31] = 6 }

local NAMES_PATH = require("paths").charnames

-- Optional override file (not required - the table above ships with the mod).
local function load_names()
    local f = io.open(NAMES_PATH, "r")
    if not f then return 0 end
    local n = 0
    for line in f:lines() do
        if not line:match("^%s*#") then
            local id, name = line:match("^%s*(%d+)%s*=%s*(.-)%s*$")
            if id and name and name ~= "" then
                NAMES[tonumber(id)] = name
                n = n + 1
            end
        end
    end
    f:close()
    return n
end

-- Row, column and side of a cell, from its id. The grid never changes: the two
-- 3-wide blocks are filled row-major, five rows each, and the DLC sit on a
-- sixth row. (This used to be measured from the 36 actors' positions on every
-- tick, which was most of this reader's 80 ms.)
local function place_of(uid)
    if uid >= 0 and uid <= 14 then
        return math.floor(uid / 3) + 1, uid % 3 + 1, "Capcom"
    elseif uid >= 15 and uid <= 29 then
        local k = uid - 15
        return math.floor(k / 3) + 1, k % 3 + 4, "Marvel"
    elseif DLC_COLUMN[uid] then
        return 6, DLC_COLUMN[uid], SIDES[uid]
    end
    return nil, nil, nil
end

local function is_select_flow(name)
    return name:sub(1, 14) == "GF_CharaSelect" or name == "GF_TeamSettings_C"
end

local function announce(force)
    local flow = C.flow()
    if not flow or not is_select_flow(C.flow_name()) then
        last_key = nil
        return false
    end
    local picker = C.obj(flow, "CharaSelectObj")
    local input = C.obj(flow, "InputObj")
    -- the stage picker has input: not this screen
    if not picker or not input or C.cname(input) ~= C.cname(picker) then
        last_key = nil
        return false
    end
    local parent = C.obj(picker, "SelectParentObj")
    if not parent then return false end

    -- Whose turn it is: the cursor that is showing. Both are hidden while the
    -- costume / colour panel or the stone picker is open over the roster; that
    -- is another reader's screen, so decline without forgetting our place.
    local team, cpu = nil, false
    local n = C.aprop_len(parent, "ArrSelectCursor") or 0
    for i = 1, math.min(n, 4) do
        local cur = C.aprop(parent, "ArrSelectCursor", i)
        if C.valid(cur) and C.bool(cur, "bHidden") == false then
            team = C.num(cur, "teamNo")
            cpu = C.bool(cur, "CheckCPU") == true
            break
        end
    end
    if team ~= 0 and team ~= 1 then return false end

    local uid = C.aprop(parent, "FocusUniqId", team + 1)
    if type(uid) ~= "number" or uid < 0 then return false end

    local key = team .. "#" .. uid
    if (not force) and key == last_key then return true end
    local first = (last_key == nil)
    local side_changed = last_key and last_key ~= "again" and last_key:sub(1, 1) ~= tostring(team)
    last_key = key

    local row, col, side = place_of(uid)
    local msg = NAMES[uid] or ("character " .. uid)
    if side then msg = msg .. ", " .. side .. " side" end
    if row and col then msg = msg .. ", row " .. row .. " column " .. col end
    -- say whose team is being picked whenever that changes
    if team == 1 and (first or side_changed) then
        msg = (cpu and "Opponent's team. " or "Player 2. ") .. msg
    elseif team == 0 and side_changed then
        msg = "Your team. " .. msg
    end
    if first then msg = "Select characters. " .. msg end
    if ann then ann.speak(msg, true) end
    return true
end

function M.announce_now(force)
    return announce(force)
end

-- Another reader has the screen. If that is the stage picker or another
-- level, the next roster visit is a fresh entry ("Select characters."). If it
-- is a panel over the roster (costume, stone, Battle Settings, Team Select),
-- coming back just reads the highlighted fighter again.
function M.closed()
    local flow = C.flow()
    local picker = flow and C.obj(flow, "CharaSelectObj")
    local input = flow and C.obj(flow, "InputObj")
    if not picker or not input or C.cname(input) ~= C.cname(picker) then
        last_key = nil
    elseif last_key then
        last_key = "again"
    end
end

function M.init(announcer)
    ann = announcer
    load_names()
    return M
end

-- Re-read charnames.txt without restarting the game (hotkey).
function M.reload_names()
    local n = load_names()
    if ann then ann.speak("Loaded " .. n .. " character names.", true) end
end

return M
