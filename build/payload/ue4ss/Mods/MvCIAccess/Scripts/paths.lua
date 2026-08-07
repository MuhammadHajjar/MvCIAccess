-- paths.lua
-- Every file the mod writes lives in one per-user folder. LOCALAPPDATA is always
-- writable, unlike the game directory (which is usually under Program Files and
-- needs admin rights).

local M = {}

local base = os.getenv("LOCALAPPDATA")
if base and base ~= "" then
    base = base .. "\\MvCIAccess"
else
    -- extremely unlikely fallback
    base = (os.getenv("USERPROFILE") or ".") .. "\\MvCIAccess"
end

-- Create the folder if it does not exist yet (harmless if it does).
pcall(function() os.execute('mkdir "' .. base .. '" >nul 2>nul') end)

M.dir = base

function M.file(name)
    return base .. "\\" .. name
end

-- The files the mod uses.
M.speech    = M.file("speech.txt")        -- IPC to the speech companion
M.last      = M.file("announce_last.txt") -- last spoken line (handy for support)
M.log       = M.file("announce_log.txt")
M.errors    = M.file("errors.txt")
M.charnames = M.file("charnames.txt")     -- optional name overrides
M.cmd       = M.file("inspector_cmd.txt") -- development inspector
M.out       = M.file("inspector_out.txt")
M.history   = M.file("inspector_history.txt")

return M
