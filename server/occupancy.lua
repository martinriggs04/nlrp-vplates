--[[
    nlrp-vplates | server/occupancy.lua  (SERVER ONLY)

    Two global registries that only make sense server side, because they are
    shared by every player on the server:

      1. CLERK LOCKS
         While a clerk is walking around a vehicle swapping plates he is busy.
         Nobody else can start a change at that location until he is back at
         his desk. The lock is authoritative: the client target is greyed out
         as a courtesy, but a forged request is rejected here.

      2. PLATE RESERVATIONS
         The plate is checked against the database the moment the player
         confirms it, but it is only written when the scene ends. Without a
         reservation two players could pick the same plate in that window and
         the second write would collide.

    Both entries carry a deadline, so a crashed client or a despawned vehicle
    can never keep a clerk or a plate locked forever.
]]

local OccupancyService = Class('OccupancyService')

function OccupancyService:init()
    self.clerks = {}  -- [locationId] = { src, expires, netId }
    self.plates = {}  -- [plateKey]   = { src, expires }

    self:_startJanitor()
end

-- ── clerk locks ────────────────────────────────────────────────────────────

---@param locationId string
---@return boolean
function OccupancyService:IsClerkFree(locationId)
    local entry = self.clerks[locationId]
    if not entry then return true end

    if GetGameTimer() > entry.expires then
        self:ReleaseClerk(locationId)
        return true
    end

    return false
end

--- Marks the clerk as busy and tells every client to grey the target out.
---@param locationId string
---@param src number
---@param netId number
---@return boolean acquired
function OccupancyService:AcquireClerk(locationId, src, netId)
    if not self:IsClerkFree(locationId) then return false end

    self.clerks[locationId] = {
        src     = src,
        netId   = netId,
        expires = GetGameTimer() + Scene.MaxTime(),
    }

    TriggerClientEvent('nlrp-vplates:client:occupancy', -1, locationId, true)
    return true
end

---@param locationId string
---@param src number|nil when given, only the holder may release the lock
function OccupancyService:ReleaseClerk(locationId, src)
    local entry = self.clerks[locationId]
    if not entry then return end
    if src and entry.src ~= src then return end

    self.clerks[locationId] = nil
    TriggerClientEvent('nlrp-vplates:client:occupancy', -1, locationId, false)
end

--- Releases every clerk held by a player (disconnect, cancel, timeout).
---@param src number
function OccupancyService:ReleaseBySource(src)
    for locationId, entry in pairs(self.clerks) do
        if entry.src == src then self:ReleaseClerk(locationId) end
    end

    for key, entry in pairs(self.plates) do
        if entry.src == src then self.plates[key] = nil end
    end
end

--- Full picture for a client that just joined or restarted the resource.
---@return table<string, boolean>
function OccupancyService:Snapshot()
    local out = {}
    for locationId in pairs(self.clerks) do
        out[locationId] = true
    end
    return out
end

-- ── plate reservations ─────────────────────────────────────────────────────

---@param plate string
---@param src number|nil ignore a reservation owned by this player
---@return boolean
function OccupancyService:IsPlateReserved(plate, src)
    local entry = self.plates[Utils.Key(plate)]
    if not entry then return false end

    if GetGameTimer() > entry.expires then
        self.plates[Utils.Key(plate)] = nil
        return false
    end

    return entry.src ~= src
end

---@param plate string
---@param src number
---@return boolean reserved
function OccupancyService:ReservePlate(plate, src)
    if self:IsPlateReserved(plate, src) then return false end

    self.plates[Utils.Key(plate)] = {
        src     = src,
        expires = GetGameTimer() + Scene.MaxTime(),
    }

    return true
end

---@param plate string
---@param src number|nil when given, only the holder may release the reservation
function OccupancyService:ReleasePlate(plate, src)
    if type(plate) ~= 'string' then return end

    local key   = Utils.Key(plate)
    local entry = self.plates[key]
    if not entry then return end
    if src and entry.src ~= src then return end

    self.plates[key] = nil
end

-- ── janitor ────────────────────────────────────────────────────────────────

function OccupancyService:_startJanitor()
    CreateThread(function()
        while true do
            Wait(10000)

            local now = GetGameTimer()

            for locationId, entry in pairs(self.clerks) do
                -- The owner disconnected, or the scene simply never reported back.
                if now > entry.expires or not GetPlayerName(entry.src) then
                    Utils.Debug(('clerk lock timed out at %s'):format(locationId))
                    self:ReleaseClerk(locationId)
                end
            end

            for key, entry in pairs(self.plates) do
                if now > entry.expires then self.plates[key] = nil end
            end
        end
    end)
end

Occupancy = OccupancyService.new()

RegisterNetEvent('nlrp-vplates:server:requestOccupancy', function()
    local src = source
    if not Security:CheckRate(src) then return end
    TriggerClientEvent('nlrp-vplates:client:occupancySnapshot', src, Occupancy:Snapshot())
end)
