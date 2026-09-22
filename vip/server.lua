--[[
    nlrp-vplates | vip/server.lua  (SERVER ONLY)

    ###########################################################################
    ##  DEMO SKELETON - WRITE YOUR OWN LOGIC HERE                            ##
    ###########################################################################

    Everything below is scaffolding. The only function you have to fill in is
    `VipService:IsVIP(source)`. Three common implementations are provided as
    commented examples; delete the ones you do not need.

    Contract:
        @param  source number  the player's server id
        @return boolean        true ONLY when the player really is VIP
        @return string|nil     optional tier name, forwarded to the Discord logs

    Hard requirements:
      * Never return true by accident. The default is `false` on purpose.
      * Keep it cheap. The result is cached for `Config.VIP.CacheSeconds`, but
        it still runs on a player-triggered path.
      * Do NOT await here if you can avoid it. If your check has to hit the
        database, cache it on player load instead of querying per request.
]]

---@param source number
---@return boolean isVip
---@return string|nil tier
function VipService:IsVIP(source)
    if not source or source <= 0 then return false end

    -- =======================================================================
    -- EXAMPLE 1 - ACE permission (server.cfg: `add_principal identifier.fivem:1 group.vip`)
    -- =======================================================================
    -- if IsPlayerAceAllowed(source, 'vplates.vip') then
    --     return true, Config.VIP.AceGroup
    -- end

    -- =======================================================================
    -- EXAMPLE 2 - static identifier whitelist
    -- =======================================================================
    -- local whitelist = {
    --     ['license:0000000000000000000000000000000000000000'] = 'gold',
    -- }
    -- for i = 0, GetNumPlayerIdentifiers(source) - 1 do
    --     local tier = whitelist[GetPlayerIdentifier(source, i)]
    --     if tier then return true, tier end
    -- end

    -- =======================================================================
    -- EXAMPLE 3 - your own database / framework metadata
    -- =======================================================================
    -- local identifier = Framework:GetIdentifier(source)
    -- if not identifier then return false end
    --
    -- local row = Database:Single('SELECT tier FROM vip_users WHERE identifier = ? AND expires > NOW()', { identifier })
    -- if row and row.tier then return true, row.tier end

    -- =======================================================================
    -- DEFAULT: fail-safe. Remove this line once your logic above is live.
    -- =======================================================================
    return Config.VIP.DefaultResult == true, nil
end

Vip = VipService.new()

-- ── status push (UI hints only) ────────────────────────────────────────────

--- The client never decides anything; this only lets the UI stay honest.
---@param src number
local function pushStatus(src)
    local isVip, tier = false, nil

    if Vip:IsEnabled() then
        isVip, tier = Vip:Resolve(src)
    end

    TriggerClientEvent('nlrp-vplates:client:vipStatus', src, {
        enabled = Vip:IsEnabled(),
        isVip   = isVip,
        tier    = tier,
    })
end

RegisterNetEvent('nlrp-vplates:server:requestVipStatus', function()
    local src = source
    if not Security:CheckRate(src) then return end
    pushStatus(src)
end)

AddEventHandler('playerDropped', function()
    Vip:Invalidate(source)
end)

-- ── exports for your own VIP resource ──────────────────────────────────────

--- Authoritative check, usable from any other resource.
---@param source number
exports('IsPlayerVIP', function(source)
    if not Vip:IsEnabled() then return false end
    return (Vip:Resolve(source))
end)

--- Call this the moment a player buys, renews or loses VIP so the cached
--- result is dropped and the client hint is refreshed immediately.
---@param source number|nil nil = flush every cached player
exports('RefreshVIP', function(source)
    Vip:Invalidate(source)

    if source and GetPlayerName(source) then
        pushStatus(source)
    end

    return true
end)
