-- announcer.lua
-- Shared speech/output layer for MvCIAccess.
-- Every screen handler hands (name, value, tooltip) style text here.
-- Two outputs:
--   1) File bridge (ALWAYS on): writes the latest line to announce_last.txt and
--      appends to announce_log.txt so we can verify menu-reading logic with NVDA
--      (or from the log) before a native speech backend is wired.
--   2) Native speech backend (OPTIONAL): if a Lua-loadable speech module exists
--      (see speech.lua), route text to it. Absent for now -> file-bridge only.
-- No fancy punctuation in string literals (ANSI-read mangles em dashes).

local M = {}

local P = require("paths")
local LAST_PATH   = P.last
local LOG_PATH    = P.log
local SPEECH_PATH = P.speech   -- IPC for the speech companion

local last_text = nil
local backend   = nil       -- table with .speak(text, interrupt) and .name
local seq       = 0         -- monotonically increasing; companion speaks on change

local function write_file(path, mode, s)
    local ok, f = pcall(io.open, path, mode)
    if ok and f then
        f:write(s)
        f:close()
    end
end

function M.init()
    -- Seed the speech sequence from the clock so a fresh game launch never reuses
    -- a number the still-running companion already spoke.
    seq = os.time() % 1000000
    -- Try to load an optional native speech backend. It is fine for this to fail;
    -- the file bridge keeps working so the rest of the mod is testable.
    local ok, mod = pcall(require, "speech")
    if ok and type(mod) == "table" and mod.available and mod.available() then
        backend = mod
        M.backend_name = mod.name or "native"
    else
        backend = nil
        M.backend_name = "file-bridge"
    end
    write_file(LOG_PATH, "w",
        "=== MvCIAccess announce log  started " .. os.date("%Y-%m-%d %H:%M:%S") ..
        "  backend=" .. M.backend_name .. " ===\n")
    return M
end

-- Speak/announce a line.
--   text:      string to announce
--   interrupt: true (default) cuts off current speech; false lets it queue and
--              also suppresses exact-duplicate repeats (used for polled reads).
function M.speak(text, interrupt)
    if text == nil then return end
    text = tostring(text)
    if text == "" then return end
    if interrupt == false and text == last_text then
        return -- dedupe repeated polled reads
    end
    last_text = text

    -- 1) file bridge (always)
    write_file(LAST_PATH, "w", text .. "\n")
    write_file(LOG_PATH, "a", os.date("%H:%M:%S") .. "  " .. text .. "\n")
    -- speech pipe for the Python companion: seq / interrupt / text
    seq = seq + 1
    write_file(SPEECH_PATH, "w", seq .. "\n" .. ((interrupt ~= false) and "1" or "0") .. "\n" .. text .. "\n")
    print("[MvCIAccess][say] " .. text)

    -- 2) native speech (when available)
    if backend then
        pcall(function() backend.speak(text, interrupt ~= false) end)
    end
end

function M.repeat_last()
    if last_text then
        -- force through even though it equals last_text
        local t = last_text
        last_text = nil
        M.speak(t, true)
    end
end

return M
