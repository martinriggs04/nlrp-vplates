--[[
    nlrp-vplates | shared/utils.lua
    Pure functions. No state, no side effects, identical on client & server.
    The server ALWAYS re-runs every validation done here on the client.
]]

Utils = {}

local Plate  = Config.Plate
local upper, gsub, find, len, sub = string.upper, string.gsub, string.find, string.len, string.sub
local format, rep = string.format, string.rep

-- ── Blacklist lookup built once at load (O(1) instead of O(n) per request) ───
local blacklistSet = {}
for i = 1, #Plate.Blacklist do
    blacklistSet[upper(Plate.Blacklist[i])] = true
end

local blacklistPrefixes = {}
for i = 1, #Plate.BlacklistedPrefixes do
    blacklistPrefixes[#blacklistPrefixes + 1] = upper(Plate.BlacklistedPrefixes[i])
end

---@param s any
---@return string
function Utils.Trim(s)
    if type(s) ~= 'string' then return '' end
    return (gsub(s, '^%s*(.-)%s*$', '%1'))
end

--- Normalises a plate the exact same way the game stores it.
--- Strips forbidden characters, collapses spaces, uppercases, hard-caps length.
---@param input any
---@return string
function Utils.Sanitize(input)
    if type(input) ~= 'string' then return '' end

    local s = input
    if Plate.ForceUppercase then s = upper(s) end

    -- Drop anything outside the allowed character class.
    s = gsub(s, '[^' .. sub(Plate.AllowedPattern, 2, -2) .. ']', '')

    if not Plate.AllowSpaces then
        s = gsub(s, ' ', '')
    else
        s = gsub(s, '%s+', ' ')
    end

    s = Utils.Trim(s)

    if len(s) > Plate.MaxLength then
        s = sub(s, 1, Plate.MaxLength)
        s = Utils.Trim(s)
    end

    return s
end

--- Comparable key: uppercase, no spaces. Used for uniqueness & blacklist checks.
---@param plate any
---@return string
function Utils.Key(plate)
    if type(plate) ~= 'string' then return '' end
    return (gsub(upper(plate), '%s', ''))
end

---@param a any
---@param b any
---@return boolean
function Utils.PlateEquals(a, b)
    return Utils.Key(a) == Utils.Key(b)
end

--- Full rule set. Returns false + a locale key (and an optional format arg).
--- When a format mask is configured for the mode it replaces the length rules:
--- the mask already pins the exact length and the type of every character.
---@param plate string sanitised plate
---@param mode string|nil 'legal'|'fake'
---@return boolean ok
---@return string|nil reasonKey
---@return any|nil reasonArg
function Utils.Validate(plate, mode)
    if type(plate) ~= 'string' then return false, 'msg.invalid_plate' end

    local key = Utils.Key(plate)
    if key == '' then return false, 'msg.invalid_plate' end

    local plateFormat = Formats and Formats:Get(mode)

    if plateFormat then
        if not plateFormat:Matches(plate) then
            return false, 'msg.plate_format', plateFormat.mask
        end
    else
        local length = len(plate)
        if length < Plate.MinLength then return false, 'msg.plate_too_short', Plate.MinLength end
        if length > Plate.MaxLength then return false, 'msg.plate_too_long', Plate.MaxLength end

        if Plate.RequireAlphanumeric and not find(key, '%w') then
            return false, 'msg.invalid_plate'
        end
    end

    if blacklistSet[key] then return false, 'msg.plate_blacklisted' end

    for i = 1, #blacklistPrefixes do
        local prefix = blacklistPrefixes[i]
        if sub(key, 1, len(prefix)) == prefix then
            return false, 'msg.plate_blacklisted'
        end
    end

    -- Substring scan for slurs / reserved words inside a longer plate.
    for word in pairs(blacklistSet) do
        if len(word) >= 4 and find(key, word, 1, true) then
            return false, 'msg.plate_blacklisted'
        end
    end

    return true
end

--- GTA pads plates to 8 characters internally; some frameworks store them padded.
---@param plate string
---@return string
function Utils.Pad(plate)
    local length = len(plate)
    if length >= Plate.MaxLength then return plate end
    return plate .. rep(' ', Plate.MaxLength - length)
end

---@param value any
---@return boolean
function Utils.IsPositiveInt(value)
    return type(value) == 'number' and value == math.floor(value) and value > 0 and value < 2147483647
end

---@param ... any
function Utils.Debug(...)
    if not Config.Debug then return end
    local parts = { ... }
    for i = 1, #parts do parts[i] = tostring(parts[i]) end
    print(format('^5[vplates]^7 %s', table.concat(parts, ' ')))
end

---@param msg string
function Utils.Warn(msg)
    print(format('^3[vplates] %s^7', msg))
end

---@param msg string
function Utils.Error(msg)
    print(format('^1[vplates] %s^7', msg))
end

---@param name string
---@return boolean
function Utils.ResourceReady(name)
    return GetResourceState(name) == 'started'
end
