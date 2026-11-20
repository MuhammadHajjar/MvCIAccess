-- MvCIAccess : main.lua
-- Bootstrap: loads the announcer and the per-screen readers, then runs one
-- unified poller that speaks the focused item on whichever screen is active.
--
-- USER HOTKEYS (chosen to avoid Ctrl+R = UE4SS hot reload, and to dodge NVDA's
-- own combos):
--   Ctrl+Shift+A  re-read the current selection
--   Ctrl+Shift+Z  repeat the last announcement
--   Ctrl+Shift+G  reload charnames.txt (optional character-name overrides)
-- In a fight:
--   Ctrl+Shift+H  health of both teams
--   Ctrl+Shift+M  Hyper Combo meter of both teams
--   Ctrl+Shift+T  time left
--   Ctrl+Shift+P  where the opponent is
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
    local Core      = require("core")
    local Menu      = require("screen_menu")
    local Fight     = require("screen_fight")
    local Mission   = require("screen_mission")
    local Title     = require("screen_title")
    local Options   = require("screen_options")
    local CmdList   = require("screen_commandlist")
    local KeyConf   = require("screen_keyconfig")
    local Stage     = require("screen_stage")
    local CharSel   = require("screen_charselect")
    local CharSub   = require("screen_charsub")

    Announcer.init()
    Inspector.init(Announcer)
    Menu.init(Announcer)
    Fight.init(Announcer)
    Mission.init(Announcer)
    Title.init(Announcer)
    Options.init(Announcer)
    CmdList.init(Announcer)
    KeyConf.init(Announcer)
    Stage.init(Announcer)
    CharSel.init(Announcer)
    CharSub.init(Announcer)

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

    -- Developer mode, enabled purely by the presence of a devmode.txt file that
    -- users never have. Turns on the Ctrl+Shift+D dump hotkey further down, the
    -- per-reader timing below, and the inspector's `luafile` / `reload`.
    local DEV = false
    pcall(function()
        local f = io.open(require("paths").file("devmode.txt"), "r")
        if f then f:close(); DEV = true end
    end)

    -- WHICH READER SPEAKS ------------------------------------------------------
    -- Decided again on every tick, from three cheap facts that core.lua works
    -- out once per tick (about 1 ms in all, no FindAllOf):
    --   * the dialog the game's popup controller is showing, if any;
    --   * the active menu: the one visible menu widget that has input and
    --     nothing open on top of it (menus nest, and the ones underneath stay
    --     visible, so visibility alone says nothing);
    --   * the flow actor, which names the level: title/menus, a select screen,
    --     a fight.
    -- A reader that still searches with FindAllOf (19 ms a call) is only asked
    -- when those facts say its screen can be up. Nothing is ever pinned: a
    -- reader that latched onto a screen used to starve whatever opened above
    -- it, and that bug shape has bitten this mod three times.

    -- Screens of the menu family that have their own reader, by widget class.
    local BY_CLASS = {
        WD_CommandList_C = CmdList,
        WD_KeyboardConfMain_C = KeyConf, WD_KeyConfMain_C = KeyConf,
        WD_KeyboardConf_C = KeyConf, WD_KeyConf_C = KeyConf,
        WD_MissionMain_C = Mission, WD_MissionMain_Update1_C = Mission,
        WD_MissionMain_Update2_C = Mission,
    }
    -- Readers of the select screens, which are built from actors: the stage
    -- picker, the roster, and the costume / Infinity Stone panels that open on
    -- top of the roster. Each one checks the flow actor's state itself.
    -- CharSub is asked before CharSel so that it notices its panel closing
    -- (and forgets what it last said) even while the roster is answering.
    local SELECT = { Stage, CharSub, CharSel }
    -- The readers in BY_CLASS, once each. Every tick, those that do not have
    -- the screen are told so, which is how they learn their screen closed.
    local OWNED = { CmdList, KeyConf, Mission }

    local RNAME = {
        [Menu] = "menu", [Fight] = "fight", [Mission] = "mission",
        [CmdList] = "cmdlist", [KeyConf] = "keyconf", [CharSub] = "charsub",
        [Stage] = "stage", [CharSel] = "charsel",
        [Options] = "options", [Title] = "title",
    }

    -- Developer only: hot-swap one module without restarting the game, driven
    -- by the inspector command "reload <module>". The module table keeps its
    -- identity and only its contents are replaced, because the tables above
    -- hold that table. Runs on the game thread, the same thread as the poller,
    -- so a swap can never land in the middle of a tick. A module that was
    -- never loaded is simply loaded; it joins no reader list.
    --
    -- The file is read with loadfile, NOT require: UE4SS resolves require
    -- through a searcher of its own that keeps handing back the code it read
    -- when the game started, even after package.loaded is cleared.
    if DEV then
        local scripts_dir = (debug.getinfo(1, "S").source or ""):match("^@?(.*[/\\])") or ""
        _G.MvCIAccess_reload = function(spec)
            local name = tostring(spec):match("^(%S+)")
            if not name then return false, "usage: reload <module>" end
            local old = package.loaded[name]
            local chunk, lerr = loadfile(scripts_dir .. name .. ".lua")
            if not chunk then return false, tostring(lerr) end
            local okr, new = pcall(chunk, name)
            if not okr or type(new) ~= "table" then
                return false, tostring(new)
            end
            if type(new.init) == "function" then
                local oki, ei = pcall(new.init, Announcer)
                if not oki then return false, "init: " .. tostring(ei) end
            end
            if type(old) == "table" then
                for k in pairs(old) do old[k] = nil end
                for k, v in pairs(new) do old[k] = v end
                package.loaded[name] = old
                return true, "swapped"
            end
            package.loaded[name] = new
            return true, "loaded, not in a reader list"
        end
    end

    -- Requests raised by the hotkeys. A hotkey callback runs on UE4SS's own
    -- thread, not the game thread, so all it may do is flip one of these
    -- existing fields; the game-thread tick below does the actual work. See the
    -- threading note on the poller for why.
    local want = {
        reread = false, repeat_last = false, reload_names = false, dev = false,
        health = false, meter = false, time = false, where = false,
    }
    local dev_cmd = "charsub"

    -- ONE unified poller for every screen ------------------------------------
    --   * ONE queued callback at a time, ever (strict in-flight guard).
    --   * We NEVER queue more while one is outstanding - no backlog can form.
    --   * If a callback is genuinely lost (level transition / restart), a slow
    --     10s stale-timer releases the guard and queues exactly one replacement.
    --
    -- THREADING: every Lua state UE4SS gives a mod shares one Lua VM, and the
    -- LoopAsync thread runs at the same time as the game thread. Lua has no
    -- locking, so Lua that allocates on the async thread while the game thread
    -- is inside a reader races the garbage collector and the registry. That
    -- is what used to end a session with UE4SS logging
    --   Hook threw exception: "[Lua::Registry::get_function_ref] Ref was not function"
    -- and removing its tick hook (the mod goes silent until the game restarts),
    -- or with an access violation inside UE4SS.dll. So the async callback below
    -- allocates nothing: it bumps a counter and queues one fixed function.
    -- The heartbeat file, the inspector's command file and the hotkeys are all
    -- serviced from the game-thread tick instead.
    if not _G.MvCIAccess_unified_poll then
        _G.MvCIAccess_unified_poll = true
        local hb_path = require("paths").file("heartbeat.txt")
        local abeat, gbeat = 0, 0
        local inflight = false
        local queued_at = 0
        local last_tick_err = nil
        local tickn = 0

        -- Per-reader timing, developer builds only.
        --
        -- "It feels sluggish" has been guessed at more than once on this mod and
        -- the guesses were not always right, so measure instead: every reader
        -- call is timed and the running totals are dumped to perf.txt. A reader
        -- that is cheap but called constantly and one that is expensive but
        -- rare look identical from the outside and need opposite fixes.
        local perf_s, perf_n = {}, {}
        local perf_path = require("paths").file("perf.txt")

        local function ask(r, force)
            if not DEV then return r.announce_now(force) end
            local t0 = os.clock()
            local res = r.announce_now(force)
            local nm = RNAME[r] or "?"
            perf_s[nm] = (perf_s[nm] or 0) + (os.clock() - t0)
            perf_n[nm] = (perf_n[nm] or 0) + 1
            return res
        end

        local function perf_dump()
            local names = {}
            for k in pairs(perf_s) do names[#names + 1] = k end
            table.sort(names, function(a, b) return perf_s[a] > perf_s[b] end)
            local f = io.open(perf_path, "w")
            if not f then return end
            f:write("MvCIAccess reader cost, ticks=" .. tickn ..
                "  (sorted by total time)\n")
            f:write("reader      calls    total_ms   avg_ms\n")
            for _, nm in ipairs(names) do
                local total_ms = perf_s[nm] * 1000
                local n = perf_n[nm]
                f:write(string.format("%-10s %6d %10.1f %8.2f\n",
                    nm, n, total_ms, total_ms / math.max(n, 1)))
            end
            f:close()
        end

        -- The select screens. Each of these readers asks the level's flow
        -- actor whether its screen has input, so they are exact and cost a
        -- handful of property reads: no cadence, no pinning.
        local function select_sweep(force)
            local claimed = false
            for _, r in ipairs(SELECT) do
                -- every reader is asked every tick, so each one sees its screen
                -- close; only the first to claim speaks
                if claimed then
                    if r.closed then r.closed() end
                elseif ask(r, force) then
                    claimed = true
                end
            end
            return claimed
        end

        -- One pass over the readers. force = speak even if nothing changed.
        local function sweep(force)
            Core.begin_tick()
            if not Core.in_fight() then Fight.reset() end
            -- a dialog sits above everything else
            local dlg = Core.dialog()
            local act = (not dlg) and Core.active_menu() or nil
            local owner = act and BY_CLASS[act.cls] or nil
            for _, r in ipairs(OWNED) do
                if r ~= owner and r.closed then r.closed() end
            end
            -- The select readers are told whenever something else has the
            -- screen (a dialog, Team Select, another level), so that coming
            -- back to the roster reads the highlighted fighter again.
            local function select_closed()
                for _, r in ipairs(SELECT) do
                    if r.closed then r.closed() end
                end
            end
            if dlg then
                select_closed()
                return ask(Menu, force)
            end
            if owner then
                Menu.announce_now(false) -- lets the menu reader see it lost the screen
                if ask(owner, force) then
                    select_closed()
                    return true
                end
            end
            if ask(Menu, force) then
                select_closed()
                return true
            end
            local flow = Core.flow_name()
            if flow:sub(1, 14) == "GF_CharaSelect" or flow == "GF_TeamSettings_C" then
                if select_sweep(force) then return true end
            else
                select_closed()
            end
            -- the fight readers never claim: they only report events
            ask(Fight, force)
            Mission.announce_hud(force)
            return false
        end

        local function unified_tick()
            tickn = tickn + 1
            if DEV and tickn % 40 == 0 then pcall(perf_dump) end
            if not DEV then return sweep(false) end
            -- the whole pass, core.lua's own work included
            local t0 = os.clock()
            sweep(false)
            perf_s.tick = (perf_s.tick or 0) + (os.clock() - t0)
            perf_n.tick = (perf_n.tick or 0) + 1
        end

        -- The whole of the mod's periodic work. Runs on the game thread only.
        local running = false
        local function tick_body()
            gbeat = gbeat + 1
            if want.repeat_last then
                want.repeat_last = false
                pcall(Announcer.repeat_last)
            end
            if want.reload_names then
                want.reload_names = false
                pcall(CharSel.reload_names)
            end
            if want.dev then
                want.dev = false
                pcall(Inspector.run, dev_cmd)
            end
            for _, kind in ipairs({ "health", "meter", "time", "where" }) do
                if want[kind] then
                    want[kind] = false
                    Core.begin_tick()
                    pcall(Fight.report, kind)
                end
            end
            -- A reader that throws used to vanish without a trace. Log it, but
            -- only when the message changes, since a broken reader fails the
            -- same way four times a second.
            local okt, et
            if want.reread then
                want.reread = false
                okt, et = pcall(sweep, true)
            else
                okt, et = pcall(unified_tick)
            end
            if not okt and tostring(et) ~= last_tick_err then
                last_tick_err = tostring(et)
                record_error("tick", et)
            end
            -- The inspector's command file, twice a second.
            if gbeat % 2 == 0 then pcall(Inspector.poll) end
            -- Heartbeat, once a second. "game" stops advancing if ticks stop
            -- arriving; "async" is how many times the timer fired.
            if gbeat % 4 == 0 then
                local f = io.open(hb_path, "w")
                if f then
                    f:write("async=" .. abeat .. " game=" .. gbeat ..
                        " time=" .. os.date("%H:%M:%S") .. "\n")
                    f:close()
                end
            end
        end

        -- Everything one tick says goes to the speech companion as ONE line:
        -- it reads a single slot, so a second line in the same tick would
        -- overwrite the first before it is heard.
        local function game_tick()
            running = true
            pcall(Announcer.begin_batch)
            pcall(tick_body)
            pcall(Announcer.flush)
            running = false
            inflight = false
        end

        -- Async thread: no allocation, no I/O, no closures (see THREADING).
        LoopAsync(250, function()
            abeat = abeat + 1
            local now = os.time()
            -- Release the guard only if a callback has been outstanding ~10s
            -- AND is not running right now: a long dev command must never have
            -- a second tick queued alongside it.
            if inflight and not running and (now - queued_at) >= 10 then inflight = false end
            if not inflight and not running then
                inflight = true
                queued_at = now
                ExecuteInGameThread(game_tick)
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
    -- Each hotkey only raises a flag; the next game-thread tick acts on it.
    -- Read current selection: option row if we're in a list, else the main-menu item.
    bind(Key.A, CS, function() want.reread = true end, "read_current")
    bind(Key.Z, CS, function() want.repeat_last = true end, "repeat_last")
    -- NOTE: not Ctrl+Shift+R - UE4SS's hot-reload key is Ctrl+R and would clash.
    bind(Key.G, CS, function() want.reload_names = true end, "reload_charnames")
    -- In a fight.
    bind(Key.H, CS, function() want.health = true end, "fight_health")
    bind(Key.M, CS, function() want.meter = true end, "fight_meter")
    bind(Key.T, CS, function() want.time = true end, "fight_time")
    bind(Key.P, CS, function() want.where = true end, "fight_where")

    -- Development only. Ctrl+Shift+D dumps whatever screen you are standing on
    -- through the inspector, so a screen can be investigated without alt-tabbing
    -- out to write a command file by hand.
    --
    -- It is gated on a devmode.txt file rather than on being commented out,
    -- because release.py copies these scripts straight into the payload: a
    -- commented-out hotkey is one forgotten edit away from shipping, whereas a
    -- user who has no devmode.txt can never get the bind at all. The command it
    -- runs can be changed by putting a different inspector command in that file.
    pcall(function()
        local P = require("paths")
        local f = io.open(P.file("devmode.txt"), "r")
        if not f then return end
        local cmd = (f:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        f:close()
        if cmd ~= "" then dev_cmd = cmd end
        bind(Key.D, CS, function() want.dev = true end, "dev_dump")
        print("[MvCIAccess] dev mode: Ctrl+Shift+D runs '" .. dev_cmd .. "'")
    end)

    print("[MvCIAccess] loaded; hotkeys registered.")
end)

if not ok then record_error("main", err) end
