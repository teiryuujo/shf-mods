--[[
    probe.hooks  —  declarative hook registry.

    A target is a plain table:
        {
            fn     = "/Script/Pkg.Class:Function",   -- full UFunction path (required)
            tag    = "label",                         -- short group name shown in the log
            params = { "A", "B" },                    -- parameter names in UFunction order (optional)
            only   = { "substr", ... },               -- log only when self:GetFullName() contains one of these
            extra  = function(self, phase) ... end,   -- returns an additional line to log (optional)
        }

    Both the pre and the post callback are always registered. Which of them the runtime actually
    fires, and whether "pre" runs before the body, is exactly what the log is meant to show.
    Hooks that cannot be registered yet (Blueprint class not loaded) are retried on a timer.
--]]
local Log     = require("probe.log")
local Inspect = require("probe.inspect")

local M = {}

local pending = {}   -- targets not hooked yet
local hooked  = {}   -- fn -> true

local function matches(self, only)
    if not only then return true end
    local full = Inspect.try(function() return self:GetFullName() end) or ""
    for _, s in ipairs(only) do
        if full:find(s, 1, true) then return true end
    end
    return false
end

--- "Name=value Name=value ..." for the hook's variadic parameters.
--- Measured on UE4SS 3.0.1: a post callback receives the return value FIRST, then the parameters.
local function formatArgs(target, phase, ...)
    local n = select("#", ...)
    local names = target.params or {}
    local shift = (phase == "post" and n > #names) and 1 or 0
    local parts = {}
    for i = 1, n do
        local p = select(i, ...)
        local v = Inspect.try(function() return p:get() end)
        local name
        if shift == 1 and i == 1 then name = "ReturnValue"
        else name = names[i - shift] or ("p" .. i) end
        parts[#parts + 1] = name .. "=" .. Inspect.describe(v)
    end
    return table.concat(parts, " ")
end

local function makeCallback(target, phase)
    return function(ctx, ...)
        local self = Inspect.try(function() return ctx:get() end)
        -- an object that is not alive must not be described (access violation inside UE4SS, 2026-10-28)
        if self ~= nil and not Inspect.valid(self) then return end
        if not matches(self, target.only) then return end
        Log.line("%-4s [%s] %s | self=%s | %s",
            phase:upper(), target.tag or "-", target.fn, Inspect.describe(self), formatArgs(target, phase, ...))
        if target.extra then
            local ok, extra = pcall(target.extra, self, phase)
            if ok and extra then
                Log.line("       %s", tostring(extra))
            elseif not ok then
                Log.line("       extra failed: %s", tostring(extra))
            end
        end
    end
end

function M.add(target)
    assert(type(target.fn) == "string", "hook target needs a fn path")
    pending[#pending + 1] = target
end

--- Tries to register every pending hook. Returns how many are still pending.
function M.flush()
    local rest = {}
    for _, target in ipairs(pending) do
        local ok, err = pcall(RegisterHook, target.fn, makeCallback(target, "pre"), makeCallback(target, "post"))
        if ok then
            hooked[target.fn] = true
            Log.line("hooked %s", target.fn)
        else
            target.lastError = tostring(err)
            rest[#rest + 1] = target
        end
    end
    pending = rest
    return #pending
end

--- Registers what it can now and keeps retrying the rest every `retryMs` up to `maxTries` times.
function M.start(retryMs, maxTries)
    if M.flush() == 0 then
        Log.line("all hooks registered")
        return
    end
    Log.line("%d hook(s) pending, retrying every %d ms", #pending, retryMs)
    local tries = 0
    LoopAsync(retryMs, function()
        tries = tries + 1
        if #pending == 0 then return true end
        if tries > maxTries then
            ExecuteInGameThread(function()
                for _, t in ipairs(pending) do Log.line("GAVE UP hooking %s: %s", t.fn, t.lastError or "?") end
            end)
            return true
        end
        ExecuteInGameThread(function()
            if M.flush() == 0 then Log.line("all hooks registered") end
        end)
        return false
    end)
end

--- Logs which targets are hooked and which are still pending.
function M.report()
    local n = 0
    for _ in pairs(hooked) do n = n + 1 end
    Log.line("hooks: %d registered, %d pending", n, #pending)
    for _, t in ipairs(pending) do Log.line("  pending %s (%s)", t.fn, t.lastError or "?") end
end

return M
