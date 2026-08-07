-- screen_title.lua
-- Main-menu reader for MvC:Infinite.
-- Structure discovered live (see memory mvci-accessibility-target):
--   WD_MainMenu_C_0 . IndexFocus  = selected item index (0..itemMax-1)
--   WD_MainMenu_C_0 . itemMax     = number of items (8)
--   WD_MainMenuItem_C_N . index   = that item's index
--   WD_MainMenuItem_C_N . TextBlock_Item : GetText() = the item's visible label
-- We poll IndexFocus; when it changes (or on menu entry), we read the matching
-- item's label and announce "Label, N of M". Manual re-read on Ctrl+Shift+A.

local M = {}
local ann = nil

local was_active = false
local last_idx = nil

local function safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end

local function text_of(widget)
    return safe(function()
        local t = widget:GetText()
        if t == nil then return nil end
        if type(t) == "string" then return t end
        return t:ToString()
    end)
end

-- Pick a VALID, visible WD_MainMenu_C. After a scene change (e.g. character
-- select) an old destroyed instance can linger and be returned by FindFirstOf,
-- so we scan all instances and choose a live, on-screen one.
local function get_main_menu()
    local arr = safe(function() return FindAllOf("WD_MainMenu_C") end)
    local first_valid = nil
    if arr then
        for i = 1, #arr do
            local w = arr[i]
            if safe(function() return w:IsValid() end) then
                if not first_valid then first_valid = w end
                if safe(function() return w:IsVisible() end) == true then return w end
            end
        end
    end
    if first_valid then return first_valid end
    local mm = safe(function() return FindFirstOf("WD_MainMenu_C") end)
    if mm and safe(function() return mm:IsValid() end) then return mm end
    return nil
end

local function menu_visible(mm)
    local v = safe(function() return mm:IsVisible() end)
    if v == nil then return true end -- if API unavailable, assume shown
    return v and true or false
end

-- Label for a given index: the visible WD_MainMenuItem_C whose .index matches.
local function label_for_index(idx)
    local items = safe(function() return FindAllOf("WD_MainMenuItem_C") end)
    if not items then return nil end
    for i = 1, #items do
        local it = items[i]
        local vis = safe(function() return it:IsVisible() end)
        if vis == true then
            local iidx = safe(function() return it.index end)
            if iidx == idx then
                local tb = safe(function() return it.TextBlock_Item end)
                if tb then
                    local txt = text_of(tb)
                    if txt and txt ~= "" then return txt end
                end
            end
        end
    end
    return nil
end

-- Announce the currently-selected item. force=true speaks even if unchanged.
local function announce_current(mm, force)
    local idx = safe(function() return mm.IndexFocus end)
    if type(idx) ~= "number" then return end
    if (not force) and idx == last_idx then return end
    -- During startup the menu widget exists before its item labels are filled in,
    -- which used to produce "item 0, 1 of 8". Stay silent until the real label is
    -- available (and do NOT record the index, so it announces once it loads).
    local name = label_for_index(idx)
    if not name or name == "" then return end
    last_idx = idx
    local total = safe(function() return mm.itemMax end)
    local msg = name
    if type(total) == "number" and total > 0 then
        msg = msg .. ", " .. (idx + 1) .. " of " .. total
    end
    if ann then ann.speak(msg, true) end
end

-- Called on a timer (game thread). Detects menu entry and selection changes.
function M.tick()
    local mm = get_main_menu()
    if not mm or not menu_visible(mm) then
        was_active = false
        return
    end
    if not was_active then
        was_active = true
        last_idx = nil
        if ann then ann.speak("Main menu", true) end
        announce_current(mm, true)
    else
        announce_current(mm, false)
    end
end

-- Synchronous announce (caller must already be on the game thread).
-- Returns true if the main menu is present (and was spoken).
function M.announce_now(force)
    local mm = get_main_menu()
    if mm and menu_visible(mm) then
        announce_current(mm, force)
        return true
    end
    return false
end

-- Fallback: dump all visible text on screen (used before per-screen handlers exist).
function M.read_screen()
    ExecuteInGameThread(function()
        local seen, list = {}, {}
        for _, cls in ipairs({ "TextBlock", "RichTextBlock" }) do
            local arr = safe(function() return FindAllOf(cls) end)
            if arr then
                for i = 1, #arr do
                    local obj = arr[i]
                    local vis = safe(function() return obj:IsVisible() end)
                    if vis ~= false then
                        local t = text_of(obj)
                        if t and t ~= "" and not seen[t] then
                            seen[t] = true
                            list[#list + 1] = t
                        end
                    end
                end
            end
        end
        if ann then
            ann.speak(#list > 0 and table.concat(list, ", ") or "no readable text on screen", true)
        end
    end)
end

-- NO internal poller (main.lua drives one unified tick for all screens).
function M.init(announcer)
    ann = announcer
    return M
end

return M
