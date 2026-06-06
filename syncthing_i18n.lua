-- syncthing_i18n.lua -	Gettext loader for the plugin’s own locale domain
local logger = require("logger")
local _dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")

-- PO string unescape: handles \n \t \r \\ \" sequences.
-- ffi/util does not expose an unescape helper in all KOReader builds,
-- so we implement it locally to avoid a nil-call crash on load.
local _esc = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"' }
local function unescape(s)
    if not s or s == "" then return s end
    return (s:gsub("\\(.)", function(c) return _esc[c] or c end))
end

---------------------------------------------------------------------------
-- PO file parser
---------------------------------------------------------------------------
local function parsePO(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil end

    local map = {}

    local msgid         = nil
    local msgid_plural  = nil
    local msgstr        = nil
    local in_id         = false
    local in_plural     = false
    local in_str        = false
    local in_str_plural = false
    local want_idx_zero = false

    local function flush()
        if msgid and msgid ~= "" and msgstr and msgstr ~= "" then
            map[msgid] = msgstr
        end
        msgid         = nil
        msgid_plural  = nil
        msgstr        = nil
        in_id         = false
        in_plural     = false
        in_str        = false
        in_str_plural = false
        want_idx_zero = false
    end

    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line == "" or line:match("^#") then
            -- nothing
        elseif line:match("^msgctxt%s+") then
            -- We don't preserve msgctxt as a separate key (the plugin
            -- doesn't use disambiguated translations), but we DO need
            -- to flush any in-progress entry so the next msgid starts
            -- a fresh record.  The `want_idx_zero = true` assignment
            -- below is a no-op for the msgctxt path itself — it's
            -- always overwritten by the upcoming msgid or msgstr —
            -- but we keep it as a documented default to make the
            -- state-machine reset complete.
            flush()
            want_idx_zero = true
        elseif line:match("^msgid%s+") then
            flush()
            msgid = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id         = true
            in_plural     = false
            in_str        = false
            in_str_plural = false
            want_idx_zero = false
        elseif line:match("^msgid_plural%s+") then
            msgid_plural = unescape(line:match('^msgid_plural%s+"(.*)"') or "")
            in_id         = false
            in_plural     = true
            in_str        = false
            in_str_plural = false
        elseif line:match("^msgstr%[") then
            local idx = tonumber(line:match("^msgstr%[(%d+)%]"))
            in_id         = false
            in_plural     = false
            in_str        = false
            in_str_plural = true
            if idx == 0 then
                msgstr        = unescape(line:match('^msgstr%[%d+%]%s+"(.*)"') or "")
                want_idx_zero = true
            else
                want_idx_zero = false
            end
        elseif line:match("^msgstr%s+") then
            msgstr = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_id         = false
            in_plural     = false
            in_str        = true
            in_str_plural = false
            want_idx_zero = false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_id and msgid then
                msgid = msgid .. cont
            elseif in_plural and msgid_plural then
                msgid_plural = msgid_plural .. cont
            elseif in_str and msgstr then
                msgstr = msgstr .. cont
            elseif in_str_plural and want_idx_zero and msgstr then
                msgstr = msgstr .. cont
            end
        end
    end

    flush()
    f:close()
    return next(map) and map or nil
end

---------------------------------------------------------------------------
-- Language detection
---------------------------------------------------------------------------
local _detected_lang = nil

local function detectLang()
    if _detected_lang then return _detected_lang end
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then
        _detected_lang = lang
        return lang
    end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    _detected_lang = lc:match("^([a-zA-Z_]+)") or "en"
    return _detected_lang
end

---------------------------------------------------------------------------
-- Locale file lookup with iterative tag stripping
---------------------------------------------------------------------------
local function tryLoad(name)
    local filepath = _dir .. "locale/" .. name .. ".po"
    local t = parsePO(filepath)
    if t then
        logger.info("[KOSyncthing+] i18n: loaded " .. filepath)
        return t
    end
end

local function loadTranslations(lang)
    if lang == "en" or lang:match("^en_") then
        return nil
    end
    local tag = lang
    while tag and tag ~= "" do
        local t = tryLoad(tag)
        if t then return t end
        local shorter = tag:match("^(.+)_[^_]+$")
        -- shorter is always a strict prefix of tag (or nil), never equal to it,
        -- so the `shorter == tag` guard is impossible and removed.
        if not shorter then break end
        tag = shorter
    end
    return nil
end

---------------------------------------------------------------------------
-- Module initialisation
---------------------------------------------------------------------------
local ko_gettext = require("gettext")
local _loaded    = false
local _gettext

local function _init()
    if _loaded then return end
    _loaded = true
    local lang = detectLang()
    local translations = loadTranslations(lang)
    if translations then
        _gettext = function(msgid)
            return translations[msgid] or ko_gettext(msgid)
        end
    else
        _gettext = ko_gettext
    end
end

local function gettext(msgid)
    if not _loaded then _init() end
    return _gettext(msgid)
end

return { gettext = gettext, getLang = detectLang }