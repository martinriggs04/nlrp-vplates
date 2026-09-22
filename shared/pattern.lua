--[[
    nlrp-vplates | shared/pattern.lua
    Plate format masks.

    A format is a small template describing, character by character, what the
    final plate must look like. It is compiled ONCE at resource start into a
    list of slots, so matching and generating are O(n) with zero allocations
    beyond the result string.

    Syntax
      1        one random digit  (0-9)
      X        one random letter (A-Z)
      <space>  a literal space, on that exact position
      ^        locks the PRECEDING character: it is never randomised and must
               match exactly

    Any character that is not `1`, `X` or `^` is already literal, so `^` is only
    mandatory when you need a literal `1` or `X` (`1^`, `X^`). Writing `N^`
    instead of `N` is still recommended: it documents the intent.

    Examples
      'N^ 11 XXX'   -> N 47 KQD      mask: N ## ???
      'L^S^ XXXXX'  -> LS ACFAS      mask: LS ?????
      '11XXX111'    -> 42QWE913      mask: ##???###

    The same rules are enforced on the client (input mask) and on the server
    (final authority). The server never trusts the composed plate.
]]

local DIGITS  = '0123456789'
local LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

local sub, upper, find, format = string.sub, string.upper, string.find, string.format
local random = math.random

-- Placeholders used to render a human readable mask.
local MASK_CHAR = { digit = '#', letter = '?' }

-- ─────────────────────────────────────────────────────────────────────────────
-- PlateFormat: one compiled template
-- ─────────────────────────────────────────────────────────────────────────────

local PlateFormat = Class('PlateFormat')

---@param source string raw format string from the config
function PlateFormat:init(source)
    self.source   = source
    self.slots    = {}
    self.length   = 0
    self.editable = 0
    self.valid    = false
    self.error    = nil

    self:_compile()

    if self.valid then
        self.mask    = self:_buildMask()
        self.example = self:Generate()
    end
end

function PlateFormat:_fail(message)
    self.error = message
    self.valid = false
    return false
end

function PlateFormat:_compile()
    local src = self.source

    if type(src) ~= 'string' or src == '' then
        return self:_fail('the format is empty')
    end

    src = upper(src)

    -- The sanitiser trims and collapses spaces, so such a format could never
    -- be satisfied by a real plate. Caught here instead of at runtime.
    if find(src, '^%s') or find(src, '%s$') then
        return self:_fail('the format cannot start or end with a space')
    end

    if find(src, '  ', 1, true) then
        return self:_fail('the format cannot contain two consecutive spaces')
    end

    local allowed = Config.Plate.AllowedPattern
    local i, n = 1, #src

    while i <= n do
        local char  = sub(src, i, i)
        local ahead = sub(src, i + 1, i + 1)
        local slot

        if char == '^' then
            return self:_fail(format("stray '^' at position %d: it must follow a character", i))
        end

        if ahead == '^' then
            slot = { kind = 'literal', char = char }
            i = i + 2
        elseif char == '1' then
            slot = { kind = 'digit' }
            i = i + 1
        elseif char == 'X' then
            slot = { kind = 'letter' }
            i = i + 1
        else
            slot = { kind = 'literal', char = char }
            i = i + 1
        end

        if slot.kind == 'literal' then
            if not find(slot.char, allowed) then
                return self:_fail(format("character '%s' is not allowed in a plate", slot.char))
            end
            if slot.char == ' ' and not Config.Plate.AllowSpaces then
                return self:_fail('the format uses a space but Config.Plate.AllowSpaces is false')
            end
        else
            self.editable = self.editable + 1
        end

        self.slots[#self.slots + 1] = slot
    end

    self.length = #self.slots

    if self.length > Config.Plate.MaxLength then
        return self:_fail(format('the format produces %d characters, the limit is %d',
            self.length, Config.Plate.MaxLength))
    end

    if self.length < Config.Plate.MinLength then
        return self:_fail(format('the format produces %d characters, the minimum is %d',
            self.length, Config.Plate.MinLength))
    end

    if self.editable == 0 then
        return self:_fail('the format is fully fixed, every plate would be identical')
    end

    self.valid = true
    return true
end

function PlateFormat:_buildMask()
    local out = {}
    for i = 1, self.length do
        local slot = self.slots[i]
        out[i] = slot.kind == 'literal' and slot.char or MASK_CHAR[slot.kind]
    end
    return table.concat(out)
end

--- Does a sanitised plate satisfy this format?
---@param plate any
---@return boolean
function PlateFormat:Matches(plate)
    if type(plate) ~= 'string' or #plate ~= self.length then return false end

    for i = 1, self.length do
        local slot = self.slots[i]
        local char = sub(plate, i, i)

        if slot.kind == 'literal' then
            if char ~= slot.char then return false end
        elseif slot.kind == 'digit' then
            if not find(char, '%d') then return false end
        else
            if not find(char, '%u') then return false end
        end
    end

    return true
end

--- Fills every editable slot at random. Used by the UI dice button and exports.
---@return string
function PlateFormat:Generate()
    local out = {}

    for i = 1, self.length do
        local slot = self.slots[i]

        if slot.kind == 'literal' then
            out[i] = slot.char
        elseif slot.kind == 'digit' then
            local at = random(#DIGITS)
            out[i] = sub(DIGITS, at, at)
        else
            local at = random(#LETTERS)
            out[i] = sub(LETTERS, at, at)
        end
    end

    return table.concat(out)
end

--- Builds a full plate out of the editable characters only.
--- Literal slots are inserted automatically, so `'47KQD'` becomes `'N 47 KQD'`.
---@param input any string or array of characters, in typing order
---@return string plate
---@return boolean complete every editable slot was filled
function PlateFormat:Compose(input)
    local chars = input

    if type(input) == 'string' then
        chars = {}
        for i = 1, #input do chars[i] = sub(input, i, i) end
    end

    if type(chars) ~= 'table' then return '', false end

    local out, cursor, complete = {}, 0, true

    for i = 1, self.length do
        local slot = self.slots[i]

        if slot.kind == 'literal' then
            out[i] = slot.char
        else
            cursor = cursor + 1
            local char = chars[cursor]

            if type(char) == 'string' and char ~= '' then
                out[i] = upper(sub(char, 1, 1))
            else
                out[i] = '_'
                complete = false
            end
        end
    end

    return table.concat(out), complete
end

--- Serialisable description handed to the NUI so the input can be masked.
---@return table
function PlateFormat:Export()
    local slots = {}

    for i = 1, self.length do
        local slot = self.slots[i]
        slots[i] = slot.kind == 'literal'
            and { kind = 'literal', char = slot.char }
            or  { kind = slot.kind }
    end

    return {
        slots    = slots,
        mask     = self.mask,
        length   = self.length,
        editable = self.editable,
        example  = self:Generate(),
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Registry: compiles the configured formats once, resolves them per mode
-- ─────────────────────────────────────────────────────────────────────────────

local FormatRegistry = Class('FormatRegistry')

function FormatRegistry:init()
    self.default = self:_build(Config.Plate.Format, 'Config.Plate.Format')
    self.byMode  = {
        legal = self:_build(Config.Plate.FormatLegal, 'Config.Plate.FormatLegal') or self.default,
        fake  = self:_build(Config.Plate.FormatFake,  'Config.Plate.FormatFake')  or self.default,
    }
end

--- A broken format must never lock the resource: it is reported loudly and the
--- plate falls back to free-form validation.
---@return PlateFormat|nil
function FormatRegistry:_build(source, label)
    if source == nil or source == false or source == '' then return nil end

    local compiled = PlateFormat.new(source)

    if not compiled.valid then
        Utils.Error(format('invalid plate format in %s (%q): %s - falling back to free-form plates',
            label, tostring(source), compiled.error or 'unknown error'))
        return nil
    end

    Utils.Debug(format('plate format %s compiled: %s (example %s)', label, compiled.mask, compiled.example))
    return compiled
end

--- @param mode string|nil 'legal'|'fake'
--- @return PlateFormat|nil nil = no format, any plate shape is accepted
function FormatRegistry:Get(mode)
    if mode and self.byMode[mode] then return self.byMode[mode] end
    return self.default
end

Formats = FormatRegistry.new()
