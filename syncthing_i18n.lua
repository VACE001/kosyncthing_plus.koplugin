-- syncthing_i18n.lua -	Gettext loader for the plugin’s own locale domain
--
-- Singular lookups (gettext) behave exactly as before. Plural lookups
-- (ngettext) are NEW: the plural msgstr[1..] forms are kept in a separate
-- table and selected with the catalogue's Plural-Forms rule, while the
-- singular `map` (which gettext and the i18n.py Lua cross-check rely on) keeps
-- its previous contents — a plural entry still contributes its form[0] to map,
-- so the parsed-entry COUNT is unchanged.
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
-- Plural-Forms expression -> Lua function n -> form index (integer)
-- Converts the C-style "plural=" expression from a .po header into a Lua
-- predicate. Booleans are coerced to 0/1 so the simple "(n != 1)" rule and
-- the multi-form Slavic rules both return a valid integer index.
---------------------------------------------------------------------------
local function parsePluralExpression(expr)
    local function translateTernary(s)
        local function findTop(str, ch)
            local depth = 0
            for i = 1, #str do
                local c = str:sub(i, i)
                if c == "(" then depth = depth + 1
                elseif c == ")" then depth = depth - 1
                elseif c == ch and depth == 0 then return i end
            end
            return nil
        end
        local q = findTop(s, "?")
        if not q then return s end
        local rest = s:sub(q + 1)
        local colon_rel = findTop(rest, ":")
        if not colon_rel then return s end
        local colon = q + colon_rel
        local cond   = s:sub(1, q - 1)
        local truthy = s:sub(q + 1, colon - 1)
        local falsy  = s:sub(colon + 1)
        return "(" .. translateTernary(cond) .. " and (" .. translateTernary(truthy)
            .. ") or (" .. translateTernary(falsy) .. "))"
    end

    expr = expr:gsub("!=", "~="):gsub("&&", " and "):gsub("%|%|", " or "):gsub("!%s*", "not ")
    expr = translateTernary(expr)

    local loadfunc = loadstring or load
    local fn = loadfunc(
        "return function(n) local r = (" .. expr ..
        ") if r == true then return 1 elseif r == false then return 0 else return r or 0 end end")
    if not fn then return nil end
    local ok, pfn = pcall(fn)
    if not ok or type(pfn) ~= "function" then return nil end
    return pfn
end

---------------------------------------------------------------------------
-- PO file parser
-- Returns: map (msgid -> singular string), plural_map (msgid -> {[0]=,[1]=}),
--          pluralizer (function or nil). map keeps its historical contents.
---------------------------------------------------------------------------
local function parsePO(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil end

    local map        = {}
    local plural_map = {}
    local pluralizer = nil

    local msgid, msgid_plural, msgstr, forms, field

    local function flush()
        if msgid == "" then
            -- Header entry: pick up the Plural-Forms rule, if any.
            local hdr = msgstr or ""
            local expr = hdr:match("Plural%-Forms:.-plural=([^;\n]+)")
            if expr then pluralizer = parsePluralExpression(expr) end
        elseif msgid and msgid ~= "" then
            if msgid_plural then
                if forms and forms[0] and forms[0] ~= "" then
                    plural_map[msgid] = forms
                    map[msgid]        = forms[0]   -- keep map's historical form[0]
                end
            else
                if msgstr and msgstr ~= "" then map[msgid] = msgstr end
            end
        end
        msgid, msgid_plural, msgstr, forms, field = nil, nil, nil, nil, nil
    end

    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line == "" or line:match("^#") then
            -- nothing
        elseif line:match("^msgctxt%s+") then
            flush()
        elseif line:match("^msgid%s+") then
            flush()
            msgid = unescape(line:match('^msgid%s+"(.*)"') or "")
            field = "id"
        elseif line:match("^msgid_plural%s+") then
            msgid_plural = unescape(line:match('^msgid_plural%s+"(.*)"') or "")
            field = "plural"
        elseif line:match("^msgstr%[") then
            local idx = tonumber(line:match("^msgstr%[(%d+)%]"))
            forms = forms or {}
            forms[idx] = unescape(line:match('^msgstr%[%d+%]%s+"(.*)"') or "")
            field = "f" .. tostring(idx)
        elseif line:match("^msgstr%s+") then
            msgstr = unescape(line:match('^msgstr%s+"(.*)"') or "")
            field = "str"
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if field == "id" then
                msgid = (msgid or "") .. cont
            elseif field == "plural" then
                msgid_plural = (msgid_plural or "") .. cont
            elseif field == "str" then
                msgstr = (msgstr or "") .. cont
            elseif field and field:match("^f%d+$") then
                local idx = tonumber(field:sub(2))
                forms = forms or {}
                forms[idx] = (forms[idx] or "") .. cont
            end
        end
    end

    flush()
    f:close()
    if not (next(map) or next(plural_map)) then return nil end
    return map, plural_map, pluralizer
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
    local map, plural_map, pluralizer = parsePO(filepath)
    if map then
        logger.info("[KOSyncthing+] i18n: loaded " .. filepath)
        return map, plural_map, pluralizer
    end
end

local function loadTranslations(lang)
    if lang == "en" or lang:match("^en_") then
        return nil
    end
    local tag = lang
    while tag and tag ~= "" do
        local map, plural_map, pluralizer = tryLoad(tag)
        if map then return map, plural_map, pluralizer end
        local shorter = tag:match("^(.+)_[^_]+$")
        if not shorter then break end
        tag = shorter
    end
    return nil
end

---------------------------------------------------------------------------
-- Module initialisation
---------------------------------------------------------------------------
local ko_gettext = require("gettext")
local _loaded     = false
local _map        = nil
local _plural     = nil
local _pluralizer = nil

local function _init()
    if _loaded then return end
    _loaded = true
    local lang = detectLang()
    _map, _plural, _pluralizer = loadTranslations(lang)
end

local function gettext(msgid)
    if not _loaded then _init() end
    if _map then
        local s = _map[msgid]
        if s ~= nil and s ~= "" then return s end
    end
    return ko_gettext(msgid)
end

-- ngettext(singular, plural, n) -> the form for `n` in the active language.
-- Falls through to KOReader's native gettext (and finally to the English
-- singular/plural) when the plugin catalogue has no plural entry.
local function ngettext(singular, plural, n)
    if not _loaded then _init() end
    n = tonumber(n) or 0
    if _plural then
        local forms = _plural[singular]
        if type(forms) == "table" then
            local idx = 0
            if _pluralizer then
                idx = _pluralizer(n) or 0
            else
                idx = (n == 1) and 0 or 1
            end
            local form = forms[idx]
            if form and form ~= "" then return form end
            form = forms[0] or forms[1]
            if form and form ~= "" then return form end
        end
    end
    if type(ko_gettext) == "table" and type(ko_gettext.ngettext) == "function" then
        local ok, res = pcall(ko_gettext.ngettext, singular, plural, n)
        if ok and res and res ~= "" then return res end
    end
    return (n == 1) and singular or plural
end

return { gettext = gettext, ngettext = ngettext, getLang = detectLang }
