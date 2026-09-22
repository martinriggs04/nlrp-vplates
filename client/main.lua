--[[
    nlrp-vplates | client/main.lua  (CLIENT ONLY)
    Entry point: wires the interaction flows and boots the location manager.
]]

local FlowController = Class('FlowController')

function FlowController:init()
    self.busy = false
end

---@return boolean
function FlowController:_lock()
    if self.busy or Nui.open or Nui.busy then
        Notify:Send('error', L('msg.busy'))
        return false
    end
    self.busy = true

    -- Safety valve: the lock is always released, even if the server never answers.
    CreateThread(function()
        local guard = GetGameTimer() + 15000
        while self.busy and GetGameTimer() < guard do Wait(500) end
        self.busy = false
    end)

    return true
end

function FlowController:_unlock()
    self.busy = false
end

--- Fixed location flow (legal, permanent, paid).
---@param location table
function FlowController:StartLegal(location)
    if not Framework:IsPlayerLoaded() then return end
    if not self:_lock() then return end

    local cfg = Config.Locations
    local vehicle, reason = Vehicles.Resolve(
        cfg.RequireEngineOff, cfg.RequireOnFoot, cfg.VehicleSearchRadius
    )

    if not vehicle then
        self:_unlock()
        return Notify:Send('error', L(reason))
    end

    TriggerServerEvent('nlrp-vplates:server:openSession', 'legal', {
        netId      = VehToNet(vehicle),
        locationId = location.id,
    })

    self:_unlock()
end

--- Item flow (fake plate, session only, unowned vehicles only).
function FlowController:StartFake()
    if not Framework:IsPlayerLoaded() then return end
    if not self:_lock() then return end

    local cfg = Config.FakePlate
    local vehicle, reason = Vehicles.Resolve(
        cfg.RequireEngineOff, cfg.RequireOnFoot, cfg.MaxDistance
    )

    if not vehicle then
        self:_unlock()
        return Notify:Send('error', L(reason))
    end

    TriggerServerEvent('nlrp-vplates:server:openSession', 'fake', {
        netId = VehToNet(vehicle),
    })

    self:_unlock()
end

Flow = FlowController.new()

RegisterNetEvent('nlrp-vplates:client:useFakePlate', function()
    Flow:StartFake()
end)

CreateThread(function()
    -- Give the framework a moment to report the login state on a live restart.
    Wait(500)
    Locations:Build()
    Utils.Debug(('ready | framework=%s target=%s notify=%s progress=%s')
        :format(Framework.name, Target.name, Notify.name, Progress.name))
end)
