--[[
    nlrp-vplates | server/security.lua  (SERVER ONLY)
    Rate limiting, strike tracking and spatial validation.
    Nothing the client sends is trusted — every request passes through here
    before any business logic runs.
]]

local cfg = Config.Security

-- ═══════════════════════════════════════════════════════════════════════════
-- Token bucket rate limiter, one bucket per player, lazily refilled.
-- ═══════════════════════════════════════════════════════════════════════════

local RateLimiter = Class('RateLimiter')

function RateLimiter:init(maxTokens, windowSeconds)
    self.max     = maxTokens
    self.window  = windowSeconds * 1000
    self.buckets = {}
end

---@param src number
---@return boolean allowed
function RateLimiter:Consume(src)
    local now    = GetGameTimer()
    local bucket = self.buckets[src]

    if not bucket then
        bucket = { tokens = self.max, last = now }
        self.buckets[src] = bucket
    end

    -- Continuous refill: tokens regenerate proportionally to elapsed time.
    local elapsed = now - bucket.last
    if elapsed > 0 then
        local refill = (elapsed / self.window) * self.max
        if refill > 0 then
            bucket.tokens = math.min(self.max, bucket.tokens + refill)
            bucket.last   = now
        end
    end

    if bucket.tokens < 1 then return false end

    bucket.tokens = bucket.tokens - 1
    return true
end

function RateLimiter:Clear(src)
    self.buckets[src] = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Cooldown registry (per player or per vehicle plate)
-- ═══════════════════════════════════════════════════════════════════════════

local Cooldown = Class('Cooldown')

function Cooldown:init(seconds)
    self.duration = (seconds or 0) * 1000
    self.entries  = {}
end

---@param key any
---@return boolean ready
---@return number remainingSeconds
function Cooldown:Check(key)
    if self.duration <= 0 then return true, 0 end
    local expires = self.entries[key]
    if not expires then return true, 0 end

    local now = GetGameTimer()
    if now >= expires then
        self.entries[key] = nil
        return true, 0
    end

    return false, math.ceil((expires - now) / 1000)
end

function Cooldown:Start(key)
    if self.duration <= 0 then return end
    self.entries[key] = GetGameTimer() + self.duration
end

function Cooldown:Clear(key)
    self.entries[key] = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Security facade
-- ═══════════════════════════════════════════════════════════════════════════

local SecurityService = Class('SecurityService')

function SecurityService:init()
    self.limiter          = RateLimiter.new(cfg.MaxRequestsPerWindow, cfg.WindowSeconds)
    self.strikes          = {}
    self.playerFakeCd     = Cooldown.new(Config.FakePlate.PlayerCooldown)
    self.vehicleLegalCd   = Cooldown.new(Config.Locations.VehicleCooldown)
    self.busy             = {}
end

--- Marks a player as having one in-flight request; prevents parallel spam.
---@param src number
---@return boolean acquired
function SecurityService:Acquire(src)
    if self.busy[src] then return false end
    self.busy[src] = true
    return true
end

---@param src number
function SecurityService:Release(src)
    self.busy[src] = nil
end

---@param src number
---@return boolean
function SecurityService:CheckRate(src)
    return self.limiter:Consume(src)
end

--- Records a rejected/forged request and applies the configured action.
---@param src number
---@param reason string
function SecurityService:Strike(src, reason)
    local count = (self.strikes[src] or 0) + 1
    self.strikes[src] = count

    Logger:Exploit(src, reason, count)

    if count < cfg.StrikesBeforeAction then return end

    self.strikes[src] = nil

    if cfg.ActionOnFlag == 'kick' then
        DropPlayer(src, L('msg.kicked'))
    elseif cfg.ActionOnFlag == 'ban-event' then
        TriggerEvent('nlrp-vplates:security:ban', src, reason)
    end
end

function SecurityService:Reset(src)
    self.limiter:Clear(src)
    self.strikes[src] = nil
    self.busy[src]    = nil
end

--- Validates that a net id resolves to a real, nearby vehicle owned by nobody
--- else's imagination. Returns the entity handle on success.
---@param src number
---@param netId any
---@return number|nil entity
---@return string|nil reason
function SecurityService:ResolveVehicle(src, netId)
    if not Utils.IsPositiveInt(netId) then return nil, L('sec.invalid_netid') end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil, L('sec.no_entity')
    end

    if GetEntityType(entity) ~= 2 then
        return nil, L('sec.not_vehicle')
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil, L('sec.no_ped') end

    local distance = #(GetEntityCoords(ped) - GetEntityCoords(entity))
    if distance > cfg.MaxInteractionDistance then
        return nil, L('sec.far_vehicle', distance)
    end

    return entity
end

--- Validates the claimed location id and the player's distance to its anchor.
---@param src number
---@param locationId any
---@return table|nil location
---@return string|nil reason
function SecurityService:ResolveLocation(src, locationId)
    if type(locationId) ~= 'string' then return nil, L('sec.bad_location_id') end

    local list = Config.LocationList
    for i = 1, #list do
        local location = list[i]
        if location.id == locationId then
            local ped = GetPlayerPed(src)
            if not ped or ped == 0 then return nil, L('sec.no_ped') end

            local anchor   = location.coords
            local distance = #(GetEntityCoords(ped) - vector3(anchor.x, anchor.y, anchor.z))
            if distance > cfg.MaxLocationDistance then
                return nil, L('sec.far_location', distance)
            end

            if location.jobs then
                local job = Framework:GetJob(src)
                local allowed = false
                for j = 1, #location.jobs do
                    if location.jobs[j] == job then allowed = true break end
                end
                if not allowed then return nil, L('sec.job_denied') end
            end

            return location
        end
    end

    return nil, L('sec.unknown_location')
end

Security = SecurityService.new()

AddEventHandler('playerDropped', function()
    Security:Reset(source)
end)
