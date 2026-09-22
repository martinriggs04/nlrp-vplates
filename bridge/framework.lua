--[[
    nlrp-vplates | bridge/framework.lua
    Framework abstraction. Every framework specific detail is contained in one
    adapter class; the rest of the resource only ever talks to `Framework`.

    Supported: QBX (qbx_core), QBCore, ESX (1.1+ / legacy), Standalone.
]]

local IS_SERVER = IsDuplicityVersion() == 1

-- ═══════════════════════════════════════════════════════════════════════════
-- Base adapter
-- ═══════════════════════════════════════════════════════════════════════════

local FrameworkAdapter = Class('FrameworkAdapter')

function FrameworkAdapter:init()
    self.name      = 'standalone'
    self.core      = nil
    self.hasOwners = false
    --- Descriptor consumed by server/ownership.lua to build its queries.
    self.schema    = nil
    self.loaded    = not IS_SERVER and false or true
end

---@return boolean
function FrameworkAdapter:IsAvailable() return false end

function FrameworkAdapter:Load() end

--- Unique, persistent id of the character (citizenid / identifier / license).
---@param src number
---@return string|nil
function FrameworkAdapter:GetIdentifier(src) return nil end

---@param src number
---@return string
function FrameworkAdapter:GetName(src)
    return GetPlayerName(src) or ('player_' .. tostring(src))
end

---@param src number
---@return string
function FrameworkAdapter:GetJob(src) return 'unemployed' end

---@param src number
---@param account string 'cash'|'bank'
---@return number
function FrameworkAdapter:GetMoney(src, account) return 0 end

---@param src number
---@param account string
---@param amount number
---@return boolean
function FrameworkAdapter:RemoveMoney(src, account, amount) return false end

---@param src number
---@param account string
---@param amount number
---@return boolean
function FrameworkAdapter:AddMoney(src, account, amount) return false end

--- Client side only.
---@return boolean
function FrameworkAdapter:IsPlayerLoaded() return true end

-- ═══════════════════════════════════════════════════════════════════════════
-- QBCore
-- ═══════════════════════════════════════════════════════════════════════════

local QBAdapter = Class('QBAdapter', FrameworkAdapter)

function QBAdapter:init()
    FrameworkAdapter.init(self)
    self.name      = 'qb'
    self.hasOwners = true
    self.schema    = {
        table        = 'player_vehicles',
        plateColumn  = 'plate',
        ownerColumn  = 'citizenid',
        jsonColumn   = nil,
    }
end

function QBAdapter:IsAvailable()
    return Utils.ResourceReady('qb-core')
end

function QBAdapter:Load()
    self.core = exports['qb-core']:GetCoreObject()
    if not IS_SERVER then
        self.loaded = LocalPlayer.state.isLoggedIn == true
        AddEventHandler('QBCore:Client:OnPlayerLoaded', function() self.loaded = true end)
        AddEventHandler('QBCore:Client:OnPlayerUnload', function() self.loaded = false end)
    end
end

function QBAdapter:_player(src)
    return self.core and self.core.Functions.GetPlayer(src) or nil
end

function QBAdapter:GetIdentifier(src)
    local player = self:_player(src)
    return player and player.PlayerData.citizenid or nil
end

function QBAdapter:GetName(src)
    local player = self:_player(src)
    if not player then return FrameworkAdapter.GetName(self, src) end
    local ci = player.PlayerData.charinfo
    return ('%s %s'):format(ci.firstname or '?', ci.lastname or '?')
end

function QBAdapter:GetJob(src)
    local player = self:_player(src)
    return player and player.PlayerData.job and player.PlayerData.job.name or 'unemployed'
end

function QBAdapter:GetMoney(src, account)
    local player = self:_player(src)
    if not player then return 0 end
    return tonumber(player.PlayerData.money[account]) or 0
end

function QBAdapter:RemoveMoney(src, account, amount)
    local player = self:_player(src)
    if not player then return false end
    return player.Functions.RemoveMoney(account, amount, 'vplates-change') == true
end

function QBAdapter:AddMoney(src, account, amount)
    local player = self:_player(src)
    if not player then return false end
    return player.Functions.AddMoney(account, amount, 'vplates-refund') == true
end

function QBAdapter:IsPlayerLoaded() return self.loaded end

-- ═══════════════════════════════════════════════════════════════════════════
-- QBX (qbx_core) — same schema as QB, different API surface
-- ═══════════════════════════════════════════════════════════════════════════

local QBXAdapter = Class('QBXAdapter', QBAdapter)

function QBXAdapter:init()
    QBAdapter.init(self)
    self.name = 'qbx'
end

function QBXAdapter:IsAvailable()
    return Utils.ResourceReady('qbx_core')
end

function QBXAdapter:Load()
    if not IS_SERVER then
        self.loaded = LocalPlayer.state.isLoggedIn == true
        AddEventHandler('QBCore:Client:OnPlayerLoaded', function() self.loaded = true end)
        AddEventHandler('qbx_core:client:playerLoggedOut', function() self.loaded = false end)
    end
end

function QBXAdapter:_player(src)
    return exports.qbx_core:GetPlayer(src)
end

function QBXAdapter:RemoveMoney(src, account, amount)
    local player = self:_player(src)
    if not player then return false end
    return player.Functions.RemoveMoney(account, amount, 'vplates-change') == true
end

function QBXAdapter:AddMoney(src, account, amount)
    local player = self:_player(src)
    if not player then return false end
    return player.Functions.AddMoney(account, amount, 'vplates-refund') == true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ESX
-- ═══════════════════════════════════════════════════════════════════════════

local ESXAdapter = Class('ESXAdapter', FrameworkAdapter)

function ESXAdapter:init()
    FrameworkAdapter.init(self)
    self.name      = 'esx'
    self.hasOwners = true
    self.schema    = {
        table        = 'owned_vehicles',
        plateColumn  = 'plate',
        ownerColumn  = 'owner',
        --- ESX keeps a JSON blob that also carries the plate.
        jsonColumn   = 'vehicle',
    }
end

function ESXAdapter:IsAvailable()
    return Utils.ResourceReady('es_extended')
end

function ESXAdapter:Load()
    if IS_SERVER then
        self.core = exports['es_extended']:getSharedObject()
    else
        self.core = exports['es_extended']:getSharedObject()
        self.loaded = self.core.IsPlayerLoaded and self.core.IsPlayerLoaded() or false
        AddEventHandler('esx:playerLoaded', function() self.loaded = true end)
        AddEventHandler('esx:onPlayerLogout', function() self.loaded = false end)
    end
end

function ESXAdapter:_player(src)
    return self.core and self.core.GetPlayerFromId(src) or nil
end

function ESXAdapter:GetIdentifier(src)
    local player = self:_player(src)
    return player and player.identifier or nil
end

function ESXAdapter:GetName(src)
    local player = self:_player(src)
    return player and (player.getName and player.getName() or player.name)
        or FrameworkAdapter.GetName(self, src)
end

function ESXAdapter:GetJob(src)
    local player = self:_player(src)
    return player and player.job and player.job.name or 'unemployed'
end

function ESXAdapter:GetMoney(src, account)
    local player = self:_player(src)
    if not player then return 0 end
    if account == 'cash' then return player.getMoney() or 0 end
    local acc = player.getAccount('bank')
    return acc and acc.money or 0
end

function ESXAdapter:RemoveMoney(src, account, amount)
    local player = self:_player(src)
    if not player then return false end
    if account == 'cash' then
        if (player.getMoney() or 0) < amount then return false end
        player.removeMoney(amount)
        return true
    end
    local acc = player.getAccount('bank')
    if not acc or acc.money < amount then return false end
    player.removeAccountMoney('bank', amount)
    return true
end

function ESXAdapter:AddMoney(src, account, amount)
    local player = self:_player(src)
    if not player then return false end
    if account == 'cash' then player.addMoney(amount) else player.addAccountMoney('bank', amount) end
    return true
end

function ESXAdapter:IsPlayerLoaded() return self.loaded end

-- ═══════════════════════════════════════════════════════════════════════════
-- Standalone — no ownership at all: every vehicle counts as unowned,
-- therefore only fake plates are usable (by design).
-- ═══════════════════════════════════════════════════════════════════════════

local StandaloneAdapter = Class('StandaloneAdapter', FrameworkAdapter)

function StandaloneAdapter:init()
    FrameworkAdapter.init(self)
    self.name      = 'standalone'
    self.hasOwners = false
    self.schema    = nil
end

function StandaloneAdapter:IsAvailable() return true end

function StandaloneAdapter:GetIdentifier(src)
    if not IS_SERVER then return nil end
    return GetPlayerIdentifierByType(src, 'license') or GetPlayerIdentifier(src, 0)
end

--- No economy in standalone: payments are skipped entirely.
function StandaloneAdapter:GetMoney() return math.maxinteger end
function StandaloneAdapter:RemoveMoney() return true end
function StandaloneAdapter:AddMoney() return true end

-- ═══════════════════════════════════════════════════════════════════════════
-- Resolver
-- ═══════════════════════════════════════════════════════════════════════════

local ORDER = {
    { key = 'qbx',        cls = QBXAdapter },
    { key = 'qb',         cls = QBAdapter },
    { key = 'esx',        cls = ESXAdapter },
    { key = 'standalone', cls = StandaloneAdapter },
}

local function resolve()
    local forced = Config.Framework

    if forced ~= 'auto' then
        for i = 1, #ORDER do
            if ORDER[i].key == forced then
                local adapter = ORDER[i].cls.new()
                if not adapter:IsAvailable() then
                    Utils.Warn(('framework "%s" forced in config but not found'):format(forced))
                end
                return adapter
            end
        end
        Utils.Error(('unknown framework in config: "%s" -> standalone'):format(tostring(forced)))
        return StandaloneAdapter.new()
    end

    for i = 1, #ORDER do
        local adapter = ORDER[i].cls.new()
        if adapter:IsAvailable() then return adapter end
    end

    return StandaloneAdapter.new()
end

Framework = resolve()

local ok, err = pcall(function() Framework:Load() end)
if not ok then
    Utils.Error(('failed to initialise framework "%s": %s'):format(Framework.name, tostring(err)))
    Framework = StandaloneAdapter.new()
end

Utils.Debug('framework =', Framework.name)
