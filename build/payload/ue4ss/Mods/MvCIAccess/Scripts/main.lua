-- MvCIAccess : main.lua
-- Bootstrap: loads the announcer and the per-screen readers, then runs one
-- unified poller that speaks the focused item on whichever screen is active.
--
-- USER HOTKEYS (these are the only ones; chosen to avoid Ctrl+R = UE4SS hot
-- reload, and to dodge NVDA's own combos):
--   Ctrl+Shift+A  re-read the current selection
--   Ctrl+Shift+Z  repeat the last announcement
--   Ctrl+Shift+G  reload charnames.txt (optional character-name overrides)
--
-- The development inspector (screen dumps, property probes) is still present in
-- inspector.lua and can be driven by writing a command into inspector_cmd.txt,
-- but no debug hotkeys are bound in release builds.

local ERR_PATH = require("paths").errors

local function record_error(where, err)
    local ok, f = pcall(io.open, ERR_PATH, "a")
    if ok and f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  [" .. where .. "] " .. tostring(err) .. "\n")
        f:close()
    end
    print("[MvCIAccess] ERROR [" .. where .. "] " .. tostring(err))
end

-- Fresh error file each launch.
do
    local ok, f = pcall(io.open, ERR_PATH, "w")
    if ok and f then f:write("=== MvCIAccess errors " .. os.date() .. " ===\n"); f:close() end
end

local ok, err = pcall(function()
    local Announcer = require("announcer")
    local Inspector = require("inspector")
    local Title     = require("screen_title")
    local Options   = require("screen_options")
    local CmdList   = require("screen_commandlist")
    local KeyConf   = require("screen_keyconfig")
    local Stage     = require("screen_stage")
    local CharSel   = require("screen_charselect")

    Announcer.init()
    Inspector.init(Announcer)
    Title.init(Announcer)
    Options.init(Announcer)
    CmdList.init(Announcer)
    KeyConf.init(Announcer)
    Stage.init(Announcer)
    CharSel.init(Announcer)

    -- Start the speech companion automatically. The installer records where it
    -- put the executable; if that file is missing (e.g. a manual install) the
    -- user can still start it by hand and everything else works unchanged.
    pcall(function()
        local P = require("paths")
        local f = io.open(P.file("companion_path.txt"), "r")
        if not f then return end
        local exe = (f:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        f:close()
        if exe == "" then return end
        -- `start ""` returns immediately so the game is never blocked
        os.execute('start "" "' .. exe .. '"')
    end)

    Announcer.speak("Marvel vs Capcom Infinite accessibility loaded.", true)

    -- ONE unified poller for every screen ------------------------------------
    -- Why: previously screen_title and screen_options each ran their own
    -- LoopAsync + ExecuteInGameThread. During a match the game thread pumps that
    -- queue slowly, so work piled up faster than it drained and the mod wedged
    -- permanently (game beat frozen, busy stuck true). Now:
    --   * ONE queued callback at a time, ever (strict in-flight guard).
    --   * We NEVER queue more while one is outstanding - no backlog can form.
    --   * If a callback is genuinely lost (level transition / restart), a slow
    --     10s stale-timer releases the guard and queues exactly one replacement.
    -- Options first (submenus / settings / pause), else the main menu.
    if not _G.MvCIAccess_unified_poll then
        _G.MvCIAccess_unified_poll = true
        local hb_path = require("paths").file("heartbeat.txt")
        local abeat, gbeat = 0, 0
        local inflight = false
        local queued_at = 0

        -- Screen readers. PRIORITY MATTERS and must be preserved every tick:
        -- the command list opens ON TOP of the pause menu, key config on top of
        -- the Settings list, and the main-menu widget stays visible inside every
        -- submenu - so a "sticky" active reader silently starves the others.
        --
        -- PERF: each reader costs a FindAllOf (~65ms), so probing all five every
        -- tick saturated the game thread. Compromise:
        --   * RARE screens (command list / key config / stage select) are probed
        --     only every 3rd tick - but once one is open it is checked EVERY tick
        --     (and short-circuits) until it closes.
        --   * COMMON screens (menus) are checked every tick, in priority order.
        local RARE   = { CmdList, KeyConf, Stage, CharSel }
        local COMMON = { Options, Title }
        local rare_active = nil
        local tickn = 0

        local function unified_tick()
            tickn = tickn + 1
            -- a rare screen that is currently open keeps priority, cheaply
            if rare_active then
                if rare_active.announce_now(false) then return end
                rare_active = nil
            end
            if tickn % 3 == 0 then
                for _, r in ipairs(RARE) do
                    if r.announce_now(false) then
                        rare_active = r
                        return
                    end
                end
            end
            for _, r in ipairs(COMMON) do
                if r.announce_now(false) then return end
            end
        end

        LoopAsync(250, function()
            abeat = abeat + 1
            local now = os.time()
            -- release the guard only if a callback has been outstanding ~10s
            if inflight and (now - queued_at) >= 10 then inflight = false end
            if not inflight then
                inflight = true
                queued_at = now
                ExecuteInGameThread(function()
                    gbeat = gbeat + 1
                    pcall(unified_tick)
                    inflight = false
                end)
            end
            local f = io.open(hb_path, "w")
            if f then
                f:write("async=" .. abeat .. " game=" .. gbeat ..
                    " inflight=" .. tostring(inflight) ..
                    " time=" .. os.date("%H:%M:%S") .. "\n")
                f:close()
            end
            return false
        end)
    end

    -- Hotkey helper that never lets a bad bind kill the mod.
    local function bind(key, mods, fn, label)
        local okb, errb = pcall(function()
            RegisterKeyBind(key, mods, fn)
        end)
        if not okb then record_error("bind " .. label, errb) end
    end

    local CS = { ModifierKey.CONTROL, ModifierKey.SHIFT }
    -- Read current selection: option row if we're in a list, else the main-menu item.
    bind(Key.A, CS, function()
        pcall(function()
            ExecuteInGameThread(function()
                if CmdList.announce_now(true) then return end
                if KeyConf.announce_now(true) then return end
                if Stage.announce_now(true) then return end
                if Options.announce_now(true) then return end
                Title.announce_now(true)
            end)
        end)
    end, "read_current")
    bind(Key.Z, CS, function() pcall(Announcer.repeat_last) end, "repeat_last")
    -- NOTE: not Ctrl+Shift+R - UE4SS's hot-reload key is Ctrl+R and would clash.
    bind(Key.G, CS, function() pcall(CharSel.reload_names) end, "reload_charnames")
    -- No debug hotkeys in release builds. The inspector is still available for
    -- development by writing a command into inspector_cmd.txt.

    print("[MvCIAccess] loaded; hotkeys registered.")
end)

if not ok then record_error("main", err) end
