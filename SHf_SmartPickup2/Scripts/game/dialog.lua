--[[
    game.dialog  —  a Yes/No question on the game's own pop-up (WBP_PopWindow, UNocePopWindowWidget).

    Measured widget events (all fire with real pre/post for WBP_PopWindow_C):
        NoceFocusableWidget:Confirm      the player confirmed; List.SelectingIndex 0 = first button (Yes)
        NoceFocusableWidget:Cancel       the player backed out
        NoceAnimWidget:OnFadeInCompleted the widget is on screen
        NoceAnimWidget:OnFadeOutCompleted the fade-out is over: this is when the widget restores the
                                         pause / input mode it cached, so only now is it safe to open
                                         the next UI (opening earlier made the next UI cache "paused").
    The answer is delivered after OnFadeOutCompleted, one short step later so the widget is gone.
    One dialog at a time; ask() returns false when it cannot be shown (caller decides what to do).
--]]
local UEHelpers = require("UEHelpers")
local Log   = require("core.log")
local Util  = require("core.util")
local Hooks = require("core.hooks")
local Const = require("game.const")
local Spawn = require("game.spawn")

local M = {}

local POPUP_ONLY       = { "WBP_PopWindow_C" }
local SHOW_TIMEOUT_MS  = 3000   -- no fade-in within this time = the widget never appeared
local AFTER_FADE_MS    = 100    -- step between the fade-out event and the answer callback

local active = nil   -- { widget, address, result, cb, shown, finished }
local hooksInstalled = false
local fadeOutWaiters = {}   -- widget address -> fn, one-shot

local typeCache = {}
--- ENoceUIPopWindowType::<Name> as a number (read from the enum, falls back to the dumped order).
local function popTypeValue(name)
    if typeCache[name] then return typeCache[name] end
    local fallback = { Invalid = 0, Yes = 1, YesNoDefaultY = 2, YesNoDefaultN = 3, Custom = 4 }
    local value = fallback[name]
    Util.try(function()
        local enum = StaticFindObject(Const.POPWINDOW_TYPE_ENUM)
        if Util.valid(enum) then
            enum:ForEachName(function(fname, v)
                local n = fname:ToString()
                if n == name or n == "ENoceUIPopWindowType::" .. name then value = v end
            end)
        end
    end)
    typeCache[name] = value
    return value
end

local function isActive(self)
    return active ~= nil and Util.try(function() return self:GetAddress() end) == active.address
end

local function finish(reason)
    local d = active
    if not d or d.finished then return end
    d.finished = true
    active = nil
    local yes = d.result == true
    Log.dbg("Dialog closed (%s) -> %s", reason, yes and "Yes" or "No")
    Util.later(AFTER_FADE_MS, function() pcall(d.cb, yes) end)
end

local function onConfirm(self)
    if not isActive(self) then return end
    local idx = Util.try(function() return self.List.SelectingIndex end)
    if idx == nil or idx < 0 then idx = Util.try(function() return self.LastSelectedIndex end, -1) end
    active.result = (idx == 0)
    Log.dbg("Dialog Confirm, selected index %s", tostring(idx))
end

local function onCancel(self)
    if not isActive(self) then return end
    active.result = false
    Log.dbg("Dialog Cancel")
end

local function onFadeIn(self)
    if isActive(self) then active.shown = true end
end

local function onFadeOut(self)
    local addr = Util.try(function() return self:GetAddress() end)
    local waiter = addr and fadeOutWaiters[addr]
    if waiter then
        fadeOutWaiters[addr] = nil
        Util.later(AFTER_FADE_MS, function() pcall(waiter) end)
    end
    if isActive(self) then finish("fade-out") end
end

local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    Hooks.on(Const.WIDGET_CONFIRM_FN,  { pre = onConfirm, only = POPUP_ONLY })
    Hooks.on(Const.WIDGET_CANCEL_FN,   { pre = onCancel,  only = POPUP_ONLY })
    Hooks.on(Const.WIDGET_FADE_IN_FN,  { pre = onFadeIn,  only = POPUP_ONLY })
    -- fade-out fires for every NoceAnimWidget (HUD prompts included): limit it to the two we wait for
    Hooks.on(Const.WIDGET_FADE_OUT_FN, { post = onFadeOut, only = { "WBP_PopWindow_C", "WBP_ReplaceItem_C" } })
end

--- Registers the widget hooks now (call from a feature's install, before any dialog is needed).
function M.prepare()
    installHooks()
end

--- True while a question is on screen (or fading out).
function M.isOpen()
    return active ~= nil
end

--- Calls fn once the given widget has finished fading out (used to chain UI after a game dialog).
function M.onceFadedOut(widget, fn)
    installHooks()
    local addr = Util.try(function() return widget:GetAddress() end)
    if not addr then return false end
    fadeOutWaiters[addr] = fn
    return true
end

--- Shows "text" with Yes/No (default No) and calls cb(true|false) once the pop-up is gone.
--- Returns false if the dialog could not be created or one is already open.
function M.ask(worldContext, text, cb)
    installHooks()
    if active then Log.dbg("Dialog: one is already open"); return false end
    local cls = Spawn.loadClass(Const.POPWINDOW_CLASS)
    if not cls then return false end
    local pc  = UEHelpers.GetPlayerController()
    local wbl = StaticFindObject(Const.WIDGET_BP_FUNCLIB)
    if not Util.valid(pc) or not Util.valid(wbl) then return false end

    local w = Util.try(function() return wbl:Create(worldContext, cls, pc) end)
    if not Util.valid(w) then Log.warn("Dialog: could not create the pop window"); return false end

    local ok, err = pcall(function()
        w:SetType(popTypeValue("YesNoDefaultN"))
        w:SetDialog(FText(text))
        w:SetDefaultIndex(1)
        -- same flags as the game's own replace windows: pause + UI input mode
        w.NeedPauseGame = true
        w.NeedSetUIGameMode = true
    end)
    if not ok then Log.warn("Dialog: setup failed: %s", tostring(err)); return false end

    active = { widget = w, address = w:GetAddress(), cb = cb, result = nil, shown = false, finished = false }
    ok, err = pcall(function() w:Show() end)
    if not ok then
        Log.warn("Dialog: Show() failed: %s", tostring(err))
        active = nil
        return false
    end
    Log.dbg("Dialog shown: %s", (text:gsub("\n", " ")))

    local d = active
    Util.later(SHOW_TIMEOUT_MS, function()
        if active == d and not d.shown then
            Log.warn("Dialog never appeared, treating it as No")
            finish("timeout")
        end
    end)
    return true
end

return M
