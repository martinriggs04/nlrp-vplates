--[[
    nlrp-vplates | shared/locale.lua
    Locale service.

    Translations live in `locales/<iso>.json`, using the exact same format and
    semantics as the ox_lib locale module:

        * nested objects are flattened into dotted keys  ("ui.confirm")
        * values are formatted with string.format          ("Hello %s")
        * "${other.key}" references another entry and is resolved at load time

    Language resolution follows each framework's own convention, in order:

        1. Config.Locale, when it is not 'auto'
        2. `ox:locale`   convar  -> ox_lib / qbx_core convention
        3. `qb_locale`   convar  -> QBCore convention
        4. `esx:locale`  convar, then ESX.GetConfig().Locale -> ESX convention
        5. 'en'

    Both convars are declared with `setr` by their respective frameworks, so the
    value is replicated and this resolves identically on client and server.

    The JSON files are drop-in compatible with `lib.locale()`: a server that
    already standardises on ox_lib can replace this loader with two lines and
    keep the exact same files and keys.
]]

local RESOURCE = GetCurrentResourceName()
local FALLBACK = 'en'

local LocaleService = Class('LocaleService')

function LocaleService:init()
    self.lang    = FALLBACK
    self.strings = {}
    self.missing = {}

    self.lang = self:_detect()
    self:_load()
end

-- ── language resolution ────────────────────────────────────────────────────

---@param name string
---@return string|nil
local function convar(name)
    local value = GetConvar(name, '')
    if value == '' or value == 'nil' then return nil end
    return value
end

---@return string
function LocaleService:_detect()
    local forced = Config.Locale
    if type(forced) == 'string' and forced ~= '' and forced ~= 'auto' then
        return forced
    end

    -- ox_lib / qbx_core
    local ox = convar('ox:locale')
    if ox then return ox end

    -- QBCore
    local qb = convar('qb_locale')
    if qb then return qb end

    -- ESX
    local esx = convar('esx:locale')
    if esx then return esx end

    if Framework and Framework.name == 'esx' and Framework.core then
        local ok, config = pcall(function() return Framework.core.GetConfig() end)
        if ok and type(config) == 'table' and type(config.Locale) == 'string' then
            return config.Locale
        end
    end

    return FALLBACK
end

-- ── loading ────────────────────────────────────────────────────────────────

---@param source table
---@param prefix string|nil
---@param out table
local function flatten(source, prefix, out)
    for key, value in pairs(source) do
        local path = prefix and (prefix .. '.' .. key) or key
        if type(value) == 'table' then
            flatten(value, path, out)
        elseif type(value) == 'string' then
            out[path] = value
        end
    end
end

---@param lang string
---@return table|nil
function LocaleService:_read(lang)
    local raw = LoadResourceFile(RESOURCE, ('locales/%s.json'):format(lang))
    if not raw then return nil end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        Utils.Error(('locales/%s.json is not valid JSON'):format(lang))
        return nil
    end

    local flat = {}
    flatten(decoded, nil, flat)
    return flat
end

--- Resolves "${other.key}" references. One pass is enough for a flat table and
--- keeps a malformed file from ever looping forever.
---@param strings table
local function resolveReferences(strings)
    for key, value in pairs(strings) do
        if value:find('${', 1, true) then
            strings[key] = value:gsub('%${([%w_%.]+)}', function(ref)
                return strings[ref] or ('${' .. ref .. '}')
            end)
        end
    end
end

function LocaleService:_load()
    local fallback = self:_read(FALLBACK) or {}

    if self.lang == FALLBACK then
        self.strings = fallback
    else
        local translated = self:_read(self.lang)

        if not translated then
            Utils.Warn(('locales/%s.json not found, falling back to "%s"'):format(self.lang, FALLBACK))
            self.strings = fallback
            self.lang    = FALLBACK
        else
            -- Any key the translation is missing keeps its English value, so a
            -- partial translation can never produce an empty notification.
            for key, value in pairs(fallback) do
                if translated[key] == nil then translated[key] = value end
            end
            self.strings = translated
        end
    end

    resolveReferences(self.strings)
end

-- ── lookup ─────────────────────────────────────────────────────────────────

---@param key string
---@param ... any
---@return string
function LocaleService:Get(key, ...)
    local str = self.strings[key]

    if not str then
        if not self.missing[key] then
            self.missing[key] = true
            Utils.Warn(('missing locale key: "%s"'):format(tostring(key)))
        end
        return tostring(key)
    end

    if select('#', ...) == 0 then return str end

    local ok, formatted = pcall(string.format, str, ...)
    return ok and formatted or str
end

--- Returns every string under a prefix, without it ("ui.confirm" -> "confirm").
--- Used to hand the whole UI dictionary to the NUI in one message.
---@param prefix string
---@return table
function LocaleService:Group(prefix)
    local out    = {}
    local offset = #prefix + 2

    for key, value in pairs(self.strings) do
        if key:sub(1, offset - 1) == prefix .. '.' then
            out[key:sub(offset)] = value
        end
    end

    return out
end

Locale = LocaleService.new()

--- Global shorthand used across the whole resource.
---@param key string
---@param ... any
---@return string
function L(key, ...)
    return Locale:Get(key, ...)
end

--- Resolves a config value that may be either a literal string or a locale
--- reference written as "@some.key". Lets shared/locations.lua stay
--- translatable without the config file depending on the locale service.
---@param value any
---@return any
function T(value)
    if type(value) == 'string' and value:sub(1, 1) == '@' then
        return Locale:Get(value:sub(2))
    end
    return value
end

Utils.Debug('locale =', Locale.lang)
