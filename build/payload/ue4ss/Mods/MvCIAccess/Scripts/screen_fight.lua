-- screen_fight.lua
-- The fight itself: who is fighting, who went down, who won, and on demand the
-- health, meter, clock and positions.
--
-- The HUD is drawn by Blueprint actors from textures, so there is no text to
-- read. The numbers come from the same place the HUD gets them: the game's own
-- UIFightBPLib function library (/Script/Duck), called on its class default
-- object. Each call costs a few hundredths of a millisecond, so a tick of this
-- reader is well under a millisecond and never searches for anything.
--
-- Team 0 is player 1 ("you"). Each team has two fighters, member 0 and 1;
-- GetMasterCharacterNo says which of the two is on point.

local M = {}
local C = require("core")
local ann = nil

-- Fighter names by the game's own character id (PlType). The roster is drawn
-- from portraits only; these ids were read from the 36 roster cells
-- (BP_Select_Child_C.CharaSelectData.PlType) and joined to the names already
-- verified by ear for character select, then confirmed against live fights.
local NAMES = {
    [1] = "Ultron", [2] = "Mega Man X", [3] = "Gamora", [4] = "Jedah", [5] = "Thanos",
    [6] = "Ryu", [7] = "Captain Marvel", [8] = "Dante", [9] = "Iron Man", [10] = "Morrigan",
    [11] = "Captain America", [12] = "Strider Hiryu", [13] = "Spider-Man", [14] = "Chun-Li",
    [15] = "Hulk", [16] = "Firebrand", [17] = "Thor", [18] = "Chris Redfield",
    [19] = "Rocket Raccoon", [20] = "Frank West", [21] = "Doctor Strange", [22] = "Zero",
    [23] = "Nova", [24] = "Haggar", [25] = "Ghost Rider", [26] = "Nemesis", [27] = "Hawkeye",
    [28] = "Spencer", [29] = "Dormammu", [30] = "Arthur",
    [34] = "Venom", [35] = "Sigma", [36] = "Black Panther", [37] = "Winter Soldier",
    [38] = "Black Widow", [39] = "Monster Hunter",
    [40] = "Ultron Drone",
}
M.NAMES = NAMES

local function say(text)
    if ann and text and text ~= "" then ann.speak(text, true) end
end

local function lib()
    return C.lib("UIFightBPLib")
end

-- Reading the fight ----------------------------------------------------------

local looks_a, looks_b, looks_c = {}, {}, {}

local function pl_type(L, team, member)
    -- three out-parameters; UE4SS fills the first table with all of them
    local a, b, c = C.scratch(looks_a), C.scratch(looks_b), C.scratch(looks_c)
    local ok = pcall(function() L:GetPlayerLooksInfo(team, member, a, b, c) end)
    if not ok then return nil end
    local id = a.PlType
    if type(id) ~= "number" or id < 0 or id >= 250 then return nil end
    return id
end

local function name_of(id)
    if not id then return "unknown fighter" end
    return NAMES[id] or ("fighter " .. id)
end

-- Snapshot of both teams, or nil while the fight has no data yet.
local function snapshot()
    local L = lib()
    if not L then return nil end
    local s = { team = {} }
    for team = 0, 1 do
        local t = { life = {}, id = {} }
        for member = 0, 1 do
            t.life[member] = C.call(L, "GetPlLifeRateForEach", team, member)
            t.id[member] = pl_type(L, team, member)
        end
        if type(t.life[0]) ~= "number" or type(t.life[1]) ~= "number" then return nil end
        t.point = C.call(L, "GetMasterCharacterNo", team)
        if t.point ~= 0 and t.point ~= 1 then t.point = 0 end
        t.bars = C.call(L, "GetGaugeLv", team)
        t.bar_fill = C.call(L, "GetGaugeValueRate", team)
        t.wins = C.call(L, "GetWinCount", team)
        s.team[team] = t
    end
    s.timer = C.call(L, "GetTimer")
    s.endless = C.call(L, "IsTimerInf") == true
    return s
end

local function pct(x)
    if type(x) ~= "number" then return "unknown" end
    return tostring(math.floor(x * 100 + 0.5))
end

-- Events ---------------------------------------------------------------------

local st = nil -- per-fight state, nil outside a fight

local function new_state()
    return {
        announced = false,              -- the line-up has been spoken
        alive = { [0] = { [0] = false, [1] = false }, [1] = { [0] = false, [1] = false } },
        -- health band of each fighter, by team and member
        band = { [0] = { [0] = 3, [1] = 3 }, [1] = { [0] = 3, [1] = 3 } },
        had = { [0] = false, [1] = false }, -- the team has had health this fight
        had_life = false,               -- both teams have: the fight is really on
        over = false,
        loser = nil,                    -- 0, 1, or -1 for a double knock-out
        over_clock = nil,               -- the clock when it ended on time
        wins0 = nil,                    -- the game's round-win counts at the start
        flow = nil,                     -- which fight this state belongs to
        bars = nil,
        clock = nil,
    }
end

local function lineup(s)
    local a, b = s.team[0], s.team[1]
    if not (a.id[0] and b.id[0]) then return nil end
    local function side(t)
        if t.id[1] and t.id[1] ~= t.id[0] then
            return name_of(t.id[0]) .. " and " .. name_of(t.id[1])
        end
        return name_of(t.id[0])
    end
    return side(a) .. ", versus " .. side(b) .. "."
end

-- 3 = above half, 2 = half or less, 1 = a quarter or less
local function band_of(x)
    if x <= 0.25 then return 1 end
    if x <= 0.5 then return 2 end
    return 3
end

local function who(team)
    return team == 0 and "You" or "Opponent"
end

local function events(s)
    local out = {}
    if not st.announced then
        local l = lineup(s)
        if l then
            st.announced = true
            out[#out + 1] = l
        end
    end
    -- Health bars fill up during the intro, so a fighter only counts as "in
    -- the fight" once it has been seen alive. That stops the empty bars of the
    -- intro from reading as four knock-outs.
    for team = 0, 1 do
        local t = s.team[team]
        for member = 0, 1 do
            local life = t.life[member]
            if life > 0 then
                st.alive[team][member] = true
            elseif st.alive[team][member] then
                st.alive[team][member] = false
                out[#out + 1] = (team == 0 and "Your " or "Their ") .. name_of(t.id[member]) .. " is down."
            end
        end
        -- Health warnings name the fighter on point, and each fighter keeps
        -- its own band, so a fresh partner switching in is not mistaken for the
        -- same fighter dropping to half again.
        local p = t.point
        local point_life = t.life[p]
        if point_life > 0 then
            local band = band_of(point_life)
            if band < st.band[team][p] then
                out[#out + 1] = (team == 0 and "Your " or "Their ") .. name_of(t.id[p]) ..
                    (band == 1 and ": low health." or ": half health.")
            end
            st.band[team][p] = band
        end
    end
    -- A team has lost when it has had health in this fight and now has none.
    local down = {}
    for team = 0, 1 do
        local t = s.team[team]
        if t.life[0] > 0 or t.life[1] > 0 then
            st.had[team] = true
        elseif st.had[team] then
            down[team] = true
        end
    end
    st.had_life = st.had[0] and st.had[1]
    if not st.over and (down[0] or down[1]) then
        st.over = true
        if down[0] and down[1] then
            st.loser = -1
            out[#out + 1] = "Double knock out."
        else
            st.loser = down[0] and 0 or 1
            out[#out + 1] = down[0] and "You lose." or "You win."
        end
    end
    -- A fight that ends on the clock: the game's own count of rounds won.
    local w0, w1 = s.team[0].wins, s.team[1].wins
    if type(w0) == "number" and type(w1) == "number" then
        if not st.wins0 then
            st.wins0 = { [0] = w0, [1] = w1 }
        elseif not st.over and (w0 > st.wins0[0] or w1 > st.wins0[1]) then
            st.over = true
            st.over_clock = type(s.timer) == "number" and s.timer or 0
            if w0 > st.wins0[0] and w1 > st.wins0[1] then
                out[#out + 1] = "Draw."
            elseif w0 > st.wins0[0] then
                out[#out + 1] = "You win."
            else
                out[#out + 1] = "You lose."
            end
        end
    end
    if st.over then
        -- the intro of a rematch empties the bars again: not knock-outs
        for team = 0, 1 do st.alive[team][0], st.alive[team][1] = false, false end
    end
    -- A new bar of Hyper Combo meter for you.
    -- (The starting meter is handed out as the fight opens, which can be long
    -- after the intro if a tutorial tip is holding the game. So gains only
    -- count once somebody has actually been hit or has built some meter.)
    if not st.under_way and st.had_life then
        for team = 0, 1 do
            local t = s.team[team]
            if t.life[0] < 0.999 or t.life[1] < 0.999
                or (type(t.bar_fill) == "number" and t.bar_fill > 0.02) then
                st.under_way = true
            end
        end
    end
    local bars = s.team[0].bars
    if type(bars) == "number" then
        if st.bars and bars > st.bars and st.under_way and not st.over then
            out[#out + 1] = bars .. (bars == 1 and " bar." or " bars.")
        end
        st.bars = bars
    end
    -- The clock, at thirty and ten, and when it runs out.
    if not s.endless and type(s.timer) == "number" and st.had_life then
        for _, mark in ipairs({ 30, 10 }) do
            if not st.over and st.clock and st.clock > mark and s.timer <= mark and s.timer > 0 then
                out[#out + 1] = mark .. " seconds."
            end
        end
        if st.clock and st.clock > 0 and s.timer <= 0 then
            table.insert(out, 1, "Time.")
            st.over_clock = st.over_clock or 0
        end
        st.clock = s.timer
    end
    return out
end

-- Called every tick while a fight flow is active. Never claims the screen: a
-- pause menu or a dialog over the fight belongs to the menu reader.
-- Is this the start of another fight on the same flow (a rematch, or the
-- next Arcade battle)? A knocked-out team has health again, or a fight that
-- ended on the clock has a full clock again.
local function started_again(s)
    if not st.over then return false end
    local l = st.loser
    if l == 0 or l == 1 then
        local t = s.team[l]
        if t.life[0] > 0 or t.life[1] > 0 then return true end
    elseif l == -1 then
        if s.team[0].life[0] > 0 or s.team[1].life[0] > 0 then return true end
    end
    if st.over_clock and type(s.timer) == "number" and s.timer > st.over_clock + 5 then
        return true
    end
    return false
end

function M.announce_now(_force)
    if not C.in_fight() then
        st = nil
        return false
    end
    local s = snapshot()
    if not s then return false end
    local flow = C.fname(C.flow())
    if not st or st.flow ~= flow or started_again(s) then
        st = new_state()
        st.flow = flow
    end
    local out = events(s)
    -- queued, not interrupting: two events a moment apart should both be heard
    if #out > 0 and ann then ann.speak(table.concat(out, " "), false) end
    return false
end

-- Forget the fight (main.lua calls this whenever no fight is on).
function M.reset()
    st = nil
end

-- On-demand reports (hotkeys) -------------------------------------------------

local function team_health(s, team)
    local t = s.team[team]
    local p, o = t.point, 1 - t.point
    local line = who(team) .. ": " .. name_of(t.id[p]) .. " " .. pct(t.life[p]) .. " percent"
    if t.id[o] and t.id[o] ~= t.id[p] then
        if t.life[o] <= 0 then
            line = line .. ", " .. name_of(t.id[o]) .. " down"
        else
            line = line .. ", " .. name_of(t.id[o]) .. " " .. pct(t.life[o])
        end
    end
    return line .. "."
end

local function team_meter(s, team)
    local t = s.team[team]
    if type(t.bars) ~= "number" then return who(team) .. ": meter unknown." end
    local line = who(team) .. ": " .. t.bars .. (t.bars == 1 and " bar" or " bars")
    if type(t.bar_fill) == "number" and t.bar_fill > 0.005 then
        line = line .. " and " .. pct(t.bar_fill) .. " percent"
    end
    return line .. "."
end

local pos_scratch, right_scratch = {}, {}

local function positions()
    local L = lib()
    if not L then return nil end
    -- Where a team's fighter ON POINT stands. Measured in a fight with a switch:
    -- GetPlayerPosFight(team, out pos, out flgRight, member) answers for the
    -- fighter on point whatever member is asked for (UE4SS drops an argument
    -- that follows a non-struct out-parameter, and the game seems to fall back
    -- to the active fighter), while GetPlayerWaistPosFight follows a fixed slot
    -- and kept reporting a fighter who had already switched out.
    local function x_of(team)
        local pos, right = C.scratch(pos_scratch), C.scratch(right_scratch)
        if not pcall(function() L:GetPlayerPosFight(team, pos, right, 0) end) then return nil end
        return type(pos.X) == "number" and pos.X or nil
    end
    local s = snapshot()
    if not s then return nil end
    local mine, theirs = x_of(0), x_of(1)
    if not (mine and theirs) then return nil end
    local gap = math.abs(theirs - mine)
    local range = gap < 180 and "close" or (gap < 450 and "mid range" or "far")
    local side = theirs >= mine and "to your right" or "to your left"
    return "Opponent " .. side .. ", " .. range .. "."
end

-- kind: "health", "meter", "time", "where". Speaks, and says so outside a fight.
function M.report(kind)
    if not C.in_fight() then
        say("Not in a fight.")
        return
    end
    local s = snapshot()
    if not s then
        say("No fight data yet.")
        return
    end
    if kind == "health" then
        say(team_health(s, 0) .. " " .. team_health(s, 1))
    elseif kind == "meter" then
        say(team_meter(s, 0) .. " " .. team_meter(s, 1))
    elseif kind == "time" then
        if s.endless then
            say("No time limit.")
        elseif type(s.timer) == "number" then
            say(s.timer .. " seconds.")
        else
            say("Time unknown.")
        end
    elseif kind == "where" then
        say(positions() or "Positions unknown.")
    end
end

function M.init(announcer)
    ann = announcer
    return M
end

return M
