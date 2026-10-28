--[[
    probe.log  —  minimal structured logger.

    Every line gets a sequence number and a timestamp (seconds since the mod loaded, ms precision),
    goes to the UE4SS console via print() and, when a file could be opened, is appended to it.
    The sequence number is what makes call order unambiguous when several hooks fire in one frame.
--]]
local M = {}

local PREFIX = "[SHf_Probe]"
local startClock = os.clock()
local seq = 0
local file = nil

local function stamp()
    seq = seq + 1
    return string.format("%s #%05d %9.3fs", PREFIX, seq, os.clock() - startClock)
end

--- Opens (appends to) the log file. Returns true on success; logging works without it.
function M.open(path)
    local f = io.open(path, "a")
    if not f then return false end
    file = f
    f:write(string.format("\n===== session %s =====\n", os.date("%Y-%m-%d %H:%M:%S")))
    f:flush()
    return true
end

--- Logs one formatted line. A bad format never raises: the raw text is logged instead.
function M.line(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then text = tostring(fmt) .. " (format error: " .. tostring(text) .. ")" end
    local full = stamp() .. " " .. text
    print(full .. "\n")
    if file then
        file:write(full, "\n")
        file:flush()
    end
end

function M.section(title)
    M.line("---------- %s ----------", title)
end

return M
