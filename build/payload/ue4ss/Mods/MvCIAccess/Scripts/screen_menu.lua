-- screen_menu.lua
-- One reader for every menu-shaped screen: dialogs, the title prompt, the main
-- menu, every option list (Story, Battle, Online and its sub-screens, Settings
-- and its sub-screens, all the pause menus and their pages, the battle-over
-- menu) and, as a fallback, any other screen of the menu family, whose text it
-- reads out in layout order.
--
-- It replaces the detection in screen_options.lua and screen_title.lua, which
-- found their screen with FindAllOf (about 19 ms a call, several calls a tick)
-- and could latch onto a menu that had another one open on top of it. Here the
-- current screen comes from core.lua: the dialog the popup controller reports,
-- else the one menu that has input and nothing above it, else the main menu.

local M = {}
local C = require("core")
local ann = nil

-- Speak a row's help line after the row. It is the same sentence the game
-- prints under the menu, and moving the cursor cuts it off.
local SPEAK_HELP = true

local last_screen = nil -- which screen (and page) was announced last
local last_row = nil    -- which row / text was announced last

local function say(text)
    if ann and text and text ~= "" then ann.speak(text, true) end
end

local function join(parts, sep)
    local out = {}
    for _, p in ipairs(parts) do
        if p and p ~= "" then out[#out + 1] = p end
    end
    return table.concat(out, sep)
end

-- "CAPTAIN AMERICA" -> "Captain America".
local function title_case(s)
    if not s or s:find("%l") then return s end
    return (s:lower():gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- Sentence-case a caption the game writes in capitals ("RANKED MATCH").
local function title(s)
    if not s then return nil end
    if s:find("%l") then return s end
    return (s:lower():gsub("^%l", string.upper))
end

-- Dialogs --------------------------------------------------------------------
-- WD_WindowBase_C: confirmations ("This will overwrite your previous autosave
-- data. Continue?"), notices and waits. The message is MessageText; the choices
-- are the labels of its button strip.

local dialog_seen_key, dialog_seen_tick = nil, 0

local function read_dialog(w, force)
    local msg = C.str(w, "MessageText")
    if msg then msg = msg:gsub("[\r\n]+", " "):gsub("%s+", " ") end
    local nav = C.obj(w, "WD_BtnNavi")
    local choices = nav and C.texts(nav, 40) or {}
    if not msg then
        local all = C.texts(w, 120)
        msg = table.concat(all, ". ")
        choices = {}
    end
    -- The key leaves the choices out: they fade in after the message and out
    -- before it, and either would otherwise read the dialog a second time.
    local key = "DLG#" .. C.fname(w) .. "#" .. msg
    if key ~= dialog_seen_key then
        dialog_seen_key, dialog_seen_tick = key, C.tick_count()
    end
    if (not force) and key == last_row then return true end
    -- So give the choices two ticks to appear before speaking without them.
    if #choices == 0 and not force and C.tick_count() - dialog_seen_tick < 2 then return true end
    last_row, last_screen = key, key
    local tail = ""
    if #choices > 0 then tail = " " .. table.concat(choices, ", or ") .. "." end
    say(msg .. tail)
    return true
end

-- Option rows ----------------------------------------------------------------

-- The rows of a list, in order. WD_MenuBase_C keeps them in Items; the
-- Collection lists keep theirs in Buttons and Battle Settings in ButtonArray;
-- a few older lists only have them as children of a rows panel.
local ROW_ARRAYS = { "Items", "Buttons", "ButtonArray" }
local ROW_PANELS = { "CanvasPanel_Option", "CanvasPanel_ItemList", "CanvasPanel_Item" }

-- A row's label: option rows carry ItemName, the other kinds a label TextBlock.
local function label_of(row)
    local name = C.str(row, "ItemName")
    if name then return name end
    local tb = C.obj(row, "TextBlock_Label")
    return tb and C.text(tb) or nil
end

local function rows_of(w)
    local rows = {}
    for _, an in ipairs(ROW_ARRAYS) do
        local n = C.aprop_len(w, an)
        if type(n) == "number" and n > 0 then
            for i = 1, n do
                local r = C.aprop(w, an, i)
                if C.valid(r) then rows[#rows + 1] = r end
            end
            if #rows > 0 then return rows end
        end
    end
    for _, pn in ipairs(ROW_PANELS) do
        local panel = C.obj(w, pn)
        local cnt = panel and C.safe(function() return panel:GetChildrenCount() end)
        if type(cnt) == "number" and cnt > 0 then
            for j = 0, cnt - 1 do
                local ch = C.safe(function() return panel:GetChildAt(j) end)
                if C.valid(ch) and C.str(ch, "ItemName") then rows[#rows + 1] = ch end
            end
            if #rows > 0 then return rows end
        end
    end
    return rows
end

-- 0-based cursor of a list. Which property carries it depends on the class.
local function cursor_of(w)
    return C.num(w, "FocusIndex") or C.num(w, "ItemIndex") or C.num(w, "IndexFocus")
        or C.num(w, "FocusMenu")
end

-- What a row is set to, as the screen shows it.
local function value_of(row)
    local cls = C.cname(row)
    local si, smax = C.num(row, "SubItemIndex"), C.num(row, "SubItemMax")
    if cls:find("Slider", 1, true) then
        if si and smax and smax > 0 then return si .. " of " .. smax end
        return nil
    end
    if cls:find("Checkbox", 1, true) then
        -- two boxes, Element1 and Element2; SubItemIndex says which is ticked
        local which = (si == 1) and "Element2" or "Element1"
        local tb = C.obj(row, which)
        return tb and C.text(tb) or nil
    end
    -- spin rows show their value in a TextBlock called Element, the Battle
    -- Settings rows in one called TextBlock_Subitem
    for _, tn in ipairs({ "Element", "TextBlock_Subitem" }) do
        local el = C.obj(row, tn)
        if el and C.visible(el) then
            local t = C.text(el)
            if t then return t end
        end
    end
    return C.str(row, "SubItemLabel")
end

-- Caption of a list screen ("RANKED MATCH", "TRAINING MENU", "BATTLE OVER").
local function caption_of(w)
    for _, holder in ipairs({ "WD_Header", "WD_PauseCommon", "WD_Coll_Caption" }) do
        local h = C.obj(w, holder)
        local tb = h and C.obj(h, "TextBlock_Caption")
        local t = tb and C.text(tb)
        if t then return title(t) end
    end
    local tb = C.obj(w, "TextBlock_Caption") or C.obj(w, "TextBlock_Label")
    return tb and title(C.text(tb)) or nil
end

-- Pause menus have pages, turned with the shoulder buttons (X and C on the
-- keyboard): SelectListNo is the page, ArrListAsset has one entry per page.
local function page_of(w)
    local page = C.num(w, "SelectListNo")
    if not page then return nil, nil end
    return page, C.aprop_len(w, "ArrListAsset")
end

local function read_list(m, rows, force)
    local w = m.w
    local idx = cursor_of(w) or 0
    local row = rows[idx + 1]
    if not row then return false end
    local name = label_of(row)
    if not name then return false end
    local value = value_of(row)
    local disabled = C.bool(row, "IsDisable") == true
    local page, pages = page_of(w)

    local screen = C.fname(w) .. "#" .. tostring(page)
    local key = screen .. "#" .. idx .. "#" .. name .. "#" .. tostring(value) .. "#" .. tostring(disabled)
    if (not force) and key == last_row then return true end

    local parts = {}
    if screen ~= last_screen or force then
        local cap = caption_of(w)
        if cap then parts[#parts + 1] = cap .. "." end
        if page and pages and pages > 1 then
            parts[#parts + 1] = "Page " .. (page + 1) .. " of " .. pages .. "."
        end
    end
    local line = name
    if value then line = line .. ": " .. value end
    if disabled then line = line .. ", unavailable" end
    line = line .. ", " .. (idx + 1) .. " of " .. #rows .. "."
    parts[#parts + 1] = line
    if SPEAK_HELP then
        local help = C.str(row, "LineHelpText")
        if help then parts[#parts + 1] = (help:gsub("[\r\n]+", " ")) end
    end
    last_screen, last_row = screen, key
    say(table.concat(parts, " "))
    return true
end

-- A screen of the menu family that is not a list: read what it says. Used for
-- the tutorial tip that pauses the first story fight, the story pause menu's
-- conditions page, and anything not met yet, so that no screen is silent.
-- Screens whose only content is button prompts drawn as key pictures, which
-- cannot be read off the screen. The wording here was taken from the picture.
local FIXED_PAGES = {
    -- pausing a story cutscene: "Esc Resume", "C Skip"
    WD_MoviePause_C = "Cutscene paused. Escape resumes. C, or the right shoulder button, skips the cutscene.",
}

-- Join pieces of on-screen text into sentences. A sentence that has a key
-- picture in the middle arrives as two pieces ("Score a hit with" and "(light
-- punch) and keep tapping ..."), so a piece that starts in lower case or with a
-- bracket continues the one before it.
local function sentences(pieces)
    local out = ""
    for _, p in ipairs(pieces) do
        if out == "" then
            out = p
        elseif p:find("^[%.,;:!%?]") then
            -- what is left after a key picture: just the full stop
            out = out .. p
        elseif out:find("[%.%!%?:]$") then
            out = out .. " " .. p
        elseif p:find("^[%l%(]") then
            out = out .. " " .. p
        else
            out = out .. ". " .. p
        end
    end
    return out
end

-- The story pause menu's first page: what it takes to win and which boosts
-- each fighter has. Its widgets are laid out in columns, so they are read by
-- name here rather than in layout order.
local function story_conditions(w)
    local box = C.obj(w, "WD_WindowControl_New_327") or C.obj(w, "WD_WindowControl_New")
    if not box then return nil end
    local function t(holder, name)
        local tb = holder and C.obj(holder, name)
        return tb and C.visible(tb) and C.text(tb) or nil
    end
    local parts = {}
    local head, text = t(box, "TextBlock_Title_V"), t(box, "TextBlock_Text_V")
    if head and text then
        parts[#parts + 1] = head .. ": " .. (text:gsub("%.$", ""))
    elseif head or text then
        parts[#parts + 1] = ((head or text):gsub("%.$", ""))
    end
    local function fighter(prop)
        local l = C.obj(box, prop)
        if not l or not C.visible(l) then return nil end
        local name = t(l, "TextBlock_ChrName")
        if not name then return nil end
        local buffs = {}
        for i = 0, 3 do
            local b = t(l, "TextBlock_0" .. i)
            if b then buffs[#buffs + 1] = b end
        end
        if #buffs > 0 then return title_case(name) .. ": " .. table.concat(buffs, ", ") end
        return title_case(name)
    end
    -- (a list built with nil holes would stop at the first missing fighter)
    local function side(a, b)
        local list = {}
        for _, prop in ipairs({ a, b }) do
            local f = fighter(prop)
            if f then list[#list + 1] = f end
        end
        return table.concat(list, ". ")
    end
    local mine = side("WDBuffList1PMani_New", "WD_BuffList1PSub_New")
    local theirs = side("WD_BuffList2PMain_New", "WD_BuffList2PSub_New")
    if mine ~= "" then parts[#parts + 1] = "Your team. " .. mine end
    if theirs ~= "" then parts[#parts + 1] = "Opponents. " .. theirs end
    if #parts == 0 then return nil end
    return table.concat(parts, ". ") .. "."
end

-- The Controls Guide (pause menu) is two full-screen PICTURES with no text
-- behind them, so each page is written out here from the picture. It shows a
-- controller; the keyboard keys are whatever Keyboard Settings says.
local CONTROLS_GUIDE = {
    [0] = "Controls guide, page 1 of 2: the controller. "
        .. "Left stick or D-pad: move. Up is a jump, the up diagonals a diagonal jump, down is crouch. "
        .. "Hold away from the opponent to guard high, down and away to guard low. "
        .. "Dash: tap forward twice, or forward with both punches. Backdash: tap back twice, or back with both punches. "
        .. "Super jump: down, then up. "
        .. "X is Light Punch, Y is Heavy Punch, A is Light Kick, B is Heavy Kick. "
        .. "Left trigger is both punches together, right trigger is both kicks together. "
        .. "Right bumper is Active Switch. Left bumper is Infinity Surge. "
        .. "Both bumpers together is Infinity Storm, once the Infinity Stone gauge is half full. "
        .. "Advancing Guard: any two attack buttons while guarding. "
        .. "Throw, or throw escape: next to the opponent, forward or back with Heavy Punch. "
        .. "View button taunts. Menu button pauses. "
        .. "All of this assumes your fighter faces right; facing left, forward and back swap. "
        .. "Next page: C, or the right shoulder button.",
    [1] = "Controls guide, page 2 of 2: gauges and the battle system. "
        .. "Vitality gauge, top of the screen: the health of your fighter and partner. "
        .. "Infinity Stone gauge, bottom corner: fills as you take damage or use Infinity Surge, and powers Infinity Storm. "
        .. "Hyper Combo gauge, bottom: fills as you hit the enemy or take damage, and is spent on Hyper Combos. "
        .. "Time counter, top centre: the time left; an infinity sign means no limit. "
        .. "Active Switch, right bumper: calls your partner in at any time, even while you move or attack; "
        .. "they dash in and attack. Hold it to call them in while blocking or being hit, which costs two Hyper Combo gauges. "
        .. "Infinity Surge, left bumper: a special action that depends on your stone, such as a strong attack or a very fast dash. "
        .. "Infinity Storm, both bumpers with the stone gauge at half or more: unleashes the stone's full power. "
        .. "Press both again during the storm for a level 3 Hyper Combo that spends the stone gauge instead of the Hyper Combo gauge. "
        .. "Auto Combo: land a Light Punch and keep tapping it. "
        .. "Easy Hyper Combo: Heavy Punch and Heavy Kick together, for one Hyper Combo gauge. "
        .. "Previous page: X, or the left shoulder button.",
}

local page_seen_key, page_seen_tick = nil, 0

-- Keys shown as pictures inside tips, filled in where the tip says which.
local KEY_IN_TIP = {
    { match = "switch between characters", gap = "by pressing%.", fill = "by pressing Active Switch." },
}

local function read_page(m, force)
    local w = m.w
    local body = FIXED_PAGES[m.cls]
    if not body and m.cls == "WD_preview_C" then
        body = CONTROLS_GUIDE[C.num(w, "PageIndex") or 0]
    end
    if not body and m.cls == "WD_PauseMenu_Story_C" then
        local cond = story_conditions(w)
        if cond then
            local page, pages = C.num(w, "SelectListNo"), C.aprop_len(w, "ArrListAsset")
            body = "Pause menu."
            if page and pages and pages > 1 then
                body = body .. " Page " .. (page + 1) .. " of " .. pages .. "."
            end
            body = body .. " " .. cond .. " Turn the page for the menu: C, or the right shoulder button."
        end
    end
    if not body then
        -- the button prompts are read last, whatever their place in the layout
        local nav = C.obj(w, "WD_BtnNavi")
        local prompts, is_prompt = nav and C.texts(nav, 40) or {}, {}
        for _, p in ipairs(prompts) do is_prompt[p] = true end
        local main = {}
        for _, t in ipairs(C.texts(w, 300)) do
            if not is_prompt[t] then main[#main + 1] = t end
        end
        if #main == 0 and #prompts == 0 then return false end
        local text = sentences(main)
        -- Tips name a key with a picture. The ones whose key is certain from
        -- their own wording get it written in.
        for _, k in ipairs(KEY_IN_TIP) do
            if text:find(k.match, 1, true) then text = text:gsub(k.gap, k.fill, 1) end
        end
        -- The key ignores the prompts: they fade in after the text, and would
        -- otherwise read the page a second time. Like a dialog, the page waits
        -- two ticks for them before speaking without.
        local key = "PAGE#" .. C.fname(w) .. "#" .. text
        if key ~= page_seen_key then page_seen_key, page_seen_tick = key, C.tick_count() end
        if (not force) and key == last_row then return true end
        if #prompts == 0 and not force and C.tick_count() - page_seen_tick < 2 then return true end
        if #prompts > 0 then
            if text ~= "" and not text:find("[%.%!%?]$") then text = text .. "." end
            text = text .. " " .. table.concat(prompts, ", ") .. "."
        end
        last_screen, last_row = key, key
        say(text)
        return true
    end
    local key = "PAGE#" .. C.fname(w) .. "#" .. body
    if (not force) and key == last_row then return true end
    last_screen, last_row = key, key
    say(body)
    return true
end

-- The main menu ----------------------------------------------------------------
-- WD_MainMenu_C keeps its eight labels and their help lines as plain arrays.

local main_seen_tick = nil

local function read_main_menu(mm, force)
    local idx = C.num(mm, "IndexFocus")
    if not idx then return false end
    -- Coming back from a fight or a select screen, the root appears a moment
    -- before the submenu it is about to reopen, with its cursor still on the
    -- first item. Let it settle for two ticks before calling it the main menu.
    if not main_seen_tick then main_seen_tick = C.tick_count() end
    if not force and C.tick_count() - main_seen_tick < 2 then return true end
    local label = C.tostr(C.aprop(mm, "ListItemTextArray", idx + 1))
    -- the widget exists a moment before its labels are filled in
    if not label or label == "" then return true end
    local total = C.aprop_len(mm, "ListItemTextArray") or C.num(mm, "itemMax") or 0
    local screen = "MAIN#" .. C.fname(mm)
    local key = screen .. "#" .. idx
    if (not force) and key == last_row then return true end
    local parts = {}
    if screen ~= last_screen then parts[#parts + 1] = "Main menu." end
    parts[#parts + 1] = label .. ", " .. (idx + 1) .. " of " .. total .. "."
    if SPEAK_HELP then
        local help = C.tostr(C.aprop(mm, "HelpTextArray", idx + 1))
        if help and help ~= "" then parts[#parts + 1] = help end
    end
    last_screen, last_row = screen, key
    say(table.concat(parts, " "))
    return true
end

-- Notices ---------------------------------------------------------------------
-- Screens with nothing to navigate, where silence leaves a player guessing:
-- the title prompt, loading and saving.

local NOTICES = {
    { cls = "WD_Title_C", flow = "GF_TitleLogo_C", say = "Press any button." },
    { cls = "WD_Loading_C", say = "Loading." },
    { cls = "WD_Saving_C", say = "Saving." },
}

-- When each notice was last spoken: the saving and loading widgets blink in and
-- out, and one save should be one "Saving.", not two.
local notice_said = {}
local NOTICE_QUIET_TICKS = 16 -- 4 seconds

local function read_notice(force)
    local flow = C.flow_name()
    for _, n in ipairs(NOTICES) do
        if (not n.flow or n.flow == flow) and C.shown(n.cls) then
            local key = "NOTE#" .. n.cls
            if force or key ~= last_row then
                last_screen, last_row = key, key
                local said = notice_said[n.cls]
                if force or not said or C.tick_count() - said > NOTICE_QUIET_TICKS then
                    say(n.say)
                end
            end
            notice_said[n.cls] = C.tick_count()
            return true
        end
    end
    return false
end

-- Entry point ------------------------------------------------------------------

-- Screens that other readers own. This reader must not answer for them.
local OWNED_ELSEWHERE = {
    WD_CommandList_C = true,
    WD_KeyboardConfMain_C = true, WD_KeyConfMain_C = true,
    WD_KeyboardConf_C = true, WD_KeyConf_C = true,
    WD_MissionMain_C = true, WD_MissionMain_Update1_C = true, WD_MissionMain_Update2_C = true,
}

-- The language picker: the languages are pictures, the cursor is IndexFocus
-- and LangStrArray holds each one's code.
local LANG_NAMES = {
    en = "English", ja = "Japanese", fr = "French", de = "German", it = "Italian",
    es = "Spanish", ["es-419"] = "Latin American Spanish", ["es-mx"] = "Latin American Spanish",
    ru = "Russian", pl = "Polish", pt = "Portuguese", ["pt-br"] = "Brazilian Portuguese",
    ar = "Arabic", ko = "Korean", th = "Thai", tr = "Turkish",
    zh = "Chinese", ["zh-hans"] = "Simplified Chinese", ["zh-hant"] = "Traditional Chinese",
    ["zh-cn"] = "Simplified Chinese", ["zh-tw"] = "Traditional Chinese",
}

local function read_language(w, force)
    local idx = C.num(w, "IndexFocus") or 0
    local total = C.aprop_len(w, "LangStrArray") or 0
    local code = C.tostr(C.aprop(w, "LangStrArray", idx + 1))
    local name = code and (LANG_NAMES[code:lower()] or code) or ("language " .. (idx + 1))
    local key = "LANG#" .. C.fname(w) .. "#" .. idx
    if (not force) and key == last_row then return true end
    local first = last_screen ~= "LANG"
    last_screen, last_row = "LANG", key
    local msg = name
    if total > 0 then msg = msg .. ", " .. (idx + 1) .. " of " .. total end
    if first or force then msg = "Language. " .. msg end
    say(msg .. ".")
    return true
end

-- How many ticks in a row nothing of this reader's has been on screen.
local idle_ticks = 0

-- True if this reader spoke for (or silently owns) the current screen.
function M.announce_now(force)
    local dlg = C.dialog()
    if dlg then
        idle_ticks = 0
        return read_dialog(dlg, force)
    end
    -- the next dialog, even the same one again, gets its short wait for choices
    dialog_seen_key = nil

    local m = C.active_menu()
    if m then
        main_seen_tick = nil
        idle_ticks = 0
        if OWNED_ELSEWHERE[m.cls] then
            -- another reader speaks here: coming back must read the row again
            last_screen, last_row = nil, nil
            return false
        end
        if m.cls == "WD_Language_C" then return read_language(m.w, force) end
        local rows = rows_of(m.w)
        if #rows > 0 and read_list(m, rows, force) then return true end
        return read_page(m, force)
    end

    -- Between two screens nothing has input for a tick or two. Say nothing
    -- then, rather than announce the main menu that is still drawn behind.
    if C.submenu_showing() then
        idle_ticks = 0
        return true
    end

    local mm = C.main_menu()
    if mm then
        -- The root's ActiveMenu is the root itself on the main menu proper and
        -- the submenu (Story, Battle, Settings) once inside one. While a
        -- deeper screen is still fading in, the submenu is hidden for a
        -- moment and only the root is left on screen: not the main menu.
        local am = C.obj(mm, "ActiveMenu")
        idle_ticks = 0
        if am and C.cname(am) ~= "WD_MainMenu_C" then
            main_seen_tick = nil
            return true
        end
        return read_main_menu(mm, force)
    end
    main_seen_tick = nil

    if read_notice(force) then
        idle_ticks = 0
        return true
    end
    -- Nothing of ours is showing (a fight, a select screen). Once that has
    -- lasted two ticks, forget what was said, so the pause menu or the next
    -- loading screen is announced again. Not on the first tick: the flow actor
    -- is swapped during a load, and for that one tick nothing can be found.
    if C.flow() then
        idle_ticks = idle_ticks + 1
        if idle_ticks >= 2 then last_screen, last_row = nil, nil end
    end
    return false
end

-- Forget what was said, so the next tick speaks the screen afresh.
function M.reset()
    last_screen, last_row = nil, nil
end

function M.init(announcer)
    ann = announcer
    return M
end

return M
