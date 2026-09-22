--[[
    nlrp-vplates | bridge/inventory.lua  (SERVER ONLY)
    Inventory abstraction for the fake-plate item.
    Supported: ox_inventory, qb-inventory, qs-inventory, core_inventory.

    Item consumption is ALWAYS done server side, before the plate is applied,
    and rolled back if the swap fails afterwards.
]]

local InventoryAdapter = Class('InventoryAdapter')

function InventoryAdapter:init()
    self.name = 'none'
end

---@return boolean
function InventoryAdapter:IsAvailable() return false end

---@param src number
---@param item string
---@return number
function InventoryAdapter:Count(src, item) return 0 end

---@param src number
---@param item string
---@param amount number
---@return boolean
function InventoryAdapter:Remove(src, item, amount) return false end

---@param src number
---@param item string
---@param amount number
---@return boolean
function InventoryAdapter:Add(src, item, amount) return false end

---@param src number
---@param item string
---@param amount number
---@return boolean
function InventoryAdapter:Has(src, item, amount)
    return self:Count(src, item) >= (amount or 1)
end

-- ── ox_inventory ────────────────────────────────────────────────────────────

local OxInventory = Class('OxInventory', InventoryAdapter)

function OxInventory:init()
    InventoryAdapter.init(self)
    self.name = 'ox_inventory'
end

function OxInventory:IsAvailable() return Utils.ResourceReady('ox_inventory') end

function OxInventory:Count(src, item)
    local ok, count = pcall(function()
        return exports.ox_inventory:GetItemCount(src, item)
    end)
    return ok and tonumber(count) or 0
end

function OxInventory:Remove(src, item, amount)
    local ok, result = pcall(function()
        return exports.ox_inventory:RemoveItem(src, item, amount)
    end)
    return ok and result ~= false
end

function OxInventory:Add(src, item, amount)
    local ok, result = pcall(function()
        return exports.ox_inventory:AddItem(src, item, amount)
    end)
    return ok and result ~= false
end

-- ── qb-inventory ────────────────────────────────────────────────────────────

local QBInventory = Class('QBInventory', InventoryAdapter)

function QBInventory:init()
    InventoryAdapter.init(self)
    self.name = 'qb-inventory'
end

function QBInventory:IsAvailable()
    return Utils.ResourceReady('qb-inventory') or Utils.ResourceReady('lj-inventory')
end

function QBInventory:_resource()
    return Utils.ResourceReady('qb-inventory') and 'qb-inventory' or 'lj-inventory'
end

function QBInventory:Count(src, item)
    -- Newer qb-inventory exposes exports; older builds only expose player functions.
    local ok, count = pcall(function()
        return exports[self:_resource()]:GetItemCount(src, item)
    end)
    if ok and tonumber(count) then return tonumber(count) end

    local player = Framework._player and Framework:_player(src) or nil
    if not player then return 0 end
    local found = player.Functions.GetItemByName(item)
    return found and (tonumber(found.amount) or 0) or 0
end

function QBInventory:Remove(src, item, amount)
    local ok, result = pcall(function()
        return exports[self:_resource()]:RemoveItem(src, item, amount, nil, 'vplates')
    end)
    if ok and result ~= nil then return result ~= false end

    local player = Framework._player and Framework:_player(src) or nil
    if not player then return false end
    return player.Functions.RemoveItem(item, amount) == true
end

function QBInventory:Add(src, item, amount)
    local ok, result = pcall(function()
        return exports[self:_resource()]:AddItem(src, item, amount, nil, nil, 'vplates')
    end)
    if ok and result ~= nil then return result ~= false end

    local player = Framework._player and Framework:_player(src) or nil
    if not player then return false end
    return player.Functions.AddItem(item, amount) == true
end

-- ── qs-inventory ────────────────────────────────────────────────────────────

local QSInventory = Class('QSInventory', InventoryAdapter)

function QSInventory:init()
    InventoryAdapter.init(self)
    self.name = 'qs-inventory'
end

function QSInventory:IsAvailable() return Utils.ResourceReady('qs-inventory') end

function QSInventory:Count(src, item)
    local ok, count = pcall(function()
        return exports['qs-inventory']:GetItemTotalAmount(src, item)
    end)
    return ok and tonumber(count) or 0
end

function QSInventory:Remove(src, item, amount)
    local ok, result = pcall(function()
        return exports['qs-inventory']:RemoveItem(src, item, amount)
    end)
    return ok and result ~= false
end

function QSInventory:Add(src, item, amount)
    local ok, result = pcall(function()
        return exports['qs-inventory']:AddItem(src, item, amount)
    end)
    return ok and result ~= false
end

-- ── core_inventory ──────────────────────────────────────────────────────────

local CoreInventory = Class('CoreInventory', InventoryAdapter)

function CoreInventory:init()
    InventoryAdapter.init(self)
    self.name = 'core_inventory'
end

function CoreInventory:IsAvailable() return Utils.ResourceReady('core_inventory') end

--- core_inventory identifies inventories by "<identifier>" for players.
function CoreInventory:_inv(src)
    return tostring(Framework:GetIdentifier(src) or '')
end

function CoreInventory:Count(src, item)
    local inv = self:_inv(src)
    if inv == '' then return 0 end

    local ok, count = pcall(function()
        return exports.core_inventory:getItemCount(inv, item)
    end)
    if ok and tonumber(count) then return tonumber(count) end

    local ok2, items = pcall(function()
        return exports.core_inventory:getInventory(inv)
    end)
    if not ok2 or type(items) ~= 'table' then return 0 end

    local total = 0
    for i = 1, #items do
        if items[i].name == item then total = total + (tonumber(items[i].count) or 0) end
    end
    return total
end

function CoreInventory:Remove(src, item, amount)
    local inv = self:_inv(src)
    if inv == '' then return false end
    local ok, result = pcall(function()
        return exports.core_inventory:removeItem(inv, item, amount)
    end)
    return ok and result ~= false
end

function CoreInventory:Add(src, item, amount)
    local inv = self:_inv(src)
    if inv == '' then return false end
    local ok, result = pcall(function()
        return exports.core_inventory:addItem(inv, item, amount)
    end)
    return ok and result ~= false
end

-- ── Resolver ────────────────────────────────────────────────────────────────

local ORDER = {
    { key = 'ox_inventory',   cls = OxInventory },
    { key = 'qs-inventory',   cls = QSInventory },
    { key = 'core_inventory', cls = CoreInventory },
    { key = 'qb-inventory',   cls = QBInventory },
}

local function resolve()
    local forced = Config.Inventory

    if forced == 'none' then return InventoryAdapter.new() end

    if forced ~= 'auto' then
        for i = 1, #ORDER do
            if ORDER[i].key == forced then return ORDER[i].cls.new() end
        end
        Utils.Error(('unknown inventory in config: "%s"'):format(tostring(forced)))
    end

    for i = 1, #ORDER do
        local adapter = ORDER[i].cls.new()
        if adapter:IsAvailable() then return adapter end
    end

    return InventoryAdapter.new()
end

Inventory = resolve()

if Inventory.name == 'none' then
    Utils.Warn('no inventory detected - the fake plate item is disabled')
end

Utils.Debug('inventory =', Inventory.name)
