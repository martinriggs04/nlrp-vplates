--[[
    nlrp-vplates | shared/class.lua
    Minimal, allocation-friendly OOP layer used by every module of the resource.

    Usage:
        local Animal = Class('Animal')
        function Animal:init(name) self.name = name end
        function Animal:speak() return '...' end

        local Dog = Class('Dog', Animal)
        function Dog:speak() return 'woof' end

        local d = Dog.new('Rex')
]]

local setmetatable, getmetatable, rawget, type = setmetatable, getmetatable, rawget, type

---@param name string
---@param base table|nil
---@return table
function Class(name, base)
    assert(type(name) == 'string', 'Class(name) expects a string')

    local cls = {}
    cls.__name = name
    cls.__index = cls
    cls.__tostring = function(self)
        return ('%s<%s>'):format(cls.__name, tostring(rawget(self, '__id') or '?'))
    end

    if base then
        cls.super = base
        setmetatable(cls, { __index = base })
    end

    function cls.new(...)
        local instance = setmetatable({}, cls)
        local init = instance.init
        if init then init(instance, ...) end
        return instance
    end

    ---@param other table
    ---@return boolean
    function cls:isInstanceOf(other)
        local mt = getmetatable(self)
        while mt do
            if mt == other then return true end
            mt = mt.super
        end
        return false
    end

    return cls
end

--- Lightweight singleton helper: builds the instance on first access only.
---@param cls table
---@return fun(...):table
function Singleton(cls)
    local instance
    return function(...)
        if not instance then instance = cls.new(...) end
        return instance
    end
end
