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
    local CharSub   = require("screen_charsub")

    Announcer.init()
    Inspector.init(Announcer)
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
    -- users never have. Turns on the Ctrl+Shift+D dump hotkey further down and
    -- the per-reader timing below.
    local DEV = false
    pcall(function()
        local f = io.open(require("paths").file("devmode.txt"), "r")
        if f then f:close(); DEV = true end
    end)

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
        -- CharSub must come before CharSel: the costume and Infinity Stone
        -- panels open ON TOP of the roster, and the roster stays visible
        -- underneath, so CharSel would otherwise answer first and starve them.
        local RARE   = { CmdList, KeyConf, CharSub, Stage, CharSel }
        local COMMON = { Options, Title }
        local rare_active = nil
        local tickn = 0

        -- Per-reader timing, developer builds only.
        --
        -- "It feels sluggish" has been guessed at more than once on this mod and
        -- the guesses were not always right, so measure instead: every reader
        -- call is timed and the running totals are dumped to perf.txt. A reader
        -- that is cheap but called constantly and one that is expensive but
        -- rare look identical from the outside and need opposite fixes.
        local RNAME = {
            [CmdList] = "cmdlist", [KeyConf] = "keyconf", [CharSub] = "charsub",
            [Stage] = "stage", [CharSel] = "charsel",
            [Options] = "options", [Title] = "title",
        }
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

        local function unified_tick()
            tickn = tickn + 1
            -- A rare screen that is open keeps priority cheaply, BUT anything
            -- that outranks it still gets a look in.
            --
            -- These screens nest: the costume / Infinity Stone panels open on
            -- top of character select while the roster stays visible beneath,
            -- so a reader pinned to the screen underneath would answer true
            -- forever and starve the panel sitting above it. Pinning without
            -- this re-check is why the costume panel read nothing at all.
            --
            -- Only the readers ABOVE the active one are re-probed, and only on
            -- the same every-3rd-tick cadence, so this costs no more than the
            -- ordinary rare sweep already does.
            if DEV and tickn % 40 == 0 then pcall(perf_dump) end
            if rare_active then
                if tickn % 3 == 0 then
                    for _, r in ipairs(RARE) do
                        if r == rare_active then break end
                        if ask(r, false) then
                            rare_active = r
                            return
                        end
                    end
                end
                if ask(rare_active, false) then return end
                rare_active = nil
            end
            if tickn % 3 == 0 then
                for _, r in ipairs(RARE) do
                    if ask(r, false) then
                        rare_active = r
                        return
                    end
                end
            end
            for _, r in ipairs(COMMON) do
                if ask(r, false) then return end
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
                if CharSub.announce_now(true) then return end
                if Stage.announce_now(true) then return end
                if CharSel.announce_now(true) then return end
                if Options.announce_now(true) then return end
                Title.announce_now(true)
            end)
        end)
    end, "read_current")
    bind(Key.Z, CS, function() pcall(Announcer.repeat_last) end, "repeat_last")
    -- NOTE: not Ctrl+Shift+R - UE4SS's hot-reload key is Ctrl+R and would clash.
    bind(Key.G, CS, function() pcall(CharSel.reload_names) end, "reload_charnames")

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
        local want = (f:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        f:close()
        if want == "" then want = "charsub" end
        bind(Key.D, CS, function()
            pcall(function() Inspector.run(want) end)
        end, "dev_dump")
        print("[MvCIAccess] dev mode: Ctrl+Shift+D runs '" .. want .. "'")
    end)

    print("[MvCIAccess] loaded; hotkeys registered.")
end)

if not ok then record_error("main", err) end
