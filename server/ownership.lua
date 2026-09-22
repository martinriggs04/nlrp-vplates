--[[
    nlrp-vplates | server/ownership.lua  (SERVER ONLY)
    Single source of truth for "who owns this plate".

    * Every query is parameterised.
    * A short-lived cache absorbs repeated lookups without ever serving stale
      data across a write (writes invalidate both the old and the new key).
    * When there is no framework or no SQL driver, ownership is simply
      unavailable -> standalone behaviour (everything is unowned).
]]

local CACHE_TTL = 15000 -- ms

local OwnershipService = Class('OwnershipService')

function OwnershipService:init()
    self.schema  = Framework.schema
    self.enabled = Framework.hasOwners and Database.available and self.schema ~= nil
    self.cache   = {}

    if self.enabled then
        self.cascade = self:_buildCascade()
    else
        self.cascade = {}
    end
end

--- Whitelists cascade table/column names: SQL identifiers can never be bound
--- as parameters, so anything not strictly alphanumeric is discarded.
function OwnershipService:_buildCascade()
    local out = {}
    local list = Config.SQL.CascadeTables or {}

    for i = 1, #list do
        local entry = list[i]
        local tbl, col = entry.table, entry.column

        if type(tbl) == 'string' and type(col) == 'string'
            and tbl:match('^[%w_]+$') and col:match('^[%w_]+$') then
            if not (tbl == self.schema.table and col == self.schema.plateColumn) then
                out[#out + 1] = { table = tbl, column = col }
            end
        else
            Utils.Error(('Config.SQL.CascadeTables[%d] ignored: invalid identifier'):format(i))
        end
    end

    return out
end

function OwnershipService:_cacheGet(key)
    local entry = self.cache[key]
    if not entry then return nil, false end
    if GetGameTimer() > entry.expires then
        self.cache[key] = nil
        return nil, false
    end
    return entry.value, true
end

function OwnershipService:_cacheSet(key, value)
    self.cache[key] = { value = value, expires = GetGameTimer() + CACHE_TTL }
end

function OwnershipService:_invalidate(...)
    for i = 1, select('#', ...) do
        self.cache[Utils.Key(select(i, ...))] = nil
    end
end

--- Returns the owner identifier of a plate, or nil when unowned/unavailable.
---@param plate string
---@return string|nil
function OwnershipService:GetOwner(plate)
    if not self.enabled then return nil end

    local key = Utils.Key(plate)
    if key == '' then return nil end

    local cached, hit = self:_cacheGet(key)
    if hit then return cached end

    local schema = self.schema
    local sql = ('SELECT `%s` AS owner FROM `%s` WHERE REPLACE(UPPER(`%s`), " ", "") = ? LIMIT 1')
        :format(schema.ownerColumn, schema.table, schema.plateColumn)

    local ok, rows = pcall(function() return Database:Query(sql, { key }) end)
    if not ok then
        Utils.Error('owner lookup failed: ' .. tostring(rows))
        return nil
    end

    local owner = rows and rows[1] and rows[1].owner or nil
    self:_cacheSet(key, owner)
    return owner
end

---@param plate string
---@param identifier string|nil
---@return boolean
function OwnershipService:IsOwnedBy(plate, identifier)
    if not identifier then return false end
    local owner = self:GetOwner(plate)
    return owner ~= nil and owner == identifier
end

---@param plate string
---@return boolean
function OwnershipService:IsOwned(plate)
    return self:GetOwner(plate) ~= nil
end

--- Uniqueness check against persisted vehicles.
---@param plate string
---@return boolean
function OwnershipService:IsTaken(plate)
    if not self.enabled then return false end
    return self:GetOwner(plate) ~= nil
end

--- Permanent plate change. Returns false if nothing was updated, which also
--- covers the "player is not the owner" race condition (the WHERE clause
--- re-checks ownership atomically).
---@param oldPlate string
---@param newPlate string
---@param identifier string
---@return boolean
function OwnershipService:UpdatePlate(oldPlate, newPlate, identifier)
    if not self.enabled then return false end

    local schema  = self.schema
    local oldKey  = Utils.Key(oldPlate)
    local stored  = newPlate

    local sql, params

    if schema.jsonColumn then
        sql = ([[
            UPDATE `%s`
               SET `%s` = ?, `%s` = JSON_SET(COALESCE(`%s`, '{}'), '$.plate', ?)
             WHERE REPLACE(UPPER(`%s`), " ", "") = ? AND `%s` = ?
        ]]):format(schema.table, schema.plateColumn, schema.jsonColumn, schema.jsonColumn,
                   schema.plateColumn, schema.ownerColumn)
        params = { stored, stored, oldKey, identifier }
    else
        sql = ([[
            UPDATE `%s`
               SET `%s` = ?
             WHERE REPLACE(UPPER(`%s`), " ", "") = ? AND `%s` = ?
        ]]):format(schema.table, schema.plateColumn, schema.plateColumn, schema.ownerColumn)
        params = { stored, oldKey, identifier }
    end

    local ok, affected = pcall(function() return Database:Execute(sql, params) end)
    if not ok then
        Utils.Error('plate update failed: ' .. tostring(affected))
        return false
    end

    if (tonumber(affected) or 0) < 1 then return false end

    for i = 1, #self.cascade do
        local entry = self.cascade[i]
        local csql = ('UPDATE `%s` SET `%s` = ? WHERE REPLACE(UPPER(`%s`), " ", "") = ?')
            :format(entry.table, entry.column, entry.column)
        pcall(function() Database:Execute(csql, { stored, oldKey }) end)
    end

    self:_invalidate(oldPlate, newPlate)
    return true
end

Ownership = OwnershipService.new()

Utils.Debug('ownership enabled =', tostring(Ownership.enabled))
