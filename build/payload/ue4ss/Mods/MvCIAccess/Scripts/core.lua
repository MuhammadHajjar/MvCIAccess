-- core.lua
-- Shared, cheap access to the game for every reader.
--
-- Two measurements shape everything in here (taken at menu level):
--   * FindAllOf(<any class>) costs about 19 ms, whatever the class and however
--     many it finds, because it walks every object in the engine. A frame is
--     16.7 ms. Readers used to call it several times per tick.
--   * A property read or a function call on an object already in hand costs
--     0.00 to 0.04 ms, and UMG's own GetAllWidgetsOfClass lists every live
--     widget of a class in about 1 ms.
-- So nothing here calls FindAllOf. The current screen is worked out from the
-- game's flow actor, its popup controller and one native widget query a tick.
--
-- One rule matters more than any other: a null object reference still arrives
-- in Lua as a non-nil userdata, and calling a method on it is a native crash
-- that pcall cannot catch. Everything that comes back from a getter, a property
-- or an out-parameter goes through valid() before anything else touches it.

local C = {}

-- Plain helpers -----------------------------------------------------------

function C.safe(fn)
    local ok, res = pcall(fn)
    if ok then return res end
    return nil
end
local safe = C.safe

function C.valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    return safe(function() return o:IsValid() end) == true
end
local valid = C.valid

-- Array elements and some out-parameters come wrapped; :get() unwraps them.
function C.unwrap(e)
    if type(e) == "userdata" then
        local inner = safe(function() return e:get() end)
        if inner ~= nil then return inner end
    end
    return e
end

function C.visible(w)
    return safe(function() return w:IsVisible() end) == true
end

function C.cname(o)
    return safe(function() return o:GetClass():GetFName():ToString() end) or "?"
end

function C.fname(o)
    return safe(function() return o:GetFullName() end) or "?"
end

-- FText / FString / string to a Lua string, or nil.
function C.tostr(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s = safe(function() return v:ToString() end)
    if type(s) == "string" then return s end
    return nil
end

function C.num(o, prop)
    local v = safe(function() return o[prop] end)
    if type(v) == "number" then return v end
    if type(v) == "userdata" then
        local n = safe(function() return v:get() end)
        if type(n) == "number" then return n end
    end
    return nil
end

-- true / false, or nil when the property is not a boolean (or does not exist).
function C.bool(o, prop)
    local v = safe(function() return o[prop] end)
    if type(v) == "boolean" then return v end
    if type(v) == "userdata" then
        local b = safe(function() return v:get() end)
        if type(b) == "boolean" then return b end
    end
    return nil
end

-- A text or string property as a Lua string ("" counts as nil).
function C.str(o, prop)
    local s = C.tostr(safe(function() return o[prop] end))
    if s == nil or s == "" then return nil end
    return s
end

-- An object property, only if it points at a live object.
function C.obj(o, prop)
    local v = safe(function() return o[prop] end)
    if valid(v) then return v end
    return nil
end

-- The text shown by a TextBlock (single line; line breaks become spaces).
function C.text(tb)
    local s = safe(function()
        local t = tb:GetText()
        if type(t) == "string" then return t end
        return t:ToString()
    end)
    if type(s) ~= "string" then return nil end
    s = s:gsub("[\r\n]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

-- TArray length, or nil if it is not an array we can measure.
function C.alen(arr)
    if arr == nil then return nil end
    local n = safe(function() return #arr end)
    if type(n) == "number" then return n end
    n = safe(function() return arr:GetArrayNum() end)
    if type(n) == "number" then return n end
    return nil
end

-- Element i (1-based) of a TArray, unwrapped. Bounds-checked: indexing a TArray
-- out of range is a native crash, so an unknown length means "do not index".
function C.aget(arr, i)
    local n = C.alen(arr)
    if type(n) ~= "number" or i < 1 or i > n then return nil end
    return C.unwrap(safe(function() return arr[i] end))
end

-- Element i (1-based) of an array PROPERTY of obj.
function C.aprop(o, prop, i)
    return C.aget(safe(function() return o[prop] end), i)
end

function C.aprop_len(o, prop)
    return C.alen(safe(function() return o[prop] end))
end

-- Call a function on an object; nil on any Lua-level failure.
function C.call(o, name, ...)
    local args = { ... }
    return safe(function() return o[name](o, table.unpack(args)) end)
end

-- Engine objects, found once ----------------------------------------------

local statics = {}

-- StaticFindObject costs about 4 ms, so each path is looked up once and kept
-- for as long as the object stays valid.
function C.static(path)
    local o = statics[path]
    if o ~= nil and valid(o) then return o end
    o = safe(function() return StaticFindObject(path) end)
    if valid(o) then
        statics[path] = o
        return o
    end
    statics[path] = nil
    return nil
end

-- One of the game's own system singletons: GameFlowSystem, PopupCtrl,
-- GameSetting, DuckSaveGame. Their class default object hands out the live
-- instance through GetInstance().
function C.system(cls)
    local cdo = C.static("/Script/Duck.Default__" .. cls)
    if not cdo then return nil end
    local inst = safe(function() return cdo:GetInstance() end)
    if valid(inst) then return inst end
    return nil
end

-- A static function library of the game, e.g. "UIFightBPLib".
function C.lib(cls)
    return C.static("/Script/Duck.Default__" .. cls)
end

-- Per-tick snapshot ---------------------------------------------------------
-- Readers ask the same questions many times in one tick; each answer is worked
-- out once and dropped when main.lua calls begin_tick().

local tick = {}
local tickn = 0

function C.begin_tick()
    tick = {}
    tickn = tickn + 1
end

-- How many ticks have run; readers use it to time "has been up for N ticks".
function C.tick_count()
    return tickn
end

-- Blueprint classes and the class paths learned by C.find belong to a level:
-- when the flow actor changes they are dropped and found again (once each,
-- about 4 ms), so a class that was unloaded is never handed to the engine.
local last_flow_name = nil
local forget_level_classes -- defined below, next to C.find

-- The flow actor of the current screen (also the world context for queries).
function C.flow()
    if tick.flow_done then return tick.flow end
    tick.flow_done = true
    local gf = C.system("GameFlowSystem")
    local f = gf and safe(function() return gf:GetFlowBP() end)
    if valid(f) then tick.flow = f end
    local name = tick.flow and C.fname(tick.flow) or nil
    if name ~= last_flow_name then
        last_flow_name = name
        forget_level_classes()
    end
    return tick.flow
end

-- Its class name, e.g. "GF_Title_C" (title + every main-menu screen),
-- "GF_FightArcade_C", "GF_FightStory_C". "" while there is no flow actor.
function C.flow_name()
    if tick.flow_name then return tick.flow_name end
    local f = C.flow()
    tick.flow_name = f and C.cname(f) or ""
    return tick.flow_name
end

function C.in_fight()
    return C.flow_name():sub(1, 8) == "GF_Fight"
end

-- Tables handed to a UFunction for its out-parameters. The UE4SS build this
-- mod ships with keeps a registry reference to every such table and never
-- releases it, so a fresh table per call would leak four times a second for the
-- whole session. One table per call site is reused instead, emptied first
-- (this build also reads the table's contents as the input value).
function C.scratch(t)
    for k in pairs(t) do t[k] = nil end
    return t
end
local found_scratch = {}

-- Every live widget of a class (by object path), valid ones only. About 1 ms.
function C.widgets(class_path)
    local ctx = C.flow()
    local wbl = C.static("/Script/UMG.Default__WidgetBlueprintLibrary")
    local cls = C.static(class_path)
    if not (ctx and wbl and cls) then return {} end
    local found = C.scratch(found_scratch)
    local ok = pcall(function() wbl:GetAllWidgetsOfClass(ctx, found, cls, false) end)
    if not ok then return {} end
    local list = found.FoundWidgets or found
    local n = C.alen(list) or #list
    local res = {}
    for i = 1, n do
        local w = C.unwrap(safe(function() return list[i] end))
        if valid(w) then res[#res + 1] = w end
    end
    return res
end

-- Widgets by SHORT class name ("WD_Title_C"), for the screens that are not
-- part of the menu family. The fast query needs the class object, and a
-- Blueprint class is only findable once it is loaded, so the first time a name
-- is asked for, every live user widget is looked through for an instance of
-- it and its class path is remembered. (Not every widget derives from the
-- game's WD_UIBase_C: the stone picker's do not.) That look costs a few
-- milliseconds, so a miss is not retried for two seconds.
local UI_BASE = "/Script/UMG.UserWidget"
local class_path, class_miss = {}, {}

forget_level_classes = function()
    for p in pairs(statics) do
        if p:sub(1, 8) ~= "/Script/" then statics[p] = nil end
    end
    class_path, class_miss = {}, {}
end

-- Every live user widget grouped by class name, built at most once a tick and
-- shared by every C.find that needs to look.
local function by_class()
    if tick.by_class then return tick.by_class end
    local map = {}
    for _, w in ipairs(C.widgets(UI_BASE)) do
        local n = C.cname(w)
        local l = map[n]
        if not l then
            l = {}
            map[n] = l
        end
        l[#l + 1] = w
    end
    tick.by_class = map
    return map
end

function C.find(short)
    local path = class_path[short]
    if path then
        if C.static(path) then return C.widgets(path) end
        class_path[short] = nil
    end
    -- a recent miss is not looked for again, unless this tick has looked anyway
    local missed = class_miss[short]
    if missed and tickn - missed < 8 and not tick.by_class then return {} end
    local res = by_class()[short] or {}
    if #res > 0 then
        class_miss[short] = nil
        local cls = safe(function() return res[1]:GetClass() end)
        local p = valid(cls) and C.fname(cls):match("^%S+ (.+)$")
        if p then class_path[short] = p end
    else
        class_miss[short] = tickn
    end
    return res
end

-- The first VISIBLE widget of a class, or nil.
function C.shown(short)
    for _, w in ipairs(C.find(short)) do
        if C.visible(w) then return w end
    end
    return nil
end

local MENU_BASE = "/Game/UI/Menu/WD_MenuBase.WD_MenuBase_C"

-- Every VISIBLE widget of the WD_MenuBase_C family, as
--   { w = widget, cls = class name, input = bool, popup = bool }.
-- All list menus, pause menus, the tutorial tip, the controls guide and the
-- small pickers derive from it.
-- since = the tick on which the widget was first seen visible this time round.
local shown_since = {}

function C.menus()
    if tick.menus then return tick.menus end
    local res, still = {}, {}
    for _, w in ipairs(C.widgets(MENU_BASE)) do
        if C.visible(w) then
            local id = C.fname(w)
            still[id] = shown_since[id] or tickn
            res[#res + 1] = {
                w = w,
                cls = C.cname(w),
                input = C.bool(w, "IsMenuBaseInput") == true,
                popup = C.bool(w, "IsPopupActive") == true,
                since = still[id],
            }
        end
    end
    shown_since = still
    tick.menus = res
    return res
end

-- Is a widget of this class on screen (visible), whatever its input state?
function C.menu_of(cls)
    for _, m in ipairs(C.menus()) do
        if m.cls == cls then return m end
    end
    return nil
end

-- Menus NEST and the ones underneath stay visible, so "visible" says nothing.
-- What does: a menu that opened something on top of itself has IsPopupActive
-- set. The screen the player is actually on is therefore the visible family
-- member that HAS input and has NO popup above it. The main menu root always
-- has both flags that way, as does the little profile-card spawner inside it,
-- so those two are never the answer on their own.
--
-- A few screens open a page on top without raising that flag (a Library entry
-- over the Library list), which leaves two candidates. The one that appeared
-- most recently is the one on top.
local NOT_A_SCREEN = { WD_MainMenu_C = true, WD_ProfCardSpawn_C = true, WD_DBSpecHeader_C = true }

function C.active_menu()
    if tick.active_done then return tick.active end
    tick.active_done = true
    local best
    for _, m in ipairs(C.menus()) do
        if m.input and not m.popup and not NOT_A_SCREEN[m.cls] then
            if not best or m.since >= best.since then best = m end
        end
    end
    tick.active = best
    return best
end

-- Is any screen of the family up besides the main menu root? True through a
-- transition too, when the menu underneath has already given up input and the
-- one opening has not taken it yet.
function C.submenu_showing()
    for _, m in ipairs(C.menus()) do
        if not NOT_A_SCREEN[m.cls] then return true end
    end
    return false
end

-- The main menu root, if it is on screen.
function C.main_menu()
    local m = C.menu_of("WD_MainMenu_C")
    return m and m.w or nil
end

local dialog_a, dialog_b = {}, {}

-- A dialog the game's popup controller is showing: its widget, or nil.
function C.dialog()
    if tick.dialog_done then return tick.dialog end
    tick.dialog_done = true
    local pc = C.system("PopupCtrl")
    if not pc then return nil end
    if safe(function() return pc:IsSpawnedDialog() end) ~= true then return nil end
    -- two out-parameters: UE4SS wants one argument each and fills the first
    local a, b = C.scratch(dialog_a), C.scratch(dialog_b)
    local ok = pcall(function() pc:GetActiveDialog(a, b) end)
    if not ok then return nil end
    local w = C.unwrap(a.OutWidget)
    if valid(w) and C.visible(w) then tick.dialog = w end
    return tick.dialog
end

-- Reading a screen's text in order ----------------------------------------

-- Walk a widget and collect the text of every visible TextBlock beneath it, in
-- layout order. Panels are walked through GetChildrenCount / GetChildAt, single
-- child wrappers through GetContent, nested user widgets through their own
-- tree. Hidden branches are skipped. Bounded, because a screen is a few
-- hundred widgets at most and this runs on a screen change, not every tick.
function C.texts(root, limit)
    local out, budget = {}, limit or 400
    local function walk(w, depth)
        if budget <= 0 or depth > 24 or not valid(w) then return end
        budget = budget - 1
        if not C.visible(w) then return end
        local cn = C.cname(w)
        if cn:find("TextBlock", 1, true) then
            local t = C.text(w)
            -- Unfilled templates show the designer's placeholder. Every label
            -- is drawn twice (text plus its shadow), so drop an immediate repeat.
            if t and not t:find("Text Block", 1, true) and out[#out] ~= t then
                out[#out + 1] = t
            end
            return
        end
        local n = safe(function() return w:GetChildrenCount() end)
        if type(n) == "number" then
            for i = 0, n - 1 do
                walk(safe(function() return w:GetChildAt(i) end), depth + 1)
            end
            return
        end
        local content = safe(function() return w:GetContent() end)
        if valid(content) then
            walk(content, depth + 1)
            return
        end
        local tree = C.obj(w, "WidgetTree")
        if tree then walk(C.obj(tree, "RootWidget"), depth + 1) end
    end
    walk(root, 0)
    return out
end

return C
