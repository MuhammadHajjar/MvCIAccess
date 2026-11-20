-- inspector.lua
-- Accessible, screen-reader-driven discovery tool (no visual UE4SS console needed).
-- Muhammad writes a one-line command into inspector_cmd.txt with NVDA, then reads
-- the answer from inspector_out.txt. Also bound to in-game hotkeys (see main.lua).
--
-- Commands (one per line in inspector_cmd.txt):
--   scan                      one-shot: VISIBLE UserWidget classes + VISIBLE text
--   snapshot | widgets        all live UserWidget classes (total + visible counts)
--   findall <ClassName>       FindAllOf(ClassName): count + up to 60 full names
--   find <substr>             live widgets whose full name contains <substr>
--   text [substr]             VISIBLE TextBlock/RichTextBlock text (optional filter)
--   textall [substr]          same, but every instance incl. hidden/template
--   probe                     1st call: baseline visible text; 2nd call: diff (move
--                             the menu cursor between the two calls to find selection)
--   class <ClassName>         FindFirstOf: its exact class + full name
--
-- Every result is written to inspector_out.txt (latest) AND appended to
-- inspector_history.txt (so running two commands never clobbers the first).
-- All engine reflection runs on the game thread. Lua errors are caught by pcall,
-- but a native access violation is NOT: bulk-reading property values, touching
-- hidden widgets and indexing an array out of bounds can each kill the game.

local M = {}

local OUT_DIR = require("paths").dir .. "\\"
local CMD_PATH = OUT_DIR .. "inspector_cmd.txt"
local OUT_PATH = OUT_DIR .. "inspector_out.txt"
local HIST_PATH = OUT_DIR .. "inspector_history.txt"

local ann = nil
local MAX_LINES = 60

local function read_file(path)
    local ok, f = pcall(io.open, path, "r")
    if not (ok and f) then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_out(lines)
    local header = "=== inspector  " .. os.date("%H:%M:%S") .. " ===\n"
    local ok, f = pcall(io.open, OUT_PATH, "w")
    if ok and f then
        f:write(header)
        for _, ln in ipairs(lines) do f:write(tostring(ln) .. "\n") end
        f:close()
    end
    -- also append to a running history so successive commands never clobber
    local ok2, h = pcall(io.open, HIST_PATH, "a")
    if ok2 and h then
        h:write(header)
        for _, ln in ipairs(lines) do h:write(tostring(ln) .. "\n") end
        h:write("\n")
        h:close()
    end
end

local function clear_cmd()
    local ok, f = pcall(io.open, CMD_PATH, "w")
    if ok and f then f:write("") ; f:close() end
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Safe reflection helpers -------------------------------------------------

-- A null object reference is a non-nil userdata, and GetClass / GetFName on
-- one is a native crash, so everything is IsValid-checked first.
local function live(obj)
    if obj == nil or type(obj) ~= "userdata" then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function class_name(obj)
    if not live(obj) then return "?" end
    local ok, res = pcall(function()
        return obj:GetClass():GetFName():ToString()
    end)
    return ok and res or "?"
end

local function full_name(obj)
    local ok, res = pcall(function() return obj:GetFullName() end)
    return ok and res or "?"
end

local function get_text(obj)
    local ok, res = pcall(function()
        local t = obj:GetText()
        if t == nil then return nil end
        if type(t) == "string" then return t end
        return t:ToString()
    end)
    if ok then return res end
    return nil
end

-- Best-effort visibility. Returns true/false, or nil if the API is unavailable
-- (caller decides how to treat unknown). Used to cut the huge hidden/template pool.
local function is_visible(obj)
    local ok, vis = pcall(function() return obj:IsVisible() end)
    if ok and vis ~= nil then return vis and true or false end
    return nil
end

-- Command implementations (run on game thread) ---------------------------

local function cmd_findall(class)
    local out = { "findall " .. class }
    local ok, arr = pcall(function() return FindAllOf(class) end)
    if not ok or arr == nil then
        out[#out + 1] = "  (none / not a valid class name)"
        return out
    end
    out[#out + 1] = "  count = " .. tostring(#arr)
    for i = 1, math.min(#arr, MAX_LINES) do
        out[#out + 1] = "  " .. full_name(arr[i])
    end
    if #arr > MAX_LINES then out[#out + 1] = "  ... (" .. (#arr - MAX_LINES) .. " more)" end
    return out
end

local function cmd_snapshot()
    local out = { "snapshot: live UserWidgets (class  xTotal / visN)" }
    local ok, arr = pcall(function() return FindAllOf("UserWidget") end)
    if not ok or arr == nil then
        out[#out + 1] = "  (no UserWidgets found)"
        return out
    end
    out[#out + 1] = "  total = " .. tostring(#arr)
    -- group by class name; track total and visible counts
    local total, vis = {}, {}
    local vis_names = {}
    for i = 1, #arr do
        local c = class_name(arr[i])
        total[c] = (total[c] or 0) + 1
        if is_visible(arr[i]) == true then
            vis[c] = (vis[c] or 0) + 1
            if #vis_names < MAX_LINES then vis_names[#vis_names + 1] = full_name(arr[i]) end
        end
    end
    local classes = {}
    for c in pairs(total) do classes[#classes + 1] = c end
    table.sort(classes)
    out[#out + 1] = "  --- classes (total / visible) ---"
    for _, c in ipairs(classes) do
        out[#out + 1] = "  " .. c .. "  x" .. total[c] .. " / vis" .. (vis[c] or 0)
    end
    out[#out + 1] = "  --- VISIBLE UserWidget full names (the active screens/panels) ---"
    if #vis_names == 0 then
        out[#out + 1] = "  (none reported visible; IsVisible may be unavailable)"
    end
    for _, fn in ipairs(vis_names) do out[#out + 1] = "  " .. fn end
    return out
end

local function cmd_find(substr)
    local needle = substr:lower()
    local out = { "find " .. substr }
    local seen = 0
    for _, cls in ipairs({ "UserWidget", "Widget" }) do
        local ok, arr = pcall(function() return FindAllOf(cls) end)
        if ok and arr then
            for i = 1, #arr do
                local fn = full_name(arr[i])
                if fn:lower():find(needle, 1, true) then
                    out[#out + 1] = "  " .. fn
                    seen = seen + 1
                    if seen >= MAX_LINES then
                        out[#out + 1] = "  ... (truncated)"
                        return out
                    end
                end
            end
        end
    end
    if seen == 0 then out[#out + 1] = "  (no match)" end
    return out
end

-- Collect readable text widgets. visible_only=true keeps only IsVisible()==true
-- (unknown-visibility widgets are dropped when filtering). Returns a list of
-- { class=..., text=..., full=... }.
local function collect_text(visible_only, needle)
    local list = {}
    for _, cls in ipairs({ "TextBlock", "RichTextBlock" }) do
        local ok, arr = pcall(function() return FindAllOf(cls) end)
        if ok and arr then
            for i = 1, #arr do
                local obj = arr[i]
                if (not visible_only) or (is_visible(obj) == true) then
                    local fn = full_name(obj)
                    if (not needle) or fn:lower():find(needle, 1, true) then
                        local txt = get_text(obj)
                        if txt and txt ~= "" then
                            list[#list + 1] = { class = class_name(obj), text = txt, full = fn }
                        end
                    end
                end
            end
        end
    end
    return list
end

local function cmd_text(substr, visible_only)
    local label = (visible_only and "text" or "textall") .. (substr and (" " .. substr) or "")
    local out = { label .. (visible_only and "  (visible only)" or "  (all incl. hidden)") }
    local needle = substr and substr:lower() or nil
    local list = collect_text(visible_only, needle)
    for i = 1, math.min(#list, MAX_LINES) do
        out[#out + 1] = "  " .. list[i].class .. " : \"" .. list[i].text .. "\""
    end
    if #list == 0 then out[#out + 1] = "  (no readable text widgets)" end
    if #list > MAX_LINES then out[#out + 1] = "  ... (" .. (#list - MAX_LINES) .. " more)" end
    return out
end

-- One-shot discovery: visible UserWidget classes + visible text, in one output.
local function cmd_scan()
    local out = { "scan: visible widgets + visible text" }
    for _, ln in ipairs(cmd_snapshot()) do out[#out + 1] = ln end
    out[#out + 1] = ""
    for _, ln in ipairs(cmd_text(nil, true)) do out[#out + 1] = ln end
    return out
end

-- Probe: find the menu selection cursor by diffing visible text between two calls.
-- 1st call captures a baseline. Move the highlight, then call again: it reports
-- text that APPEARED, DISAPPEARED, or CHANGED (that delta is usually the cursor).
local function count_keys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local probe_baseline = nil
local function cmd_probe()
    local cur = {}
    for _, e in ipairs(collect_text(true, nil)) do
        cur[e.full] = e.text
    end
    if not probe_baseline then
        probe_baseline = cur
        return { "probe: baseline captured (" .. count_keys(cur) ..
            " visible texts). Move the menu cursor, then run probe again." }
    end
    local out = { "probe: diff vs baseline" }
    local changed = 0
    for full, txt in pairs(cur) do
        local old = probe_baseline[full]
        if old == nil then
            out[#out + 1] = "  APPEARED  " .. full .. " : \"" .. txt .. "\""
            changed = changed + 1
        elseif old ~= txt then
            out[#out + 1] = "  CHANGED   " .. full .. " : \"" .. old .. "\" -> \"" .. txt .. "\""
            changed = changed + 1
        end
    end
    for full, txt in pairs(probe_baseline) do
        if cur[full] == nil then
            out[#out + 1] = "  DISAPPEARED " .. full .. " : \"" .. txt .. "\""
            changed = changed + 1
        end
    end
    if changed == 0 then
        out[#out + 1] = "  (no visible-text change. The cursor may be a separate widget"
        out[#out + 1] = "   or a color/state change, not text. That needs a separate probe mode.)"
    end
    probe_baseline = nil -- reset for the next pair
    return out
end

-- Dump every widget whose full path contains <substr> (any class): visibility,
-- class, the path tail after the needle, and text if any. Reveals a screen's
-- whole widget subtree by name (e.g. tree WD_MainMenu).
local function cmd_tree(substr, cap)
    cap = cap or 200
    local needle = substr:lower()
    local out = { "tree " .. substr }
    local seen, rows = {}, {}
    for _, cls in ipairs({ "Widget", "UserWidget" }) do
        local ok, arr = pcall(function() return FindAllOf(cls) end)
        if ok and arr then
            for i = 1, #arr do
                local obj = arr[i]
                local fn = full_name(obj)
                local pos = fn:lower():find(needle, 1, true)
                if pos and not seen[fn] then
                    seen[fn] = true
                    local vis = is_visible(obj)
                    local vtag = (vis == true) and "vis" or ((vis == false) and "hid" or "?")
                    rows[#rows + 1] = {
                        fn = fn,
                        tail = fn:sub(pos + #substr),
                        class = class_name(obj),
                        vtag = vtag,
                        txt = get_text(obj),
                    }
                end
            end
        end
    end
    table.sort(rows, function(a, b) return a.fn < b.fn end)
    out[#out + 1] = "  count = " .. #rows
    for i = 1, math.min(#rows, cap) do
        local r = rows[i]
        local line = "  [" .. r.vtag .. "] " .. r.class .. " " .. r.tail
        if r.txt and r.txt ~= "" then line = line .. " : \"" .. r.txt .. "\"" end
        out[#out + 1] = line
    end
    if #rows > cap then out[#out + 1] = "  ... (" .. (#rows - cap) .. " more)" end
    return out
end

-- Try to set/read the UE4 localization culture from Lua via the Kismet
-- internationalization library (may not exist on UE4.15 -> reported as not found).
local function get_i18n_lib()
    local ok, lib = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
    end)
    if ok and lib and lib:IsValid() then return lib end
    return nil
end

local function cmd_getculture()
    local out = { "getculture" }
    local lib = get_i18n_lib()
    if not lib then
        out[#out + 1] = "  KismetInternationalizationLibrary: NOT FOUND (expected on UE4.15)"
        return out
    end
    local ok, cur = pcall(function() return lib:GetCurrentCulture() end)
    out[#out + 1] = ok and ("  current culture = " .. tostring(cur)) or ("  GetCurrentCulture error: " .. tostring(cur))
    return out
end

local function cmd_setculture(code)
    code = (code and code ~= "") and code or "en"
    local out = { "setculture " .. code }
    local lib = get_i18n_lib()
    if not lib then
        out[#out + 1] = "  KismetInternationalizationLibrary: NOT FOUND (expected on UE4.15)."
        out[#out + 1] = "  Cannot switch language from Lua this way; use the in-game Language option."
        return out
    end
    out[#out + 1] = "  library: found"
    local okb, before = pcall(function() return lib:GetCurrentCulture() end)
    if okb then out[#out + 1] = "  before = " .. tostring(before) end
    local oks, ret = pcall(function() return lib:SetCurrentCulture(code, true) end)
    out[#out + 1] = "  SetCurrentCulture('" .. code .. "', true) -> " ..
        (oks and ("ok, returned " .. tostring(ret)) or ("ERROR: " .. tostring(ret)))
    local oka, after = pcall(function() return lib:GetCurrentCulture() end)
    if oka then out[#out + 1] = "  after = " .. tostring(after) end
    out[#out + 1] = "  (If it did not change, the game re-forces its own language in native code.)"
    return out
end

-- Dump the properties (and their current values) of the first object whose full
-- name contains <substr>. Used to find the menu's selected-index variable.
-- Enumerates via UClass:ForEachProperty when available, and also probes a list of
-- likely index-property names directly (works even if enumeration is unavailable).
local INDEX_CANDIDATES = {
    "CursorPos", "CursorIndex", "Cursor", "CurrentIndex", "CurrentPos", "Index",
    "SelectIndex", "SelectedIndex", "Select", "Selected", "SelectNo", "SelectNum",
    "nowSelect", "NowIndex", "Position", "Pos", "MenuIndex", "ItemIndex",
    "FocusIndex", "CurrentItem", "CurrentNo", "No", "Number",
}

local function prop_name(prop)
    local n
    local ok = pcall(function() n = prop:GetFName():ToString() end)
    if ok and n then return n end
    ok = pcall(function() n = prop:GetName() end)
    if ok and n then return n end
    return nil
end

-- Read a property and return a plain-scalar string, or nil if it is not a
-- resolvable scalar (missing, an object, or a function wrapper). Handles UE4SS
-- returning a userdata wrapper by trying :get().
local function resolve(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return nil end
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then
        return tostring(v)
    elseif t == "userdata" then
        local ok2, vv = pcall(function() return v:get() end)
        if ok2 and vv ~= nil then
            local tt = type(vv)
            if tt == "number" or tt == "boolean" or tt == "string" then return tostring(vv) end
        end
        return nil
    end
    return nil
end

local function read_scalar(obj, name)
    local s = resolve(obj, name)
    return s, (s ~= nil)
end

-- Find an object by token. Treat it as a CLASS first (so "WD_MainMenu_C" returns
-- an actual instance, not a child that merely contains the string); when several
-- instances exist, prefer a VISIBLE one (the active submenu). Then fall back to
-- full-name ends-with, then contains.
local function find_by_substr(token)
    local oka, arr = pcall(function() return FindAllOf(token) end)
    if oka and arr and #arr > 0 then
        for i = 1, #arr do
            if is_visible(arr[i]) == true then return arr[i] end
        end
        return arr[1]
    end
    local ok0, byclass = pcall(function() return FindFirstOf(token) end)
    if ok0 and byclass and byclass:IsValid() then return byclass end
    local needle = token:lower()
    local contains = nil
    for _, cls in ipairs({ "Widget", "UserWidget", "Object" }) do
        local ok, arr = pcall(function() return FindAllOf(cls) end)
        if ok and arr then
            for i = 1, #arr do
                local fn = full_name(arr[i]):lower()
                if fn:sub(-#needle) == needle then return arr[i] end
                if not contains and fn:find(needle, 1, true) then contains = arr[i] end
            end
        end
    end
    return contains
end

local function cmd_props(substr)
    local out = { "props " .. substr }
    local target = find_by_substr(substr)
    if not target then
        out[#out + 1] = "  (no object matches)"
        return out
    end
    out[#out + 1] = "  target = " .. full_name(target)
    local cls
    pcall(function() cls = target:GetClass() end)

    -- 1) full enumeration if the API is available
    local listed = 0
    if cls then
        pcall(function()
            cls:ForEachProperty(function(prop)
                local pname = prop_name(prop)
                if pname then
                    local val = resolve(target, pname)
                    out[#out + 1] = "  " .. pname .. " = " .. (val or "<non-scalar>")
                    listed = listed + 1
                end
            end)
        end)
    end
    if listed == 0 then
        out[#out + 1] = "  (ForEachProperty unavailable; probing candidate names)"
    end

    -- 2) always probe likely index names directly (robust fallback + highlight)
    out[#out + 1] = "  --- likely index candidates (name = value) ---"
    local hits = 0
    for _, name in ipairs(INDEX_CANDIDATES) do
        local val, existed = read_scalar(target, name)
        if existed and val ~= nil then
            out[#out + 1] = "  * " .. name .. " = " .. val
            hits = hits + 1
        end
    end
    if hits == 0 then out[#out + 1] = "  (none of the candidate names resolved)" end
    return out
end

-- Find the selection index by diffing scalar properties across a cursor move.
-- 1st call: baseline of candidate scalars on WD_MainMenu_C + each WD_MainMenuItem_C.
-- Move the highlight, then call again: reports every scalar that changed. The one
-- that changed IS the selection index (or a per-item selected flag).
local ITEM_CANDIDATES = {
    "Selected", "bSelected", "IsSelected", "Select", "Focus", "bFocus", "Active",
    "bActive", "Index", "No", "Highlight", "bHighlight", "State",
}

local function collect_idx()
    local map = {}
    local root = find_by_substr("WD_MainMenu_C")
    if root then
        for _, name in ipairs(INDEX_CANDIDATES) do
            local v = resolve(root, name)
            if v ~= nil then map["root." .. name] = v end
        end
    end
    local ok, items = pcall(function() return FindAllOf("WD_MainMenuItem_C") end)
    if ok and items then
        for i = 1, #items do
            for _, name in ipairs(ITEM_CANDIDATES) do
                local v = resolve(items[i], name)
                if v ~= nil then map["item" .. (i - 1) .. "." .. name] = v end
            end
        end
    end
    return map
end

-- Walk up a class's parents. Stops at the engine base widget classes.
local STOP_CLASSES = {
    UserWidget = true, Widget = true, Object = true, Visual = true,
    -- stop before engine base classes for actors too, so dumps stay focused on
    -- the Blueprint's own variables
    Actor = true, Pawn = true, Info = true, GameModeBase = true, GameStateBase = true,
}
local function class_super(cls)
    if not live(cls) then return nil end
    local s
    local ok = pcall(function() s = cls:GetSuperStruct() end)
    if ok and live(s) then return s end
    ok = pcall(function() s = cls:GetSuperClass() end)
    if ok and live(s) then return s end
    return nil
end

-- Full property enumeration of one object, walking the WHOLE class chain (so
-- inherited properties like a focus flag on a base class are not missed).
local function enumerate_all(obj)
    local lines = {}
    if not obj then return { "  (object not found)" } end
    lines[#lines + 1] = "  enumerate " .. full_name(obj)
    local cls
    pcall(function() cls = obj:GetClass() end)
    if not cls then
        lines[#lines + 1] = "    (no class)"
        return lines
    end
    local seen = {}
    local n, guard = 0, 0
    while cls and guard < 12 do
        guard = guard + 1
        local cn = "?"
        pcall(function() cn = cls:GetFName():ToString() end)
        if STOP_CLASSES[cn] then break end
        pcall(function()
            cls:ForEachProperty(function(prop)
                local nm
                pcall(function() nm = prop:GetFName():ToString() end)
                if not nm then pcall(function() nm = prop:GetName() end) end
                if nm and not seen[nm] then
                    seen[nm] = true
                    local v = resolve(obj, nm)
                    lines[#lines + 1] = "    [" .. cn .. "] " .. nm .. " = " .. (v or "<non-scalar>")
                    n = n + 1
                end
            end)
        end)
        cls = class_super(cls)
    end
    if n == 0 then
        lines[#lines + 1] = "    (no properties enumerated)"
    end
    return lines
end

local probeidx_baseline = nil
local function cmd_probeidx()
    local cur = collect_idx()
    if not probeidx_baseline then
        probeidx_baseline = cur
        local out = { "probeidx: baseline captured (" .. count_keys(cur) ..
            " candidate scalars). Move the menu cursor, then run probeidx again." }
        out[#out + 1] = "--- full property enumeration (WD_MainMenu_C_0) ---"
        for _, ln in ipairs(enumerate_all(find_by_substr("WD_MainMenu_C"))) do out[#out + 1] = ln end
        out[#out + 1] = "--- full property enumeration (WD_MainMenuItem_C_0) ---"
        for _, ln in ipairs(enumerate_all(find_by_substr("WD_MainMenuItem_C"))) do out[#out + 1] = ln end
        return out
    end
    local out = { "probeidx: diff vs baseline (a CHANGED value = the selection index)" }
    local changed = 0
    for k, v in pairs(cur) do
        local old = probeidx_baseline[k]
        if old ~= nil and old ~= v then
            out[#out + 1] = "  CHANGED  " .. k .. " : " .. old .. " -> " .. v
            changed = changed + 1
        elseif old == nil then
            out[#out + 1] = "  NEW      " .. k .. " = " .. v
            changed = changed + 1
        end
    end
    if changed == 0 then
        out[#out + 1] = "  (no scalar changed. The index name is not in the candidate list;"
        out[#out + 1] = "   the properties need enumerating a different way.)"
    end
    out[#out + 1] = "  --- baseline had " .. count_keys(probeidx_baseline) .. " props, now " .. count_keys(cur) .. " ---"
    probeidx_baseline = nil
    return out
end

-- GENERIC selection-index finder for ANY screen. Enumerates every scalar property
-- of every visible UserWidget, then diffs across a cursor move. The value that
-- changed is that screen's selection index (and names the widget that holds it).
local probeany_baseline = nil
local function collect_all_scalars(cap)
    cap = cap or 150
    local map = {}
    local ok, arr = pcall(function() return FindAllOf("UserWidget") end)
    if not ok or not arr then return map, 0 end
    local n = 0
    for i = 1, #arr do
        local w = arr[i]
        if is_visible(w) == true then
            n = n + 1
            if n > cap then break end
            local cls
            pcall(function() cls = w:GetClass() end)
            local fn = full_name(w)
            if cls then
                pcall(function()
                    cls:ForEachProperty(function(prop)
                        local nm = prop_name(prop)
                        if nm then
                            local v = resolve(w, nm)
                            if v ~= nil then map[fn .. "::" .. nm] = v end
                        end
                    end)
                end)
            end
        end
    end
    return map, n
end

local function cmd_probeany()
    local cur, nwid = collect_all_scalars()
    if not probeany_baseline then
        probeany_baseline = cur
        return { "probeany: baseline of " .. count_keys(cur) .. " scalars across " .. nwid ..
            " visible widgets. Move the cursor one step, then run probeany again." }
    end
    local out = { "probeany: diff (a CHANGED number = THIS screen's selection index)" }
    local changed = 0
    for k, v in pairs(cur) do
        local old = probeany_baseline[k]
        if old ~= nil and old ~= v then
            out[#out + 1] = "  CHANGED  " .. k .. " : " .. old .. " -> " .. v
            changed = changed + 1
        end
    end
    if changed == 0 then
        out[#out + 1] = "  (nothing changed - move the cursor further between the two presses,"
        out[#out + 1] = "   or the index is on a non-UserWidget; the scan needs widening)"
    end
    probeany_baseline = nil
    return out
end

-- Dump every visible option-item widget with its scalar properties AND its label
-- text. Reveals the per-item focus flag + how the label/value are stored, so we
-- can read the focused row generically (Settings, submenus, etc.).
local OPT_CLASSES = {
    "WD_OptionItem_PressBtn_C", "WD_OptionItem_SpinText_C", "WD_OptionItem_Slider_C",
}
local function starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end
-- GetFullName() returns "ClassName /Path"; return just the /Path part for matching.
local function path_of(fn)
    return fn:match("%s(.+)$") or fn
end
local function bool_method(w, name)
    local ok, v = pcall(function() return w[name](w) end)
    if ok and type(v) == "boolean" then return v end
    return nil
end
local function cmd_optscan()
    local out = { "optscan: visible option items (label + focus + props)" }
    -- Precompute all TextBlocks once for label lookup by path prefix.
    local tbs = {}
    local ok, arr = pcall(function() return FindAllOf("TextBlock") end)
    if ok and arr then tbs = arr end
    local shown = 0
    for _, cls in ipairs(OPT_CLASSES) do
        local ok2, items = pcall(function() return FindAllOf(cls) end)
        if ok2 and items then
            for i = 1, #items do
                local w = items[i]
                if is_visible(w) == true and shown < 40 then
                    shown = shown + 1
                    local fn = full_name(w)
                    local ipath = path_of(fn)
                    local tail = fn:match("([^.:]+)$") or fn
                    -- all text under this item (label, and value for spin rows)
                    local texts = {}
                    for k = 1, #tbs do
                        if starts_with(path_of(full_name(tbs[k])), ipath) then
                            local t = get_text(tbs[k])
                            if t and t ~= "" then texts[#texts + 1] = t end
                        end
                    end
                    -- focus signals
                    local kf = bool_method(w, "HasKeyboardFocus")
                    local uf = bool_method(w, "HasAnyUserFocus")
                    -- scalar props
                    local parts = {}
                    local c
                    pcall(function() c = w:GetClass() end)
                    if c then
                        pcall(function()
                            c:ForEachProperty(function(prop)
                                local nm = prop_name(prop)
                                if nm then
                                    local v = resolve(w, nm)
                                    if v ~= nil then parts[#parts + 1] = nm .. "=" .. v end
                                end
                            end)
                        end)
                    end
                    out[#out + 1] = "  [" .. cls .. "] " .. tail ..
                        "  text=[" .. table.concat(texts, " | ") .. "]" ..
                        "  kbFocus=" .. tostring(kf) .. " userFocus=" .. tostring(uf) ..
                        "  {" .. table.concat(parts, ", ") .. "}"
                end
            end
        end
    end
    if shown == 0 then out[#out + 1] = "  (no visible option items)" end
    -- Broad sweep: ANY visible UserWidget currently reporting Slate focus.
    out[#out + 1] = "  --- visible widgets reporting focus ---"
    local fcount = 0
    local okf, uw = pcall(function() return FindAllOf("UserWidget") end)
    if okf and uw then
        local seen = 0
        for i = 1, #uw do
            local w = uw[i]
            if is_visible(w) == true then
                seen = seen + 1
                if seen > 200 then break end
                local kf = bool_method(w, "HasKeyboardFocus")
                local uf = bool_method(w, "HasAnyUserFocus")
                if kf == true or uf == true then
                    local fn = full_name(w)
                    out[#out + 1] = "   FOCUS " .. (fn:match("([^.:]+)$") or fn) ..
                        "  kb=" .. tostring(kf) .. " user=" .. tostring(uf)
                    fcount = fcount + 1
                end
            end
        end
    end
    if fcount == 0 then out[#out + 1] = "   (no widget reports Slate focus)" end
    return out
end

-- Collect every FULL-CHAIN scalar property of an object into map[prefix::name]=val.
local function collect_chain_scalars(obj, map, prefix)
    local cls
    pcall(function() cls = obj:GetClass() end)
    local seen = {}
    local guard = 0
    while cls and guard < 12 do
        guard = guard + 1
        local cn = "?"
        pcall(function() cn = cls:GetFName():ToString() end)
        if STOP_CLASSES[cn] then break end
        pcall(function()
            cls:ForEachProperty(function(prop)
                local nm
                pcall(function() nm = prop:GetFName():ToString() end)
                if nm and not seen[nm] then
                    seen[nm] = true
                    local v = resolve(obj, nm)
                    if v ~= nil then map[prefix .. "::" .. nm] = v end
                end
            end)
        end)
        cls = class_super(cls)
    end
end

local function all_option_items()
    local arr = nil
    local ok, a = pcall(function() return FindAllOf("WD_OptionItemBase_C") end)
    if ok and a and #a > 0 then arr = a end
    if not arr then
        arr = {}
        for _, cls in ipairs({ "WD_OptionItem_PressBtn_C", "WD_OptionItem_SpinText_C", "WD_OptionItem_Slider_C" }) do
            local ok2, b = pcall(function() return FindAllOf(cls) end)
            if ok2 and b then for i = 1, #b do arr[#arr + 1] = b[i] end end
        end
    end
    return arr
end

-- Baseline/diff of ALL full-chain scalars of every visible option item. Run it,
-- move the cursor one step, run again: whatever CHANGED is the selection signal.
local optdiff_baseline = nil
local function cmd_optdiff()
    local map, nitems = {}, 0
    local arr = all_option_items()
    for i = 1, #arr do
        local w = arr[i]
        if is_visible(w) == true then
            nitems = nitems + 1
            -- key by full path (unique per instance) so items never collide
            local key = path_of(full_name(w))
            collect_chain_scalars(w, map, key)
            local name = resolve(w, "ItemName")
            if name then map[key .. "::__name"] = name end
        end
    end
    if not optdiff_baseline then
        optdiff_baseline = map
        return { "optdiff: baseline " .. count_keys(map) .. " scalars over " .. nitems ..
            " visible option items. Move the cursor one step, then run optdiff again." }
    end
    local out = { "optdiff: diff (CHANGED = the option selection signal)" }
    local changed = 0
    for k, v in pairs(map) do
        local o = optdiff_baseline[k]
        if o ~= nil and o ~= v then
            out[#out + 1] = "  CHANGED " .. k .. " : " .. o .. " -> " .. v
            changed = changed + 1
        end
    end
    if changed == 0 then
        out[#out + 1] = "  (nothing on the option items changed - selection is not reflected"
        out[#out + 1] = "   on them; read the cursor geometry instead)"
    end
    optdiff_baseline = nil
    return out
end

-- DEEP probe: full class-chain scalars of EVERY UserWidget (visible AND hidden),
-- diffed across a move. Finds a cursor/selection index anywhere - used for screens
-- (like character select) where nothing visible reflects the cursor.
local probeall_baseline = nil
local function cmd_probeall()
    local map, n = {}, 0
    local ok, arr = pcall(function() return FindAllOf("UserWidget") end)
    if ok and arr then
        for i = 1, #arr do
            n = n + 1
            if n > 300 then break end
            collect_chain_scalars(arr[i], map, path_of(full_name(arr[i])))
        end
    end
    if not probeall_baseline then
        probeall_baseline = map
        return { "probeall: baseline " .. count_keys(map) .. " scalars over " .. n ..
            " widgets (visible+hidden). Move the cursor one step, then run probeall again." }
    end
    local out = { "probeall: diff (a CHANGED value = the cursor/selection signal)" }
    local changed = 0
    for k, v in pairs(map) do
        local o = probeall_baseline[k]
        if o ~= nil and o ~= v then
            out[#out + 1] = "  CHANGED " .. k .. " : " .. o .. " -> " .. v
            changed = changed + 1
            if changed > 60 then break end
        end
    end
    if changed == 0 then out[#out + 1] = "  (nothing changed among any widget scalars)" end
    probeall_baseline = nil
    return out
end

-- SAFE targeted probe for character select: only the real select-screen widget
-- classes (not arbitrary hidden widgets, which crash). Diff across a cursor move.
local CHAR_CLASSES = {
    "WD_SelectTeamList_C", "WD_MemberListSmall_C", "WD_ListItem00_C", "WD_ListItem01_C",
    "WD_GemDetail_C", "WD_SelectTitle_C", "WD_BtnNavi_Slct_C",
}
local charprobe_baseline = nil
local function cmd_charprobe()
    local map, n = {}, 0
    for _, cls in ipairs(CHAR_CLASSES) do
        local ok, arr = pcall(function() return FindAllOf(cls) end)
        if ok and arr then
            for i = 1, #arr do
                local w = arr[i]
                if (pcall(function() return w:IsValid() end)) and w:IsValid() then
                    n = n + 1
                    collect_chain_scalars(w, map, path_of(full_name(w)))
                end
            end
        end
    end
    if not charprobe_baseline then
        charprobe_baseline = map
        return { "charprobe: baseline " .. count_keys(map) .. " scalars over " .. n ..
            " select widgets. Move the cursor one step, then run charprobe again." }
    end
    local out = { "charprobe: diff (a CHANGED value = the character cursor)" }
    local changed = 0
    for k, v in pairs(map) do
        local o = charprobe_baseline[k]
        if o ~= nil and o ~= v then
            out[#out + 1] = "  CHANGED " .. k .. " : " .. o .. " -> " .. v
            changed = changed + 1
        end
    end
    if changed == 0 then out[#out + 1] = "  (nothing changed on the select widgets)" end
    charprobe_baseline = nil
    return out
end

-- SAFE full-chain probe of only VISIBLE widgets (hidden ones crash). Full class
-- chain so inherited fields (e.g. WD_MenuBase.ItemIndex) are caught. The baseline
-- is stored in a FILE so it survives a mod reload OR a game relaunch between the
-- two presses (a module var would be wiped). Diff a cursor move.
local PROBEVIS_FILE = require("paths").file("probevis_base.txt")
local function cmd_probevis()
    local map, n = {}, 0
    local ok, arr = pcall(function() return FindAllOf("UserWidget") end)
    if ok and arr then
        for i = 1, #arr do
            local w = arr[i]
            if is_visible(w) == true then
                n = n + 1
                if n > 130 then break end
                collect_chain_scalars(w, map, path_of(full_name(w)))
            end
        end
    end
    -- load a previously-saved baseline, if any
    local base = nil
    local rf = io.open(PROBEVIS_FILE, "r")
    if rf then
        local content = rf:read("*a"); rf:close()
        if content and #content > 0 then
            base = {}
            for line in content:gmatch("[^\n]+") do
                local k, v = line:match("^(.-)\t(.*)$")
                if k then base[k] = v end
            end
        end
    end
    if not base then
        local wf = io.open(PROBEVIS_FILE, "w")
        if wf then
            for k, v in pairs(map) do wf:write(k .. "\t" .. tostring(v) .. "\n") end
            wf:close()
        end
        return { "probevis: baseline saved (" .. count_keys(map) .. " scalars over " .. n ..
            " visible widgets). Move the cursor one step, then run probevis again." }
    end
    local out = { "probevis: diff (a CHANGED value = the cursor/focus)" }
    local changed = 0
    for k, v in pairs(map) do
        local o = base[k]
        if o ~= nil and o ~= v then
            out[#out + 1] = "  CHANGED " .. k .. " : " .. o .. " -> " .. v
            changed = changed + 1
            if changed > 60 then break end
        end
    end
    if changed == 0 then out[#out + 1] = "  (nothing changed among visible widgets)" end
    local cf = io.open(PROBEVIS_FILE, "w"); if cf then cf:write(""); cf:close() end -- reset for next pair
    return out
end

-- pcall that returns the value on success, nil on failure (never the error text).
local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- Read an FText/-ish property to a string.
local function ftext_prop(obj, name)
    local v = try(function() return obj[name] end)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local s = try(function() return v:ToString() end)
    if type(s) == "string" then return s end
    return nil
end

-- Format an X/Y struct value (e.g. FVector2D) to a string, best effort.
local function xy_str(v)
    if v == nil then return nil end
    local x = try(function() return v.X end)
    local y = try(function() return v.Y end)
    if type(x) == "number" or type(y) == "number" then
        return "(" .. tostring(x) .. ", " .. tostring(y) .. ")"
    end
    return nil
end
local function read_xy(obj, name)
    return xy_str(try(function() return obj[name] end))
end

-- A widget's Canvas-slot position, best effort.
local function slot_xy(w)
    local slot = try(function() return w.Slot end)
    if not slot then return nil end
    return xy_str(try(function() return slot:GetPosition() end))
end

-- The submenu container classes that actually hold an option list.
local LIST_CONTAINER_CLASSES = {
    "WD_MenuOption_C", "WD_MMVersus_C", "WD_MMStory_C", "WD_MMRanking_C",
    "WD_OnlineMenu_C", "WD_OnlineSetting_C", "WD_SystemSetting_C", "WD_DisplaySetting_C",
    "WD_SoundOption_C", "WD_Language_C",
}

-- Dump the active option list: the container's cursor offset + its option panel's
-- children in order (with labels). Run before/after a move to see the cursor
-- offset change and confirm the child order is stable -> offset maps to a row.
local function cmd_listdump()
    local out = { "listdump: active option list (cursor offset + ordered children)" }
    for _, cls in ipairs(LIST_CONTAINER_CLASSES) do
        local arr = select(2, pcall(function() return FindAllOf(cls) end)) or {}
        for i = 1, #arr do
            local c = arr[i]
            if is_visible(c) == true then
                out[#out + 1] = "== " .. cls .. " ==  CursorOffsetPos=" ..
                    (read_xy(c, "CursorOffsetPos") or "?")
                -- find its option panel and walk children in order
                local panel = select(2, pcall(function() return c.CanvasPanel_Option end))
                local cnt = panel and select(2, pcall(function() return panel:GetChildrenCount() end)) or nil
                if type(cnt) == "number" then
                    out[#out + 1] = "  panel children = " .. cnt
                    for j = 0, math.min(cnt - 1, 30) do
                        local ch = select(2, pcall(function() return panel:GetChildAt(j) end))
                        local nm = ch and ftext_prop(ch, "ItemName") or nil
                        local st = ch and select(2, pcall(function() return ch.ItemState end)) or nil
                        out[#out + 1] = "   [" .. j .. "] " ..
                            (ch and class_name(ch) or "?") ..
                            "  name=" .. (nm and ("\"" .. nm .. "\"") or "?") ..
                            "  ItemState=" .. tostring(st)
                    end
                else
                    out[#out + 1] = "  (CanvasPanel_Option not readable / GetChildrenCount failed)"
                end
                break -- only the first visible instance of this class
            end
        end
    end
    if #out == 1 then out[#out + 1] = "  (no visible list container found)" end
    return out
end

-- Dump whichever config sub-screen is currently visible (keyboard/controller
-- config, HUD position, or the list sub-settings): its class-chain props, its
-- widget subtree, and the visible on-screen text. One key covers any of them.
local SCREEN_DUMP_CLASSES = {
    "WD_KeyboardConfMain_C", "WD_KeyboardConfBind_C", "WD_KeyConfMain_C",
    "WD_CtrlSelectMain_C", "WD_HudPosition_C", "WD_SystemSetting_C",
    "WD_DisplaySetting_C", "WD_SoundOption_C",
}
local function cmd_screendump()
    local out = { "screendump: visible config sub-screen(s)" }
    local found = false
    for _, cls in ipairs(SCREEN_DUMP_CLASSES) do
        local w = find_by_substr(cls)
        if w and is_visible(w) == true then
            found = true
            out[#out + 1] = "== " .. cls .. " (props) =="
            for _, ln in ipairs(enumerate_all(w)) do out[#out + 1] = ln end
            out[#out + 1] = "== " .. cls .. " (subtree) =="
            for _, ln in ipairs(cmd_tree((cls:gsub("_C$", "")), 120)) do out[#out + 1] = ln end
        end
    end
    if not found then out[#out + 1] = "  (no known config sub-screen visible)" end
    out[#out + 1] = "== visible text =="
    for _, ln in ipairs(cmd_text(nil, true)) do out[#out + 1] = ln end
    return out
end

-- Check whether WD_MainMenu_C.ActiveMenu tracks the CURRENT screen, and dump that
-- container's class chain (to find the shared base class of all list containers).
-- Run it on several screens (Settings, a submenu, Language) to compare.
local function cmd_autocheck()
    local out = { "autocheck" }
    local mm = try(function() return FindFirstOf("WD_MainMenu_C") end)
    if not mm then
        out[#out + 1] = "  WD_MainMenu_C not found"
        return out
    end
    local am = try(function() return mm.ActiveMenu end)
    if not am then
        out[#out + 1] = "  ActiveMenu = nil"
        return out
    end
    out[#out + 1] = "  ActiveMenu class = " .. class_name(am)
    out[#out + 1] = "  ActiveMenu full  = " .. full_name(am)
    out[#out + 1] = "  has CanvasPanel_Option  = " .. tostring(try(function() return am.CanvasPanel_Option end) ~= nil)
    out[#out + 1] = "  has WD_OptionListCursor = " .. tostring(try(function() return am.WD_OptionListCursor end) ~= nil)
    out[#out + 1] = "  == class chain of ActiveMenu =="
    for _, ln in ipairs(enumerate_all(am)) do out[#out + 1] = ln end
    return out
end

-- Thorough dump of the Language picker (WD_Language_C): its full property list
-- (to find its cursor/index field) plus its whole widget subtree (to find the
-- language option widgets and their labels).
local function cmd_langdump()
    local out = { "langdump" }
    local w = find_by_substr("WD_Language_C")
    if not w then
        out[#out + 1] = "  (WD_Language_C not found)"
        return out
    end
    out[#out + 1] = "== properties (class chain) =="
    for _, ln in ipairs(enumerate_all(w)) do out[#out + 1] = ln end
    out[#out + 1] = "== subtree (WD_Language) =="
    for _, ln in ipairs(cmd_tree("WD_Language", 120)) do out[#out + 1] = ln end
    out[#out + 1] = "== visible widgets + text (whole screen) =="
    for _, ln in ipairs(cmd_scan()) do out[#out + 1] = ln end
    return out
end

-- Dump ONE widget: its class-chain properties plus every child widget under its
-- path (class, name, visibility, text). Name/text reads only for the children, so
-- it is as safe as `scan`.
local function dump_widget(w, label, out, cap)
    cap = cap or 45
    if not w then
        out[#out + 1] = "  (" .. label .. " not found)"
        return
    end
    out[#out + 1] = "-- " .. label .. " = " .. full_name(w)
    for _, ln in ipairs(enumerate_all(w)) do out[#out + 1] = ln end
    local ipath = path_of(full_name(w))
    local n = 0
    local ok, arr = pcall(function() return FindAllOf("Widget") end)
    if ok and arr then
        for i = 1, #arr do
            local ch = arr[i]
            local fn = full_name(ch)
            local p = path_of(fn)
            if p ~= ipath and starts_with(p, ipath) then
                local t = get_text(ch)
                out[#out + 1] = "   [" .. ((is_visible(ch) == true) and "vis" or "hid") .. "] " ..
                    class_name(ch) .. " " .. (fn:match("([^.]+)$") or fn) ..
                    ((t and t ~= "") and ("  text=\"" .. t .. "\"") or "")
                n = n + 1
                if n >= cap then
                    out[#out + 1] = "   ... (truncated)"
                    break
                end
            end
        end
    end
end

-- Command list (move list): the screen's cursor field + the structure of the
-- first visible move row, so we can read move name AND its input notation.
local function cmd_cmdlistdump()
    local out = { "cmdlistdump" }
    out[#out + 1] = "== WD_CommandList_C =="
    dump_widget(find_by_substr("WD_CommandList_C"), "WD_CommandList_C", out, 60)
    out[#out + 1] = ""
    out[#out + 1] = "== one move row (WD_CmdListButton_C) =="
    dump_widget(find_by_substr("WD_CmdListButton_C"), "WD_CmdListButton_C", out, 45)
    out[#out + 1] = ""
    out[#out + 1] = "== one category (WD_CmdListCategory_C) =="
    dump_widget(find_by_substr("WD_CmdListCategory_C"), "WD_CmdListCategory_C", out, 20)
    return out
end

-- Select screens (character select / stage select). Dumps the visible select
-- widgets, and lists distinct ACTOR class names - the character roster is not
-- UMG, so if a cursor exists it likely lives on an actor (a manager/GameMode).
-- Name/class reads only for the actor list, so it is safe.
local function cmd_selectdump()
    local out = { "selectdump" }
    for _, cls in ipairs({ "WD_SelectTitle_C", "WD_StageName_C", "WD_SelectTeamList_C",
                           "WD_MemberListSmall_C", "WD_GemDetail_C", "WD_BtnNavi_Slct_C" }) do
        local w = find_by_substr(cls)
        if w and is_visible(w) == true then
            out[#out + 1] = "== " .. cls .. " (VISIBLE) =="
            dump_widget(w, cls, out, 25)
            out[#out + 1] = ""
        end
    end
    -- distinct actor classes (names only)
    out[#out + 1] = "== actor classes present =="
    local counts, order = {}, {}
    local ok, arr = pcall(function() return FindAllOf("Actor") end)
    if ok and arr then
        out[#out + 1] = "  actor count = " .. #arr
        for i = 1, #arr do
            local c = class_name(arr[i])
            if counts[c] == nil then
                counts[c] = 0
                order[#order + 1] = c
            end
            counts[c] = counts[c] + 1
        end
        table.sort(order)
        for _, c in ipairs(order) do
            out[#out + 1] = "  " .. c .. "  x" .. counts[c]
        end
    else
        out[#out + 1] = "  (FindAllOf Actor failed)"
    end
    return out
end

-- The character/stage select screens are built from ACTORS, not widgets.
-- Dump the properties of the key select actors (cursor, cells, managers) to find
-- the cursor index and the per-cell character/stage identity.
local SELECT_ACTORS = {
    "BP_Select_Cursor_C", "BP_Select_Child_C", "BP_Select_Parent_C",
    "CharaSelect_C", "GS_CharaSelect_C", "BP_CharaSelectSingle_C",
    "BP_Stage_Cursor_C", "BP_Stage_Name_C", "BP_Stage_C", "BP_StageSelectMain_C",
}

-- List property NAMES of an object's class chain WITHOUT reading any values.
-- Reading values is what crashes (a string/struct read as a pointer ->
-- EXCEPTION_ACCESS_VIOLATION); iterating the names is safe.
local function enumerate_names(obj)
    local lines = {}
    local cls
    pcall(function() cls = obj:GetClass() end)
    if not cls then return { "    (no class)" } end
    local seen, guard = {}, 0
    while cls and guard < 12 do
        guard = guard + 1
        local cn = "?"
        pcall(function() cn = cls:GetFName():ToString() end)
        if STOP_CLASSES[cn] then break end
        pcall(function()
            cls:ForEachProperty(function(prop)
                local nm
                pcall(function() nm = prop:GetFName():ToString() end)
                if nm and not seen[nm] then
                    seen[nm] = true
                    lines[#lines + 1] = "    [" .. cn .. "] " .. nm
                end
            end)
        end)
        cls = class_super(cls)
    end
    if #lines == 0 then lines[1] = "    (no properties)" end
    return lines
end

-- Safe location read (engine function, well-defined return type).
local function actor_loc(a)
    local v = try(function() return a:K2_GetActorLocation() end)
    if not v then v = try(function() return a:GetActorLocation() end) end
    if not v then return nil end
    local x = try(function() return v.X end)
    local y = try(function() return v.Y end)
    local z = try(function() return v.Z end)
    if type(x) ~= "number" then return nil end
    return string.format("(%.0f, %.0f, %.0f)", x, y or 0, z or 0)
end

local function cmd_selectactors()
    local out = { "selectactors: property NAMES + locations (no value reads - crash-safe)" }
    for _, cls in ipairs(SELECT_ACTORS) do
        local ok, arr = pcall(function() return FindAllOf(cls) end)
        if ok and arr and #arr > 0 then
            out[#out + 1] = "== " .. cls .. "  (x" .. #arr .. ") =="
            -- locations of the first few instances (safe)
            for i = 1, math.min(#arr, 6) do
                local a = arr[i]
                if a and (pcall(function() return a:IsValid() end)) and a:IsValid() then
                    out[#out + 1] = "   inst " .. i .. " loc = " .. tostring(actor_loc(a))
                end
            end
            -- property names of the first instance only
            local a1 = arr[1]
            if a1 and (pcall(function() return a1:IsValid() end)) and a1:IsValid() then
                out[#out + 1] = "   -- property names --"
                for _, ln in ipairs(enumerate_names(a1)) do out[#out + 1] = ln end
            end
            out[#out + 1] = ""
        end
    end
    if #out == 1 then out[#out + 1] = "  (no select actors found)" end
    return out
end

-- Character-name discovery: for each roster cell, its UniqId + whatever name we
-- can resolve from CharaSelectData, plus its grid location. Specific named reads
-- only (never bulk enumeration).
local function cmd_charnames()
    local out = { "charnames: UniqId -> name/location for each roster cell" }
    local ok, arr = pcall(function() return FindAllOf("BP_Select_Child_C") end)
    if not ok or not arr or #arr == 0 then
        out[#out + 1] = "  (no BP_Select_Child_C - open character select first)"
        return out
    end
    local NAME_PROPS = { "CharaName", "Name", "NameText", "DisplayName", "CharaNameText", "CharaId", "CharaID" }
    for i = 1, math.min(#arr, 40) do
        local c = arr[i]
        if c and (pcall(function() return c:IsValid() end)) and c:IsValid() then
            local uid = try(function() return c.UniqId end)
            local line = "  UniqId=" .. tostring(uid) .. "  loc=" .. tostring(actor_loc(c))
            local data = try(function() return c.CharaSelectData end)
            if data then
                line = line .. "  data=" .. tostring(try(function() return data:GetFullName() end))
                for _, p in ipairs(NAME_PROPS) do
                    local v = try(function() return data[p] end)
                    if v ~= nil then
                        local s = try(function() return v:ToString() end)
                        line = line .. "  " .. p .. "=" .. tostring(s or v)
                    end
                end
            end
            -- the portrait material / mesh ASSET usually encodes the character
            -- code (e.g. chr012 or a name), unlike the generic component path
            local mt = try(function() return c.MT_Chara end)
            if mt then
                line = line .. "\n      MT_Chara=" .. tostring(try(function() return mt:GetFullName() end))
                local parent = try(function() return mt.Parent end)
                if parent then
                    line = line .. "\n      MT_parent=" .. tostring(try(function() return parent:GetFullName() end))
                end
            end
            local sm = try(function() return c.SM_Chara end)
            if sm then
                local asset = try(function() return sm.StaticMesh end)
                if asset then
                    line = line .. "\n      Mesh=" .. tostring(try(function() return asset:GetFullName() end))
                end
                local mats = try(function() return sm:GetMaterial(0) end)
                if mats then
                    line = line .. "\n      Mat0=" .. tostring(try(function() return mats:GetFullName() end))
                end
            end
            out[#out + 1] = line
        end
    end
    return out
end

-- Keyboard / controller config. SAFE profile: enumerate properties of only the
-- ONE known container widget, then list its children by name/text (no property
-- enumeration on the children - that is what crashed probevis on this screen).
local function cmd_keyconfdump()
    local out = { "keyconfdump" }
    for _, cls in ipairs({ "WD_KeyboardConf_C", "WD_KeyConf_C",
                           "WD_KeyboardConfMain_C", "WD_KeyConfMain_C" }) do
        local w = find_by_substr(cls)
        if w and is_visible(w) == true then
            out[#out + 1] = "== " .. cls .. " (VISIBLE) =="
            dump_widget(w, cls, out, 70)
            out[#out + 1] = ""
        end
    end
    if #out == 1 then out[#out + 1] = "  (no key-config widget visible)" end
    return out
end

-- Dump the RAW (undecoded) command list for the open character: every entry's
-- name and its command text with the $ffXX$ icon tokens intact. One capture per
-- character gives everything needed to map the icon tokens exactly.
local function tarr_count(a)
    if not a then return nil end
    for _, g in ipairs({
        function() return #a end,
        function() return a:GetArrayNum() end,
        function() return a:Num() end,
    }) do
        local v = try(g)
        if type(v) == "number" then return v end
    end
    return nil
end

local function tarr_str(a, i0)
    if not a then return nil end
    local n = tarr_count(a)
    if type(n) ~= "number" or i0 < 0 or i0 >= n then return nil end
    for _, g in ipairs({
        function() return a[i0 + 1] end,
        function() return a[i0] end,
        function() return a:get(i0) end,
    }) do
        local v = try(g)
        if type(v) == "string" and v ~= "" then return v end
        local s = try(function() return v:ToString() end)
        if type(s) == "string" and s ~= "" then return s end
    end
    return nil
end

local function cmd_cmdraw()
    local out = { "cmdraw: RAW command list (icon tokens intact)" }
    local cl = find_by_substr("WD_CommandList_C")
    if not cl then
        out[#out + 1] = "  (WD_CommandList_C not found - open the command list first)"
        return out
    end
    local cn = try(function() return cl.TextBlock_CharName:GetText():ToString() end)
    out[#out + 1] = "character = " .. tostring(cn)
    local names = try(function() return cl.CmdNameArray end)
    local texts = try(function() return cl.CmdTextArray end)
    local nn = tarr_count(names)
    local nt = tarr_count(texts)
    out[#out + 1] = "CmdNameArray count = " .. tostring(nn) .. ", CmdTextArray count = " .. tostring(nt)
    local total = math.max(tonumber(nn) or 0, tonumber(nt) or 0)
    if total == 0 then
        out[#out + 1] = "  (arrays unreadable; falling back to visible rows)"
        local ok, arr = pcall(function() return FindAllOf("WD_CmdListButton_C") end)
        if ok and arr then
            for i = 1, math.min(#arr, 30) do
                local w = arr[i]
                if is_visible(w) == true then
                    local nm = try(function() return w.CommandName:ToString() end)
                    local tx = try(function() return w.CommandText:ToString() end)
                    out[#out + 1] = "  \"" .. tostring(nm) .. "\"  =  " .. tostring(tx)
                end
            end
        end
        return out
    end
    for i = 0, math.min(total - 1, 60) do
        out[#out + 1] = "  [" .. i .. "] \"" .. tostring(tarr_str(names, i)) ..
            "\"  =  " .. tostring(tarr_str(texts, i))
    end
    return out
end

-- Deeper cursor probe: for the active list container, read the cursor widget's
-- slot position and each row's slot position / render opacity / animation state,
-- so we can tell which row is selected (whichever the cursor's Y matches, or the
-- row that differs in opacity/animation).
local function cmd_slotdump()
    local out = { "slotdump: cursor + per-row position/opacity/anim" }
    for _, cls in ipairs(LIST_CONTAINER_CLASSES) do
        local arr = try(function() return FindAllOf(cls) end) or {}
        for i = 1, #arr do
            local c = arr[i]
            if is_visible(c) == true then
                local cursor = try(function() return c.WD_OptionListCursor end)
                out[#out + 1] = "== " .. cls .. " ==" ..
                    "  cursorSlot=" .. (cursor and (slot_xy(cursor) or "?") or "no-cursor") ..
                    "  ListCursorSlot=" .. (xy_str(try(function() return c.ListCursorSlot:GetPosition() end)) or "?") ..
                    "  CursorOffsetPos=" .. (read_xy(c, "CursorOffsetPos") or "?")
                local panel = try(function() return c.CanvasPanel_Option end)
                local cnt = panel and try(function() return panel:GetChildrenCount() end) or nil
                if type(cnt) == "number" then
                    for j = 0, math.min(cnt - 1, 30) do
                        local ch = try(function() return panel:GetChildAt(j) end)
                        if ch then
                            local nm = ftext_prop(ch, "ItemName")
                            local op = try(function() return ch:GetRenderOpacity() end)
                            local anim = try(function() return ch:IsAnyAnimationPlaying() end)
                            out[#out + 1] = "   [" .. j .. "] " ..
                                (nm and ("\"" .. nm .. "\"") or class_name(ch)) ..
                                "  slot=" .. (slot_xy(ch) or "?") ..
                                "  opac=" .. tostring(op) ..
                                "  anim=" .. tostring(anim)
                        end
                    end
                end
                break
            end
        end
    end
    if #out == 1 then out[#out + 1] = "  (no visible list container found)" end
    return out
end

-- Enumerate the submenu container widgets (the analog of WD_MainMenu_C for each
-- category) to find their selection-index variable, the way we found IndexFocus.
local SUBMENU_CLASSES = {
    "WD_MainMenu_C", "WD_MenuOption_C", "WD_MMVersus_C", "WD_MMStory_C",
    "WD_MMRanking_C", "WD_OnlineMenu_C",
}
local function cmd_subenum()
    local out = { "subenum: submenu container properties (looking for the index var)" }
    for _, cls in ipairs(SUBMENU_CLASSES) do
        local w = find_by_substr(cls) -- prefers a VISIBLE instance
        out[#out + 1] = "== " .. cls .. (w and (is_visible(w) == true and " (visible)" or " (hidden)") or "") .. " =="
        if w then
            for _, ln in ipairs(enumerate_all(w)) do out[#out + 1] = ln end
        else
            out[#out + 1] = "  (not found)"
        end
    end
    return out
end

local function cmd_class(class)
    local out = { "class " .. class }
    local ok, obj = pcall(function() return FindFirstOf(class) end)
    if not ok or obj == nil then
        out[#out + 1] = "  (not found)"
        return out
    end
    out[#out + 1] = "  exactClass = " .. class_name(obj)
    out[#out + 1] = "  full       = " .. full_name(obj)
    return out
end

-- The character-select sub-screens: the costume / color picker, the Infinity
-- Stone picker, and their rows. These are the screens that still read nothing.
--
-- Deliberately ONE command instead of five, because every scan costs a real trip
-- out of the game and back. It prints, in order:
--   1. every UserWidget class currently VISIBLE, so that if the class guesses
--      below are wrong we still learn the correct names from the same dump
--   2. every instance of each candidate class, and whether it is visible
--   3. a property enumeration + subtree for the visible ones
--   4. all visible text
--
-- enumerate_all reads property VALUES. Doing that in bulk across everything on
-- screen is what hard crashed the game in probeall/probevis, and pcall cannot
-- catch it. Here it is capped to MAX_ENUM objects, which keeps it to the same
-- single-object pattern screendump has always used safely.
local CHARSUB_CLASSES = {
    "WD_Menu_Con_C", "WD_Menu_Gem_Button_C", "WD_GemDetail_C",
    "WD_ListItem00_C", "WD_ListItem01_C", "WD_SelectTeamList_C",
}
local CHARSUB_MAX_ENUM = 4

local function cmd_charsub()
    local out = { "charsub: character-select sub-screens" }

    -- 1) what is actually on screen right now
    out[#out + 1] = "== VISIBLE UserWidget classes =="
    local counts = {}
    local all = try(function() return FindAllOf("UserWidget") end) or {}
    for i = 1, #all do
        if is_visible(all[i]) == true then
            local cn = class_name(all[i])
            counts[cn] = (counts[cn] or 0) + 1
        end
    end
    local names = {}
    for cn in pairs(counts) do names[#names + 1] = cn end
    table.sort(names)
    if #names == 0 then
        out[#out + 1] = "  (nothing visible)"
    else
        for _, cn in ipairs(names) do
            out[#out + 1] = "  " .. cn .. " x" .. counts[cn]
        end
    end

    -- 2 and 3) the candidate classes
    local enumed = 0
    for _, cls in ipairs(CHARSUB_CLASSES) do
        local list = try(function() return FindAllOf(cls) end) or {}
        out[#out + 1] = "== " .. cls .. "  instances=" .. #list .. " =="
        local any_visible = false
        for i = 1, #list do
            local w = list[i]
            local vis = is_visible(w)
            out[#out + 1] = "  [" .. i .. "] visible=" .. tostring(vis) ..
                "  " .. full_name(w)
            if vis == true then
                any_visible = true
                if enumed < CHARSUB_MAX_ENUM then
                    enumed = enumed + 1
                    for _, ln in ipairs(enumerate_all(w)) do out[#out + 1] = ln end
                end
            end
        end
        if any_visible then
            for _, ln in ipairs(cmd_tree((cls:gsub("_C$", "")), 60)) do
                out[#out + 1] = ln
            end
        end
    end
    if enumed >= CHARSUB_MAX_ENUM then
        out[#out + 1] = "(enumeration capped at " .. CHARSUB_MAX_ENUM ..
            " objects on purpose; bulk value reads crash the game)"
    end

    out[#out + 1] = "== visible text =="
    for _, ln in ipairs(cmd_text(nil, true)) do out[#out + 1] = ln end
    return out
end

-- Developer-only tools ----------------------------------------------------
-- Available only when devmode.txt exists (the same gate main.lua uses), so a
-- player's install never has them.
--
-- `luafile <name>` runs a Lua snippet from the data folder on the game thread
-- and writes whatever lines it returns as the answer. That turns a new screen
-- into a question that can be asked from outside the game, instead of a new
-- hard-wired dump command and a restart for every one. The snippet receives the
-- helpers below as its single argument. It is as dangerous as any other code
-- here: the crash rules (no bulk value reads, no hidden widgets, bounds-checked
-- arrays) apply to snippets exactly as they do to readers.
--
-- `reload <module>` hot-swaps one module (see main.lua).
local DEV = false

-- The reflected type of a property, e.g. "IntProperty". Reads no value.
local function prop_type(prop)
    local t
    pcall(function() t = prop:GetClass():GetFName():ToString() end)
    return t or "?"
end

-- Property names WITH their types for an object's class chain. Like
-- enumerate_names it reads no values, so it is safe on any live object, and the
-- type is what tells you which properties are safe to read afterwards.
local function enumerate_typed(obj, all_classes)
    local lines = {}
    if not live(obj) then return { "    (invalid object)" } end
    local cls
    pcall(function() cls = obj:GetClass() end)
    if not cls then return { "    (no class)" } end
    local seen, guard = {}, 0
    while cls and guard < 14 do
        guard = guard + 1
        local cn = "?"
        pcall(function() cn = cls:GetFName():ToString() end)
        if STOP_CLASSES[cn] and not all_classes then break end
        if cn == "Object" then break end
        pcall(function()
            cls:ForEachProperty(function(prop)
                local nm
                pcall(function() nm = prop:GetFName():ToString() end)
                if nm and not seen[nm] then
                    seen[nm] = true
                    lines[#lines + 1] = "    [" .. cn .. "] " .. nm .. " : " .. prop_type(prop)
                end
            end)
        end)
        cls = class_super(cls)
    end
    if #lines == 0 then lines[1] = "    (no properties)" end
    return lines
end

local function dev_helpers()
    return {
        dir = OUT_DIR,
        try = try, trim = trim,
        class_name = class_name, full_name = full_name, path_of = path_of,
        get_text = get_text, ftext_prop = ftext_prop, is_visible = is_visible,
        resolve = resolve, read_xy = read_xy, slot_xy = slot_xy, actor_loc = actor_loc,
        tarr_count = tarr_count, collect_text = collect_text,
        enumerate_names = enumerate_names, enumerate_typed = enumerate_typed,
        class_super = class_super, prop_type = prop_type,
    }
end

-- `luafile <name> [argument]`: anything after the file name reaches the snippet
-- as its second argument, so one snippet can serve many classes.
local function cmd_luafile(spec)
    local name, arg = spec:match("^(%S+)%s*(.*)$")
    local out = { "luafile " .. spec }
    local chunk, lerr = loadfile(OUT_DIR .. name)
    if not chunk then
        out[#out + 1] = "  load error: " .. tostring(lerr)
        return out
    end
    local okc, res = pcall(chunk, dev_helpers(), arg)
    if not okc then
        out[#out + 1] = "  run error: " .. tostring(res)
    elseif type(res) == "table" then
        for _, ln in ipairs(res) do out[#out + 1] = tostring(ln) end
    elseif res ~= nil then
        out[#out + 1] = tostring(res)
    end
    return out
end

-- Dispatch (runs on game thread) -----------------------------------------

local function run_command(cmd)
    -- A leading "-" runs the command without speaking "inspector done", for
    -- scripted runs that would otherwise talk over the screen being tested.
    local quiet = false
    if cmd:sub(1, 1) == "-" then
        quiet = true
        cmd = trim(cmd:sub(2))
    end
    local verb, rest = cmd:match("^(%S+)%s*(.*)$")
    verb = (verb or ""):lower()
    rest = trim(rest or "")
    local out
    if DEV and verb == "luafile" and rest ~= "" then
        out = cmd_luafile(rest)
    elseif DEV and verb == "reload" and rest ~= "" then
        local okr, e = false, "no reloader installed"
        if _G.MvCIAccess_reload then okr, e = _G.MvCIAccess_reload(rest) end
        out = { "reload " .. rest .. " -> " .. tostring(okr) .. "  " .. tostring(e or "") }
    elseif verb == "scan" then
        out = cmd_scan()
    elseif verb == "snapshot" or verb == "widgets" then
        out = cmd_snapshot()
    elseif verb == "charsub" then
        out = cmd_charsub()
    elseif verb == "findall" and rest ~= "" then
        out = cmd_findall(rest)
    elseif verb == "find" and rest ~= "" then
        out = cmd_find(rest)
    elseif verb == "text" then
        out = cmd_text(rest ~= "" and rest or nil, true)
    elseif verb == "textall" then
        out = cmd_text(rest ~= "" and rest or nil, false)
    elseif verb == "probe" then
        out = cmd_probe()
    elseif verb == "tree" and rest ~= "" then
        out = cmd_tree(rest)
    elseif verb == "props" and rest ~= "" then
        out = cmd_props(rest)
    elseif verb == "probeidx" then
        out = cmd_probeidx()
    elseif verb == "probeany" then
        out = cmd_probeany()
    elseif verb == "probeall" then
        out = cmd_probeall()
    elseif verb == "charprobe" then
        out = cmd_charprobe()
    elseif verb == "probevis" then
        out = cmd_probevis()
    elseif verb == "optscan" then
        out = cmd_optscan()
    elseif verb == "subenum" then
        out = cmd_subenum()
    elseif verb == "optdiff" then
        out = cmd_optdiff()
    elseif verb == "listdump" then
        out = cmd_listdump()
    elseif verb == "slotdump" then
        out = cmd_slotdump()
    elseif verb == "langdump" then
        out = cmd_langdump()
    elseif verb == "autocheck" then
        out = cmd_autocheck()
    elseif verb == "screendump" then
        out = cmd_screendump()
    elseif verb == "cmdlistdump" then
        out = cmd_cmdlistdump()
    elseif verb == "cmdraw" then
        out = cmd_cmdraw()
    elseif verb == "keyconfdump" then
        out = cmd_keyconfdump()
    elseif verb == "selectdump" then
        out = cmd_selectdump()
    elseif verb == "selectactors" then
        out = cmd_selectactors()
    elseif verb == "charnames" then
        out = cmd_charnames()
    elseif verb == "propschain" and rest ~= "" then
        out = { "propschain " .. rest }
        for _, ln in ipairs(enumerate_all(find_by_substr(rest))) do out[#out + 1] = ln end
    elseif verb == "getculture" then
        out = cmd_getculture()
    elseif verb == "setculture" then
        out = cmd_setculture(rest ~= "" and rest or "en")
    elseif verb == "class" and rest ~= "" then
        out = cmd_class(rest)
    else
        out = {
            "unknown command: " .. cmd,
            "commands: scan | snapshot | findall <Class> | find <substr> | text [substr] | textall [substr] | probe | tree <substr> | props <substr> | getculture | setculture [code] | class <Class>",
        }
    end
    write_out(out)
    if ann and not quiet then ann.speak("inspector done: " .. verb, true) end
end

-- Public: run a command by name. MUST be called on the game thread: engine
-- reflection is only safe there, and main.lua's tick is the only caller.
function M.run(cmd)
    cmd = trim(cmd or "")
    if cmd == "" then return end
    local ok, err = pcall(run_command, cmd)
    if not ok then
        write_out({ "ERROR running '" .. cmd .. "':", "  " .. tostring(err) })
    end
end

-- Poll the command file; when a command appears, clear the file then run it.
-- Clearing first means the next poll sees an empty file, so a command runs once;
-- writing the same command again re-runs it. main.lua calls this from its
-- game-thread tick, twice a second.
local function poll()
    -- Players never use the inspector, and several of its commands read
    -- property values in bulk, which can crash the game: developer builds only.
    if not DEV then return end
    local raw = read_file(CMD_PATH)
    if not raw then return end
    local cmd = trim(raw)
    if cmd == "" then return end
    clear_cmd()
    M.run(cmd)
end
M.poll = poll

function M.init(announcer)
    ann = announcer
    pcall(function()
        local f = io.open(require("paths").file("devmode.txt"), "r")
        if f then f:close(); DEV = true end
    end)
    -- seed the files so NVDA has something to open
    clear_cmd()
    write_out({ "inspector ready. Write a command into inspector_cmd.txt.",
        "commands: scan | snapshot | findall <Class> | find <substr> | text [substr] | textall [substr] | probe | probeidx | tree <substr> | props <substr> | getculture | setculture [code] | class <Class>" })
    -- No poller of its own: a second LoopAsync would put file I/O on the async
    -- thread, which races the game thread (see the threading note in main.lua).
    -- main.lua's game-thread tick calls M.poll.
    return M
end

return M
