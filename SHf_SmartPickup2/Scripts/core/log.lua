--[[
    core.log  —  console logger with a prefix and a debug switch.
    Output goes through print(), which UE4SS writes to its console and UE4SS.log.
--]]
local M = { prefix = "[mod]", debug = false }

function M.configure(opts)
    if opts.prefix ~= nil then M.prefix = opts.prefix end
    if opts.debug  ~= nil then M.debug  = opts.debug end
end

local function emit(level, fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then text = tostring(fmt) .. " (format error: " .. tostring(text) .. ")" end
    print(M.prefix .. (level and (" " .. level) or "") .. " " .. text .. "\n")
end

function M.info(fmt, ...) emit(nil, fmt, ...) end
function M.warn(fmt, ...) emit("WARN", fmt, ...) end
function M.dbg(fmt, ...)
    if M.debug then emit("dbg", fmt, ...) end
end

return M
