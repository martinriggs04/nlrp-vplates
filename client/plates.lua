--[[
    nlrp-vplates | client/plates.lua  (CLIENT ONLY)
    Applies plate changes broadcast by the server through entity state bags,
    and provides the vehicle lookup helpers used by the interaction flows.

    State bags are the only mechanism used to push a plate: the server owns the
    value, every client (including late joiners) renders the same thing, and the
    value dies together with the entity — which is exactly what "session only"
    fake plates require.
]]

local STATE_KEY = 'vplates'

local PlateRenderer = Class('PlateRenderer')

function PlateRenderer:init()
    self.pending = {}
end

---@param entity number
---@param plate string
function PlateRenderer:_write(entity, plate)
    if not DoesEntityExist(entity) then return end

    -- Only the entity owner can replicate the change; everyone else still sets
    -- it locally so the visual stays consistent on every screen.
    if NetworkGetEntityIsNetworked(entity) and not NetworkHasControlOfEntity(entity) then
        NetworkRequestControlOfEntity(entity)
        local timeout = GetGameTimer() + 500
        while not NetworkHasControlOfEntity(entity) and GetGameTimer() < timeout do
            Wait(0)
        end
    end

    SetVehicleNumberPlateText(entity, plate)
end

--- Waits (briefly) for an entity that was announced before it streamed in.
---@param netId number
---@param plate string
function PlateRenderer:_writeWhenReady(netId, plate)
    if self.pending[netId] then return end
    self.pending[netId] = true

    CreateThread(function()
        local timeout = GetGameTimer() + 10000

        while GetGameTimer() < timeout do
            local entity = NetworkDoesEntityExistWithNetworkId(netId)
                and NetToVeh(netId) or 0

            if entity ~= 0 and DoesEntityExist(entity) then
                self:_write(entity, plate)
                break
            end

            Wait(250)
        end

        self.pending[netId] = nil
    end)
end

Renderer = PlateRenderer.new()

AddStateBagChangeHandler(STATE_KEY, nil, function(bagName, _, value)
    if type(value) ~= 'table' or type(value.plate) ~= 'string' then return end

    local netId = tonumber(bagName:match('^entity:(%d+)$'))
    if not netId then return end

    local entity = NetworkDoesEntityExistWithNetworkId(netId) and NetToVeh(netId) or 0

    if entity ~= 0 and DoesEntityExist(entity) then
        CreateThread(function() Renderer:_write(entity, value.plate) end)
    else
        Renderer:_writeWhenReady(netId, value.plate)
    end
end)

-- ── lookup helpers ─────────────────────────────────────────────────────────

Vehicles = {}

--- Closest vehicle to a point, within `radius`.
---@param coords vector3
---@param radius number
---@return number|nil entity
function Vehicles.GetClosest(coords, radius)
    local best, bestDist = nil, radius

    local pool = GetGamePool('CVehicle')
    for i = 1, #pool do
        local vehicle = pool[i]
        local dist = #(GetEntityCoords(vehicle) - coords)
        if dist < bestDist then
            best, bestDist = vehicle, dist
        end
    end

    return best
end

--- Validates the vehicle the player is about to work on, client side.
--- The server repeats every one of these checks it can verify.
---@param requireEngineOff boolean
---@param requireOnFoot boolean
---@param radius number
---@return number|nil entity
---@return string|nil reasonKey
function Vehicles.Resolve(requireEngineOff, requireOnFoot, radius)
    local ped = PlayerPedId()

    if requireOnFoot and IsPedInAnyVehicle(ped, false) then
        return nil, 'msg.in_vehicle'
    end

    local vehicle = Vehicles.GetClosest(GetEntityCoords(ped), radius)
    if not vehicle then return nil, 'msg.no_vehicle' end

    if requireEngineOff and GetIsVehicleEngineRunning(vehicle) then
        return nil, 'msg.engine_on'
    end

    return vehicle
end

---@param entity number
---@return string
function Vehicles.GetPlate(entity)
    return Utils.Trim(GetVehicleNumberPlateText(entity) or '')
end
