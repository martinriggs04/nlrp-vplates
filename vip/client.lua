--[[
    nlrp-vplates | vip/client.lua  (CLIENT ONLY)

    ###########################################################################
    ##  DEMO SKELETON - UI HINTS ONLY, NEVER A DECISION                      ##
    ###########################################################################

    This side holds nothing but a copy of the status the server pushed. It
    exists so the UI can stay honest (grey out a prompt, show a badge, ...).

    Changing anything here does NOT grant access: the server re-checks VIP on
    `OpenSession` AND again on `Commit`. Faking `isVip = true` locally only
    earns the player a rejected request.
]]

--- Client side status is a mirror, never a lookup.
---@return boolean isVip
---@return string|nil tier
function VipService:IsVIP()
    local status = self.status
    if not status then return false end
    return status.isVip == true, status.tier
end

--- Asks the server for a fresh status. Cheap, rate limited server side.
function VipService:Request()
    TriggerServerEvent('nlrp-vplates:server:requestVipStatus')
end

Vip = VipService.new()

RegisterNetEvent('nlrp-vplates:client:vipStatus', function(payload)
    if type(payload) ~= 'table' then return end

    Vip.status  = payload
    Vip.enabled = payload.enabled == true
    Vip:Invalidate()

    Utils.Debug(('vip status received: enabled=%s vip=%s tier=%s')
        :format(tostring(payload.enabled), tostring(payload.isVip), tostring(payload.tier)))
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Vip:Request()
end)

AddEventHandler('playerSpawned', function()
    Vip:Request()
end)

--- UI helper for other resources. NOT a security check.
exports('IsVIP', function()
    return (Vip:IsVIP())
end)
