--[[
    core.hooks  —  one RegisterHook per function, any number of handlers behind it.

        Hooks.on("/Script/Pkg.Class:Function", {
            pre  = function(self, ...) end,   -- `self` is already unwrapped; `...` are RemoteUnrealParam
            post = function(self, ...) end,   -- post receives the return value FIRST, then the params
            only = { "substr", ... },         -- optional: run only when self:GetFullName() contains one
        })

    Remember (measured in this game): Blueprint functions fire only `pre`, and it runs after the body.
    Handler errors are caught and logged so one broken feature cannot break the others.
    Functions whose class is not loaded yet are retried on a timer (Hooks.start).
--]]
local Log  = require("core.log")
local Util = require("core.util")

local M = {}

local entries = {}   -- fn -> { registered = bool, handlers = {...}, lastError = string|nil }
local order   = {}   -- fn paths in insertion order
local started = false   -- once start() ran, later Hooks.on calls register immediately

local function matches(self, only)
    if not only then return true end
    local full = Util.try(function() return self:GetFullName() end) or ""
    for _, s in ipairs(only) do
        if full:find(s, 1, true) then return true end
    end
    return false
end

local function dispatcher(fn, phase)
    return function(ctx, ...)
        local self = Util.try(function() return ctx:get() end)
        -- Two crashes (2026-10-27/28) died inside a Lua hook callback reached from the same game call
        -- path, with an access violation on object access. A pcall cannot catch that. IsValid() only
        -- consults the object array, so it is the one check that is safe on a dying object: skip
        -- everything else for an object that is not alive. (Static functions pass their CDO: valid.)
        if self ~= nil and not Util.valid(self) then return end
        for _, h in ipairs(entries[fn].handlers) do
            local cb = h[phase]
            if cb and matches(self, h.only) then
                local ok, err = pcall(cb, self, ...)
                if not ok then Log.warn("%s handler of %s failed: %s", phase, fn, tostring(err)) end
            end
        end
    end
end

function M.on(fn, handler)
    assert(type(fn) == "string", "Hooks.on: function path expected")
    assert(type(handler) == "table" and (handler.pre or handler.post), "Hooks.on: pre and/or post handler expected")
    local e = entries[fn]
    if not e then
        e = { registered = false, handlers = {} }
        entries[fn] = e
        order[#order + 1] = fn
    end
    e.handlers[#e.handlers + 1] = handler
    -- a hook added after start() (e.g. by a module that is set up lazily) must not wait for a
    -- retry loop that has already finished
    if started and not e.registered then M.flush() end
end

--- Registers every function that is not hooked yet. Returns how many are still missing.
function M.flush()
    local missing = 0
    for _, fn in ipairs(order) do
        local e = entries[fn]
        if not e.registered then
            local ok, err = pcall(RegisterHook, fn, dispatcher(fn, "pre"), dispatcher(fn, "post"))
            if ok then
                e.registered = true
                Log.dbg("hooked %s", fn)
            else
                e.lastError = tostring(err)
                missing = missing + 1
            end
        end
    end
    return missing
end

--- Hooks what it can now and retries the rest every `retryMs`, at most `maxTries` times.
function M.start(retryMs, maxTries)
    started = true
    if M.flush() == 0 then
        Log.info("all %d hooks registered", #order)
        return
    end
    -- RegisterHook is called on the game thread; the async loop only schedules it and stops once
    -- a game-thread pass has reported completion (or the retry budget is spent).
    local tries, finished = 0, false
    LoopAsync(retryMs, function()
        if finished then return true end
        tries = tries + 1
        ExecuteInGameThread(function()
            if finished then return end
            if M.flush() == 0 then
                Log.info("all %d hooks registered", #order)
                finished = true
            elseif tries >= maxTries then
                M.report()
                finished = true
            end
        end)
        return false
    end)
end

function M.report()
    for _, fn in ipairs(order) do
        local e = entries[fn]
        if not e.registered then Log.warn("hook NOT registered: %s (%s)", fn, e.lastError or "?") end
    end
end

return M
