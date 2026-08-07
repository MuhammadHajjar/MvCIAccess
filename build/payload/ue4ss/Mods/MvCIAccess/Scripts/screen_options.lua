-- screen_options.lua
-- GENERIC reader for every WD_MenuBase_C list menu (Settings, Battle, Story,
-- Ranking, Online, and the settings sub-screens System/Display/Sound/...).
-- Discovered: all these containers derive from WD_MenuBase_C, which exposes:
--   ItemIndex        (int)  = selected row index (0-based)   <-- the key
--   IsMenuBaseInput  (bool) = this container currently has input (is the active one)
--   IsPopupActive    (bool) = a popup (e.g. the Language picker) is open on top
--   CanvasPanel_Option/CanvasPanel_Item : the rows, as children in order
-- The selected row = the ItemIndex-th child that has an ItemName. No geometry needed.
-- Active container = the visible WD_MenuBase_C whose IsMenuBaseInput is true.
-- Gated on the main-menu widget existing, so it does nothing during gameplay/loading.

local M = {}
local ann = nil
local last_key = nil
local mm_cache = nil

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
    return safe(function() return v:ToString() end)
end

-- Read a numeric property, resolving a UE4SS userdata wrapper via :get() if needed.
local function num_prop(obj, name)
    local v = safe(function() return obj[name] end)
    if type(v) == "number" then return v end
    if type(v) == "userdata" then
        local n = safe(function() return v:get() end)
        if type(n) == "number" then return n end
    end
    return nil
end

-- Length of a raw TArray value, best effort across UE4SS API shapes.
local function arr_count(arr)
    for _, getter in ipairs({
        function() return #arr end,
        function() return arr:GetArrayNum() end,
        function() return arr:Num() end,
    }) do
        local n = safe(getter)
        if type(n) == "number" then return n end
    end
    return nil
end

-- Length of a TArray property.
local function array_len(obj, name)
    local arr = safe(function() return obj[name] end)
    if not arr then return nil end
    return arr_count(arr)
end

-- Whether index i0 (0-based) is safely within arr. If the length is unknown we
-- return false and DO NOT index - indexing out of bounds crashes the game natively.
local function in_bounds(arr, i0)
    local n = arr_count(arr)
    return type(n) == "number" and i0 >= 0 and i0 < n
end

-- Element i0 (0-based) of a TArray, converted to string. Bounds-checked.
local function array_element(obj, name, i0)
    local arr = safe(function() return obj[name] end)
    if not arr or not in_bounds(arr, i0) then return nil end
    local function tostr(v)
        if v == nil then return nil end
        if type(v) == "string" then return v end
        local s = safe(function() return v:ToString() end)
        if type(s) == "string" and s ~= "" then return s end
        return nil
    end
    for _, getter in ipairs({
        function() return arr[i0 + 1] end,
        function() return arr[i0] end,
        function() return arr:get(i0) end,
    }) do
        local s = tostr(safe(getter))
        if s then return s end
    end
    return nil
end

-- Element i0 (0-based) of a TArray, returned as the raw object (widget). Bounds-checked.
local function array_obj(obj, name, i0)
    local arr = safe(function() return obj[name] end)
    if not arr or not in_bounds(arr, i0) then return nil end
    for _, getter in ipairs({
        function() return arr[i0 + 1] end,
        function() return arr[i0] end,
        function() return arr:get(i0) end,
    }) do
        local v = safe(getter)
        if type(v) == "userdata" then return v end
    end
    return nil
end

-- The rows panel: WD_MenuOption uses CanvasPanel_Option; the settings sub-screens
-- (Sound/System/Display) use CanvasPanel_ItemList; the base uses CanvasPanel_Item.
local function rows_panel(w)
    return safe(function() return w.CanvasPanel_Option end)
        or safe(function() return w.CanvasPanel_ItemList end)
        or safe(function() return w.CanvasPanel_Item end)
end

local function panel_child_count(w)
    local panel = rows_panel(w)
    if not panel then return 0 end
    local cnt = safe(function() return panel:GetChildrenCount() end)
    return type(cnt) == "number" and cnt or 0
end

-- Is this a readable list? Either its rows panel has children, OR the WD_MenuBase
-- Items array is non-empty (sub-screens spawn rows outside the panel).
local function has_list(w)
    if not valid(w) then return false end
    if panel_child_count(w) > 0 then return true end
    local n = array_len(w, "Items")
    return type(n) == "number" and n > 0
end

-- Ordered list of real option rows (each with an ItemName). Tries the rows panel
-- first (proven for the top-level lists), then the WD_MenuBase Items array (needed
-- for the settings sub-screens, whose rows are not the panel's direct children).
local function item_list(container)
    local items = {}
    local cnt = panel_child_count(container)
    if cnt > 0 then
        local panel = rows_panel(container)
        for j = 0, cnt - 1 do
            local ch = safe(function() return panel:GetChildAt(j) end)
            local name = ch and ftext(safe(function() return ch.ItemName end))
            if name and name ~= "" then items[#items + 1] = { w = ch, name = name } end
        end
        if #items > 0 then return items end
    end
    local n = array_len(container, "Items")
    if type(n) == "number" and n > 0 then
        for i0 = 0, n - 1 do
            local w = array_obj(container, "Items", i0)
            local name = w and ftext(safe(function() return w.ItemName end))
            if name and name ~= "" then items[#items + 1] = { w = w, name = name } end
        end
    end
    return items
end

-- Find the main-menu widget fresh each tick (no persistent cache). A cached
-- reference can stay "valid" after a scene transition (char select / team setup /
-- fighter card) yet point at a stale instance whose ActiveMenu never updates,
-- which is exactly what made submenus go silent after going back. Re-finding and
-- preferring a valid, VISIBLE instance keeps it correct.
local function get_mm()
    local arr = safe(function() return FindAllOf("WD_MainMenu_C") end)
    local first_valid = nil
    if arr then
        for i = 1, #arr do
            local w = arr[i]
            if valid(w) then
                first_valid = first_valid or w
                if safe(function() return w:IsVisible() end) == true then return w end
            end
        end
    end
    return first_valid
end

-- Settings sub-screens that open on top of the main options list (they don't
-- update ActiveMenu, so we look for them explicitly).
-- Ordered most-used first: the round-robin probe reaches these soonest.
local SUBSCREEN_CLASSES = {
    -- settings sub-screens (most common)
    "WD_SoundOption_C", "WD_SystemSetting_C", "WD_DisplaySetting_C", "WD_Language_C",
    -- online (all standard option lists, verified 2026-08-06)
    "WD_OnlineMenu_C", "WD_OnlineSetting_C",
    "WD_LobbyMenu_C", "WD_MMRanking_C", "WD_LobbySearch_C", "WD_LobbyMake_C",
    "WD_ReplayListProf_C",
    -- control config
    "WD_KeyConfMain_C", "WD_KeyboardConfMain_C", "WD_CtrlSelectMain_C",
}
-- Find the sub-screen layered on top of the current list, BY CLASS.
-- (A broad FindAllOf on the shared base class looks tempting but does not work:
-- several menus are visible with the input flag set at once, so it picks the
-- wrong one - that regression silenced the settings sub-screens.)
--
-- PERF: probing every class each tick would cost ~14 lookups. Instead:
--   * while a sub-screen is already open it is CACHED and re-checked for free;
--   * otherwise only a few classes are probed per tick, round-robin, so the
--     whole list is covered about once a second at a bounded cost.
local sub_cached, sub_idx = nil, 1
local PROBES_PER_TICK = 3

local function subscreen_ok(w)
    return valid(w)
        and safe(function() return w:IsVisible() end) == true
        and safe(function() return w.IsMenuBaseInput end) == true
        and has_list(w)
end

local function scan_subscreen()
    if subscreen_ok(sub_cached) then return sub_cached end
    sub_cached = nil
    local n = #SUBSCREEN_CLASSES
    for _ = 1, math.min(PROBES_PER_TICK, n) do
        local cls = SUBSCREEN_CLASSES[sub_idx]
        sub_idx = (sub_idx % n) + 1
        local arr = safe(function() return FindAllOf(cls) end)
        if arr then
            for i = 1, #arr do
                local w = arr[i]
                if subscreen_ok(w) then
                    sub_cached = w
                    return w
                end
            end
        end
    end
    return nil
end

local function scan_subscreen_by_class()
    for _, cls in ipairs(SUBSCREEN_CLASSES) do
        local arr = safe(function() return FindAllOf(cls) end)
        if arr then
            for i = 1, #arr do
                local w = arr[i]
                -- require IsMenuBaseInput so lingering (visible-but-inactive)
                -- sub-screens are not picked over the active one.
                if safe(function() return w:IsVisible() end) == true
                    and safe(function() return w.IsMenuBaseInput end) == true
                    and has_list(w) then
                    return w
                end
            end
        end
    end
    return nil
end

local cached_container = nil
local tick_n = 0

-- In-match PAUSE menus. ONLY specific, known classes - never a broad
-- FindAllOf("WD_MenuBase_C") (that returns stale/HUD widgets in a match).
-- Property reads happen only after valid() + IsVisible()==true.
-- Verified class names, one per mode (all share the same option-row layout).
-- Screens that are active while the main-menu widget is hidden: the in-match
-- pause menus, and the character-select sub-pickers (costume/colour, Infinity
-- Stone) which appear after choosing a fighter.
local PAUSE_CLASSES = {
    "WD_PauseMenu_Training_C",
    "WD_PauseMenu_Arcade_C",
    "WD_PauseMenu_Versus_C",
    "WD_Menu_Con_C",          -- costume / colour picker
    "WD_Menu_Gem_Button_C",   -- Infinity Stone picker
}
-- Story's pause menu has NO option rows - it is an information screen (Win
-- Conditions / Character Conditions / active buffs), handled separately below.
local STORY_PAUSE_CLASS = "WD_PauseMenu_Story_C"
local pause_cached, pause_tick = nil, 0

local function scan_pausemenu()
    for _, cls in ipairs(PAUSE_CLASSES) do
        local arr = safe(function() return FindAllOf(cls) end)
        if arr then
            for i = 1, #arr do
                local w = arr[i]
                if valid(w)
                    and safe(function() return w:IsVisible() end) == true
                    and safe(function() return w.IsMenuBaseInput end) == true
                    and has_list(w) then
                    return w
                end
            end
        end
    end
    return nil
end

-- The active list container, or nil.
-- In the menu system (main-menu widget visible) -> follow ActiveMenu + sub-screens.
-- Otherwise (in a match, or main menu gone) -> look for a known PAUSE menu only.
local function active_container()
    local mm = get_mm()
    if mm and safe(function() return mm:IsVisible() end) == true then
        pause_cached = nil
        local am = safe(function() return mm.ActiveMenu end)
        if not has_list(am) then
            cached_container = nil
            return nil -- on the main menu, not in a sublist
        end
        -- Resolve the input-owning container EVERY tick. This is only one
        -- FindAllOf, so it is affordable, and it must not be cached/timed: menus
        -- nest (a sub-screen opens on top while ActiveMenu still points at the
        -- parent), and a stale cache is exactly what silenced sub-screens before.
        cached_container = scan_subscreen() or am
        if has_list(cached_container) then return cached_container end
        if has_list(am) then return am end
        return nil
    end
    -- In a match (or no main menu): only the known standalone/pause classes.
    -- PERF: while nothing is open (i.e. actual fighting) this must stay nearly
    -- free, so the scan is rate-limited instead of running every tick.
    cached_container = nil
    local p = pause_cached
    if valid(p) and safe(function() return p:IsVisible() end) == true and has_list(p) then
        return p
    end
    pause_cached = nil
    pause_tick = pause_tick + 1
    if pause_tick % 4 == 0 then
        pause_cached = scan_pausemenu()
    end
    if has_list(pause_cached) then return pause_cached end
    return nil
end

-- Selected item, 1-based position, total. Uses ItemIndex; falls back to first item.
local function selected(container)
    local items = item_list(container)
    if #items == 0 then return nil end
    -- Settings sub-screens (Sound/System/Display) track selection with FocusIndex;
    -- the top lists (Settings/Battle/Story) use ItemIndex. Prefer FocusIndex.
    local idx = num_prop(container, "FocusIndex")
    if idx == nil then idx = num_prop(container, "ItemIndex") end
    local pos
    if idx and idx >= 0 and idx < #items then
        pos = idx + 1
    else
        pos = 1
    end
    return items[pos], pos, #items
end

-- Current value of a value-picker row: SubItemLabel, else SubItemNames[SubItemIndex].
-- Only touch the sub-item array when the row actually HAS sub-items (SubItemMax>0);
-- button rows have an empty SubItemNames and indexing it would crash the game.
local function item_value(w)
    local s = ftext(safe(function() return w.SubItemLabel end))
    if s and s ~= "" then return s end
    local smax = num_prop(w, "SubItemMax")
    if smax and smax > 0 then
        local si = num_prop(w, "SubItemIndex")
        if si and si >= 0 and si < smax then
            local s2 = array_element(w, "SubItemNames", si)
            if s2 and s2 ~= "" then return s2 end
        end
    end
    return nil
end

local function describe(item, pos, total, popup)
    local msg = item.name
    local val = item_value(item.w)
    if val and val ~= "" then msg = msg .. ": " .. val end
    if safe(function() return item.w.IsDisable end) == true then msg = msg .. ", disabled" end
    if type(pos) == "number" and type(total) == "number" then
        msg = msg .. ", " .. pos .. " of " .. total
    end
    if popup then msg = msg .. ", submenu open" end
    return msg
end

-- The Language picker is a special popup: languages are images (Image_Lang0..14),
-- selection is WD_Language_C.IndexFocus, names are in LangStrArray.
local function language_open()
    local arr = safe(function() return FindAllOf("WD_Language_C") end)
    if arr then
        for i = 1, #arr do
            local w = arr[i]
            -- Only when it is the ACTIVE screen (has input) - it lingers visible
            -- after use, which would otherwise hijack every other menu.
            if valid(w) and safe(function() return w:IsVisible() end) == true
                and safe(function() return w.IsMenuBaseInput end) == true then
                return w
            end
        end
    end
    return nil
end

local function announce_language(w, force)
    local idx = num_prop(w, "IndexFocus") or 0
    local total = array_len(w, "LangStrArray")
    if not total or total <= 0 then
        total = 0
        for i = 0, 24 do
            if safe(function() return w["Image_Lang" .. i] end) ~= nil then total = i + 1 end
        end
    end
    local name = array_element(w, "LangStrArray", idx)
    local msg = name or ("language " .. (idx + 1))
    if total and total > 0 then msg = msg .. ", " .. (idx + 1) .. " of " .. total end
    local key = "LANG#" .. tostring(idx)
    if (not force) and key == last_key then return true end
    last_key = key
    if ann then ann.speak(msg, true) end
    return true
end

-- GetFullName() is "Class /Path"; keep the path for prefix matching.
local function path_of(fn)
    return fn and (fn:match("%s(.+)$") or fn) or nil
end

-- Story's pause menu is an INFO screen (no option rows): Win Conditions,
-- Character Conditions, active buffs. Announce its text ONCE per open - the
-- text sweep is only affordable because it never repeats while paused.
local story_spoken = false
local story_cached, story_tick = nil, 0

-- Rate-limited: this costs a FindAllOf, and it must not run every tick while
-- navigating normal menus. Once found, the cached widget is checked cheaply.
local function story_pause_open()
    if valid(story_cached) and safe(function() return story_cached:IsVisible() end) == true then
        return story_cached
    end
    story_cached = nil
    story_tick = story_tick + 1
    if story_tick % 4 ~= 0 then return nil end
    local arr = safe(function() return FindAllOf(STORY_PAUSE_CLASS) end)
    if not arr then return nil end
    for i = 1, #arr do
        local w = arr[i]
        if valid(w) and safe(function() return w:IsVisible() end) == true then
            story_cached = w
            return w
        end
    end
    return nil
end

local function announce_story_pause(w)
    local base = path_of(safe(function() return w:GetFullName() end))
    if not base then return end
    local arr = safe(function() return FindAllOf("TextBlock") end)
    if not arr then return end
    local seen, parts = {}, {}
    for i = 1, #arr do
        local tb = arr[i]
        local p = path_of(safe(function() return tb:GetFullName() end))
        if p and p ~= base and p:sub(1, #base) == base
            and safe(function() return tb:IsVisible() end) == true then
            local t = ftext(safe(function() return tb:GetText() end))
            if t and t ~= "" and not seen[t] and t:find("Text Block", 1, true) == nil then
                seen[t] = true
                parts[#parts + 1] = t
            end
        end
    end
    if #parts > 0 and ann then ann.speak(table.concat(parts, ", "), true) end
end

local function announce(force)
    -- Story pause: information screen, announced once when it opens.
    local sp = story_pause_open()
    if sp then
        if force or not story_spoken then
            story_spoken = true
            announce_story_pause(sp)
        end
        return true
    end
    story_spoken = false

    local container = active_container()
    if not container then
        last_key = nil
        return false
    end
    -- Language picker popup takes priority when open.
    local lang = language_open()
    if lang then return announce_language(lang, force) end
    local item, pos, total = selected(container)
    if not item then return true end
    local popup = safe(function() return container.IsPopupActive end) == true
    -- include the current value + its index in the key so CHANGING a value
    -- (left/right on the same row) re-announces it - configurable by ear.
    local val = item_value(item.w) or ""
    local sidx = num_prop(item.w, "SubItemIndex")
    local key = tostring(safe(function() return container:GetFullName() end)) ..
        "#" .. tostring(pos) .. "#" .. val .. "#" .. tostring(sidx) .. (popup and "P" or "")
    if (not force) and key == last_key then return true end
    last_key = key
    local msg = describe(item, pos, total, popup)
    if msg and ann then ann.speak(msg, true) end
    return true
end

function M.tick()
    announce(false)
end

function M.announce_now(force)
    return announce(force)
end

-- NO internal poller. main.lua drives ONE unified game-thread tick for every
-- screen. Two independent pollers each queuing ExecuteInGameThread work built an
-- unbounded backlog whenever the game thread pumped slowly (during a match) -
-- that backlog is what froze the mod.
function M.init(announcer)
    ann = announcer
    return M
end

return M
