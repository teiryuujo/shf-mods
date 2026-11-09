--[[
    game.texts  —  dialog texts in the game's current language (falls back to English).
--]]
local Util  = require("core.util")
local Const = require("game.const")

local TEXTS = {
    ru = { use = "Инвентарь полон.\nИспользовать «%s» сейчас?" },
    en = { use = "Inventory is full.\nUse %s right now?" },
    ja = { use = "持ち物がいっぱいです。\n「%s」を今使いますか？" },
    de = { use = "Inventar ist voll.\n%s jetzt benutzen?" },
    fr = { use = "Inventaire plein.\nUtiliser %s maintenant ?" },
    es = { use = "Inventario lleno.\n¿Usar %s ahora?" },
    it = { use = "Inventario pieno.\nUsare %s adesso?" },
    pl = { use = "Ekwipunek pełny.\nUżyć %s teraz?" },
    pt = { use = "Inventário cheio.\nUsar %s agora?" },
    ko = { use = "소지품이 가득 찼습니다.\n%s을(를) 지금 사용할까요?" },
    zh = { use = "物品栏已满。\n现在使用“%s”？" },
}

local M = {}

local function language()
    local lang = Util.try(function()
        return StaticFindObject(Const.I18N_FUNCLIB):GetCurrentLanguage():ToString()
    end) or "en"
    return string.lower(string.sub(lang, 1, 2))
end

function M.get(key, ...)
    local t = TEXTS[language()] or TEXTS.en
    return string.format(t[key] or TEXTS.en[key], ...)
end

return M
