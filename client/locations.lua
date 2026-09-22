--[[
    nlrp-vplates | client/locations.lua  (CLIENT ONLY)
    Ped + blip + target lifecycle for every configured location.

    Peds are streamed in/out based on distance so a server with 30 locations
    still costs nothing when nobody is around. Blips are created once.
]]

local SPAWN_DISTANCE   = 100.0
local DESPAWN_DISTANCE = 150.0
local TICK             = 1500

local LocationEntity = Class('LocationEntity')

function LocationEntity:init(data)
    self.data    = data
    self.id      = data.id
    self.coords  = vector3(data.coords.x, data.coords.y, data.coords.z)
    self.heading = data.coords.w or 0.0
    self.ped     = nil
    self.blip    = nil
    self.zoned   = false
    self.busy    = false   -- a scene is playing on this ped right now
    self.locked  = false   -- the server says the clerk is serving someone
    self.origin  = nil     -- exact spawn position, restored after a scene
end

function LocationEntity:CreateBlip()
    local cfg = self.data.blip
    if not cfg or self.blip then return end

    local blip = AddBlipForCoord(self.coords.x, self.coords.y, self.coords.z)
    SetBlipSprite(blip, cfg.sprite or 446)
    SetBlipColour(blip, cfg.color or 3)
    SetBlipScale(blip, cfg.scale or 0.75)
    SetBlipDisplay(blip, cfg.display or 4)
    SetBlipAsShortRange(blip, true)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(T(cfg.label or self.data.label))
    EndTextCommandSetBlipName(blip)

    self.blip = blip
end

function LocationEntity:RemoveBlip()
    if self.blip then
        RemoveBlip(self.blip)
        self.blip = nil
    end
end

function LocationEntity:SpawnPed()
    local cfg = self.data.ped
    if not cfg or self.ped then return end

    local model = type(cfg.model) == 'number' and cfg.model or joaat(cfg.model)

    RequestModel(model)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < timeout do Wait(50) end
    if not HasModelLoaded(model) then
        Utils.Warn(('ped model unavailable for location %s'):format(self.id))
        return
    end

    local ped = CreatePed(4, model, self.coords.x, self.coords.y, self.coords.z - 1.0, self.heading, false, false)
    SetModelAsNoLongerNeeded(model)

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedDiesWhenInjured(ped, false)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    SetPedCanBeTargetted(ped, false)
    if cfg.frozen ~= false then FreezeEntityPosition(ped, true) end

    if cfg.scenario then
        TaskStartScenarioInPlace(ped, cfg.scenario, 0, true)
    end

    self.ped = ped
    -- Captured after spawning so the scene can put him back to the centimetre.
    self.origin = GetEntityCoords(ped)
    self:_bindTarget()
end

function LocationEntity:DespawnPed()
    -- Never yank the clerk out of the world in the middle of a scene.
    if not self.ped or self.busy then return end

    Target:Remove(self.id)
    self.zoned = false

    if DoesEntityExist(self.ped) then
        DeleteEntity(self.ped)
    end
    self.ped = nil
end

function LocationEntity:_targetOptions()
    local data = self.data
    return {
        label    = L('target.label'),
        icon     = 'fa-solid fa-id-card',
        distance = data.distance or 2.5,
        radius   = data.radius or 1.5,
        --- Hides the option while the clerk is serving someone else. This is
        --- a courtesy only: the server rejects the request anyway.
        canInteract = function()
            return not self.locked and not self.busy
        end,
        onSelect = function()
            if self.locked or self.busy then
                return Notify:Send('error', L('msg.npc_busy'))
            end
            Flow:StartLegal(data)
        end,
    }
end

function LocationEntity:_bindTarget()
    if self.zoned then return end
    self.zoned = true
    Target:AddEntity(self.id, self.ped, self:_targetOptions())
end

--- Locations without a ped get a static zone that never needs streaming.
function LocationEntity:BindStaticZone()
    if self.zoned or self.data.ped then return end
    self.zoned = true
    Target:AddCoords(self.id, self.coords, self:_targetOptions())
end

function LocationEntity:Destroy()
    self:DespawnPed()
    self:RemoveBlip()
    if self.zoned then
        Target:Remove(self.id)
        self.zoned = false
    end
end

-- ═══════════════════════════════════════════════════════════════════════════

local LocationManager = Class('LocationManager')

function LocationManager:init()
    self.entries = {}
    self.byId    = {}
    self.running = false
end

--- @param id string
--- @return table|nil
function LocationManager:Get(id)
    return self.byId[id]
end

--- Server-driven clerk availability.
---@param id string
---@param locked boolean
function LocationManager:SetLocked(id, locked)
    local entry = self.byId[id]
    if entry then entry.locked = locked == true end
end

function LocationManager:Build()
    local list = Config.LocationList

    for i = 1, #list do
        local entry = LocationEntity.new(list[i])
        self.entries[#self.entries + 1] = entry
        self.byId[entry.id] = entry
        entry:CreateBlip()
        entry:BindStaticZone()
    end

    if #self.entries > 0 then self:_startStreamer() end

    -- Catch up with clerks that were already busy before we joined.
    TriggerServerEvent('nlrp-vplates:server:requestOccupancy')
end

function LocationManager:_startStreamer()
    if self.running then return end
    self.running = true

    CreateThread(function()
        while self.running do
            local pos     = GetEntityCoords(PlayerPedId())
            local closest = 9999.0

            for i = 1, #self.entries do
                local entry = self.entries[i]

                if entry.data.ped then
                    local dist = #(pos - entry.coords)
                    if dist < closest then closest = dist end

                    if dist <= SPAWN_DISTANCE then
                        if not entry.ped then entry:SpawnPed() end
                    elseif dist > DESPAWN_DISTANCE and entry.ped then
                        entry:DespawnPed()
                    end
                end
            end

            -- Far from everything: poll lazily. Nearby: stay responsive.
            Wait(closest > 400.0 and 5000 or TICK)
        end
    end)
end

function LocationManager:Destroy()
    self.running = false
    for i = 1, #self.entries do
        self.entries[i].busy = false
        self.entries[i]:Destroy()
    end
    self.entries = {}
    self.byId    = {}
end

Locations = LocationManager.new()

RegisterNetEvent('nlrp-vplates:client:occupancy', function(locationId, locked)
    if type(locationId) ~= 'string' then return end
    Locations:SetLocked(locationId, locked)
end)

RegisterNetEvent('nlrp-vplates:client:occupancySnapshot', function(state)
    if type(state) ~= 'table' then return end
    for locationId, locked in pairs(state) do
        Locations:SetLocked(locationId, locked)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Locations:Destroy()
    Target:RemoveAll()
end)
