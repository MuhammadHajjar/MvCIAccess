-- announcer.lua
-- Shared speech/output layer for MvCIAccess.
-- Two outputs:
--   1) File bridge (ALWAYS on): writes the latest line to announce_last.txt and
--      appends every line to announce_log.txt (so the reading logic can be
--      checked from the log), and writes speech.txt for the speech companion.
--   2) Native speech backend (OPTIONAL): if a Lua-loadable speech module exists
--      (see speech.lua), route text to it. Absent for now -> file-bridge only.
-- No fancy punctuation in string literals (ANSI-read mangles em dashes).
--
-- speech.txt holds ONE utterance: "<sequence>\n<1|0 interrupt>\n<text>\n". The
-- companion looks at it every 30 ms and speaks when the sequence changes, so two
-- writes a few milliseconds apart lose the first. Readers can speak more than
-- once in a tick (a fight event and a mission task, say), so main.lua brackets
-- each tick with begin_batch() / flush() and the tick's lines go out as one
-- write.

local M = {}

local P = require("paths")
local LAST_PATH   = P.last
local LOG_PATH    = P.log
local SPEECH_PATH = P.speech   -- IPC for the speech companion

local last_text = nil
local backend   = nil       -- table with .speak(text, interrupt) and .name
local seq       = 0         -- monotonically increasing; companion speaks on change

local batching = false
local pending_text, pending_interrupt = nil, false

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

-- Hand one utterance to the companion (and the native backend, if any).
local function emit(text, interrupt)
    seq = seq + 1
    write_file(SPEECH_PATH, "w", seq .. "\n" .. (interrupt and "1" or "0") .. "\n" .. text .. "\n")
    if backend then
        pcall(function() backend.speak(text, interrupt) end)
    end
end

-- Speak/announce a line.
--   text:      string to announce
--   interrupt: true (default) cuts off current speech; false queues behind it.
-- Callers do their own change detection; nothing is filtered here.
function M.speak(text, interrupt)
    if text == nil then return end
    text = tostring(text)
    if text == "" then return end
    local cut = (interrupt ~= false)
    last_text = text

    write_file(LAST_PATH, "w", text .. "\n")
    write_file(LOG_PATH, "a", os.date("%H:%M:%S") .. "  " .. text .. "\n")
    print("[MvCIAccess][say] " .. text)

    if not batching then
        emit(text, cut)
    elseif cut or not pending_text then
        -- an interrupting line would cut whatever was queued before it anyway
        pending_text, pending_interrupt = text, cut
    else
        pending_text = pending_text .. " " .. text
    end
end

-- Collect everything spoken until flush() into one utterance.
function M.begin_batch()
    batching = true
    pending_text, pending_interrupt = nil, false
end

function M.flush()
    batching = false
    if pending_text then
        local t, cut = pending_text, pending_interrupt
        pending_text = nil
        emit(t, cut)
    end
end

function M.repeat_last()
    if last_text then M.speak(last_text, true) end
end

return M
