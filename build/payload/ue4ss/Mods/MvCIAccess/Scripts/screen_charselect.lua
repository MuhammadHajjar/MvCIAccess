-- screen_charselect.lua
-- Reader for CHARACTER SELECT. This screen is built from ACTORS, not widgets:
--   BP_Select_Cursor_C x2 : the cursors (teamNo 0 = 1P, 1 = 2P). Their world
--                           location moves as you navigate the roster.
--   BP_Select_Child_C x36 : the roster cells; each has UniqId (0..35) and sits
--                           at a distinct grid location.
--   BP_Select_Parent_C    : has FocusUniqId (per-team focused cell) + BeforeUniqId.
-- We resolve the highlighted cell (FocusUniqId if readable, else the cell nearest
-- the 1P cursor) and announce its name + grid position.
-- Character NAMES are not text on this screen, so we resolve them from the cell's
-- CharaSelectData when possible, else fall back to a UniqId number. Names are
-- never guessed - a wrong name would send you to the wrong fighter.

local M = {}
local ann = nil
local last_key = nil

-- UniqId -> character name.
-- The roster names are NOT readable from the game: every cell shares one mesh
-- (SM_Chara) and its portrait is a runtime MaterialInstanceDynamic, so nothing
-- in the actor identifies the character. Rather than guess (a wrong name would
-- send the player to the wrong fighter), names are loaded from a plain text file
-- that anyone can fill in once:
--     Documents\MvCI-Access\charnames.txt      lines of  "<UniqId> = <Name>"
-- Unknown ids are announced by number + grid position, which still navigates.
-- Verified in game 2026-08-06 by stepping the roster and listening to the name
-- the game announces on select. Layout confirmed: LEFT half = Capcom (0-14),
-- RIGHT half = Marvel (15-29), bottom row = DLC (30-35, contributed by an owner
-- of the DLC 2026-08-07). The DLC row is 2 Capcom + 4 Marvel, so it does NOT
-- follow the left/right split - see SIDES below.
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

-- Which half of the roster a fighter belongs to.
-- For the base roster this matches screen position (Capcom fills the left half,
-- Marvel the right), but the DLC row does NOT: it is 2 Capcom and 4 Marvel, so
-- e.g. Winter Soldier sits on the left half despite being Marvel. Position is
-- therefore only a fallback.
local SIDES = {
    [30] = "Capcom", [32] = "Capcom",
    [31] = "Marvel", [33] = "Marvel", [34] = "Marvel", [35] = "Marvel",
}

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

local function loc_of(a)
    local v = safe(function() return a:K2_GetActorLocation() end)
    if not v then return nil end
    local x = safe(function() return v.X end)
    local y = safe(function() return v.Y end)
    local z = safe(function() return v.Z end)
    if type(x) ~= "number" or type(z) ~= "number" then return nil end
    return { x = x, y = y or 0, z = z }
end

local function all_valid(cls)
    local out = {}
    local arr = safe(function() return FindAllOf(cls) end)
    if not arr then return out end
    for i = 1, #arr do
        if valid(arr[i]) then out[#out + 1] = arr[i] end
    end
    return out
end

-- The 1P cursor (teamNo 0), or the first cursor found.
local function get_cursor()
    local arr = all_valid("BP_Select_Cursor_C")
    local first = arr[1]
    for i = 1, #arr do
        if num_prop(arr[i], "teamNo") == 0 then return arr[i] end
    end
    return first
end

-- Best-effort character name from a cell's data (never guessed).
local NAME_PROPS = { "CharaName", "Name", "NameText", "DisplayName", "CharaNameText" }
local function cell_name(cell)
    local data = safe(function() return cell.CharaSelectData end)
    if data then
        for _, p in ipairs(NAME_PROPS) do
            local s = ftext(safe(function() return data[p] end))
            if s and s ~= "" and s:find("Text Block", 1, true) == nil then return s end
        end
    end
    return nil
end

-- Grid position of a cell among all cells (1-based row/column).
local function grid_pos(cells, target)
    local tl = loc_of(target)
    if not tl then return nil, nil end
    local xs, zs = {}, {}
    local function add(t, v)
        for i = 1, #t do
            if math.abs(t[i] - v) < 8 then return end
        end
        t[#t + 1] = v
    end
    for i = 1, #cells do
        local l = loc_of(cells[i])
        if l then add(xs, l.x); add(zs, l.z) end
    end
    table.sort(xs)                                     -- left -> right
    table.sort(zs, function(a, b) return a > b end)    -- top -> bottom
    local col, row
    for i = 1, #xs do if math.abs(xs[i] - tl.x) < 8 then col = i break end end
    for i = 1, #zs do if math.abs(zs[i] - tl.z) < 8 then row = i break end end
    return row, col
end

-- Character select and STAGE select share the same level, so both screens'
-- actors exist at once. The screen title is the reliable discriminator.
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
    local title = select_title()
    if not title or not title:find("CHARACTER", 1, true) then
        last_key = nil
        return false
    end
    local cursor = get_cursor()
    if not cursor then
        last_key = nil
        return false
    end
    local cells = all_valid("BP_Select_Child_C")
    if #cells == 0 then
        last_key = nil
        return false
    end

    -- Preferred: the parent's focused UniqId. Else: cell nearest the cursor.
    local sel, uid = nil, nil
    local parent = all_valid("BP_Select_Parent_C")[1]
    if parent then
        local f = num_prop(parent, "FocusUniqId")
        if f then uid = f end
    end
    if uid then
        for i = 1, #cells do
            if num_prop(cells[i], "UniqId") == uid then sel = cells[i] break end
        end
    end
    if not sel then
        local cl = loc_of(cursor)
        if cl then
            local best, bestd
            for i = 1, #cells do
                local l = loc_of(cells[i])
                if l then
                    local dx, dz = l.x - cl.x, l.z - cl.z
                    local d = dx * dx + dz * dz
                    if not bestd or d < bestd then best, bestd = cells[i], d end
                end
            end
            sel = best
        end
        if sel then uid = num_prop(sel, "UniqId") end
    end
    if not sel then return false end

    local name = cell_name(sel) or NAMES[uid]
    local row, col = grid_pos(cells, sel)

    local key = tostring(uid) .. "#" .. tostring(name)
    if (not force) and key == last_key then return true end
    local first = (last_key == nil)
    last_key = key

    local msg = name or ("character " .. tostring(uid))
    -- Side: an explicit entry wins, because the DLC row does not follow the
    -- left/right split. Otherwise fall back to screen position, which is correct
    -- for the base roster (verified 2026-08-06): CAPCOM is the left half
    -- (negative X, UniqId 0-14), MARVEL the right half (positive X, 15-29).
    local side = SIDES[uid]
    if not side then
        local l = loc_of(sel)
        if l then side = (l.x < 0) and "Capcom" or "Marvel" end
    end
    if side then msg = msg .. ", " .. side .. " side" end
    if row and col then msg = msg .. ", row " .. row .. " column " .. col end
    if first then msg = "Select characters. " .. msg end
    if ann then ann.speak(msg, true) end
    return true
end

function M.announce_now(force)
    return announce(force)
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
