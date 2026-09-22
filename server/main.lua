--[[
    nlrp-vplates | server/main.lua  (SERVER ONLY)
    Authoritative plate service.

    Flow (two phases, both server-validated):
      1. OPEN    client asks for a session -> server validates player, vehicle,
                 ownership, money/item and issues a short-lived ticket.
      2. COMMIT  client sends the ticket + the desired plate -> server re-checks
                 everything, charges, writes and broadcasts the new plate.

    The client never decides anything. It only renders.
]]

local STATE_KEY   = 'vplates'
local TICKET_TTL  = 60000

local PlateService = Class('PlateService')

function PlateService:init()
    self.tickets    = {}  -- [src]    = ticket
    self.fakes      = {}  -- [netId]  = { plate, original, entity, src, expires }
    self.fakeByKey  = {}  -- [key]    = netId
    self.ticketSeq  = 0

    self:_startJanitor()
end

-- ── helpers ────────────────────────────────────────────────────────────────

---@param src number
---@param ok boolean
---@param messageKey string
---@param ... any
function PlateService:_reply(src, ok, messageKey, ...)
    TriggerClientEvent('nlrp-vplates:client:result', src, ok, L(messageKey, ...))
end

---@param src number
---@param reason string
---@param detail any
function PlateService:_deny(src, reason, detail)
    Logger:Denied(src, reason, detail)
end

---@param entity number
---@return string
function PlateService:_originalPlate(entity)
    local state = Entity(entity).state[STATE_KEY]
    if type(state) == 'table' and type(state.original) == 'string' then
        return state.original
    end
    return Utils.Trim(GetVehicleNumberPlateText(entity) or '')
end

---@param entity number
---@return string
function PlateService:_currentPlate(entity)
    local state = Entity(entity).state[STATE_KEY]
    if type(state) == 'table' and type(state.plate) == 'string' then
        return state.plate
    end
    return Utils.Trim(GetVehicleNumberPlateText(entity) or '')
end

--- A plate is free when no owned vehicle uses it, no live fake plate does and
--- nobody has reserved it for a scene that is still running.
---@param plate string
---@param ignoreNetId number|nil
---@param src number|nil reservation owner allowed to keep its own plate
---@return boolean
function PlateService:_isPlateFree(plate, ignoreNetId, src)
    if not Config.Plate.EnforceUniqueness then return true end

    local key = Utils.Key(plate)

    local holder = self.fakeByKey[key]
    if holder and holder ~= ignoreNetId then return false end

    if Occupancy:IsPlateReserved(plate, src) then return false end

    return not Ownership:IsTaken(plate)
end

---@param entity number
---@param plate string
---@param original string
---@param fake boolean
function PlateService:_apply(entity, plate, original, fake)
    Entity(entity).state:set(STATE_KEY, {
        plate    = plate,
        original = original,
        fake     = fake,
    }, true)
end

-- ── phase 1: session ───────────────────────────────────────────────────────

--- The clerk physically walks to the vehicle, so it has to be parked within
--- walking range of his desk. The coordinates are read from the entity, not
--- assumed from the player position: the two can be far apart.
---@param entity number vehicle entity
---@param location table
---@return boolean tooFar, number distance (rounded, for the message)
function PlateService:_vehicleTooFar(entity, location)
    if not Config.Scene.Enabled then return false, 0 end

    local anchor   = location.coords
    local distance = #(GetEntityCoords(entity) - vector3(anchor.x, anchor.y, anchor.z))

    return distance > Config.Scene.MaxVehicleDistance, math.floor(distance + 0.5)
end

---@param src number
---@param mode string 'legal'|'fake'
---@param payload table
function PlateService:OpenSession(src, mode, payload)
    if not Security:CheckRate(src) then
        Security:Strike(src, L('sec.rate_limit'))
        return self:_reply(src, false, 'msg.denied')
    end

    if type(payload) ~= 'table' then
        Security:Strike(src, L('sec.invalid_payload'))
        return self:_reply(src, false, 'msg.denied')
    end

    local entity, reason = Security:ResolveVehicle(src, payload.netId)
    if not entity then
        self:_deny(src, reason, payload.netId)
        return self:_reply(src, false, 'msg.no_vehicle')
    end

    local netId        = payload.netId
    local original     = self:_originalPlate(entity)
    local current      = self:_currentPlate(entity)
    local identifier   = Framework:GetIdentifier(src)
    local ticket

    if mode == 'legal' then
        local location, locReason = Security:ResolveLocation(src, payload.locationId)
        if not location then
            Security:Strike(src, locReason or L('sec.bad_location_id'))
            return self:_reply(src, false, 'msg.denied')
        end

        -- VIP gate. Rejected here so the UI never even opens.
        if not Vip:CanUse(src, 'legal') then
            self:_deny(src, L('sec.vip_denied'), original)
            return self:_reply(src, false, 'msg.vip_only')
        end

        if not Ownership.enabled then
            return self:_reply(src, false, 'msg.not_owner')
        end

        if not Ownership:IsOwnedBy(original, identifier) then
            self:_deny(src, L('sec.not_owner'), original)
            return self:_reply(src, false, 'msg.not_owner')
        end

        local ready, remaining = Security.vehicleLegalCd:Check(Utils.Key(original))
        if not ready then
            return self:_reply(src, false, 'msg.cooldown', remaining)
        end

        local pay   = Config.Locations.Payment
        local price = tonumber(location.price) or pay.Price

        if pay.Enabled and price > 0 and Framework:GetMoney(src, pay.Account) < price then
            return self:_reply(src, false, 'msg.no_money', price)
        end

        if pay.RequireItem and not Inventory:Has(src, pay.Item, pay.ItemAmount) then
            return self:_reply(src, false, 'msg.no_item')
        end

        -- The clerk can only serve one customer at a time.
        if not Occupancy:IsClerkFree(location.id) then
            return self:_reply(src, false, 'msg.npc_busy')
        end

        -- The clerk walks to the vehicle, so it has to be within walking
        -- range of his desk. Checked here so the UI never even opens.
        local far, distance = self:_vehicleTooFar(entity, location)
        if far then
            return self:_reply(src, false, 'msg.too_far', distance)
        end

        ticket = {
            mode       = 'legal',
            location   = location,
            price      = price,
            duration   = Config.Locations.Duration,
        }
    elseif mode == 'fake' then
        if Inventory.name == 'none' then
            return self:_reply(src, false, 'msg.no_item')
        end

        -- Off by default: fake plates are the criminal path, open to everyone.
        if not Vip:CanUse(src, 'fake') then
            self:_deny(src, L('sec.vip_denied'), original)
            return self:_reply(src, false, 'msg.vip_only')
        end

        if not Inventory:Has(src, Config.FakePlate.Item, Config.FakePlate.ItemAmount) then
            return self:_reply(src, false, 'msg.no_item')
        end

        local ready, remaining = Security.playerFakeCd:Check(src)
        if not ready then
            return self:_reply(src, false, 'msg.cooldown', remaining)
        end

        -- Hard rule: fake plates never work on a legally registered vehicle.
        if not Config.FakePlate.AllowOnOwnedVehicles and Ownership:IsOwned(original) then
            return self:_reply(src, false, 'msg.owned_vehicle')
        end

        ticket = {
            mode     = 'fake',
            price    = 0,
            duration = Config.FakePlate.Duration,
        }
    else
        Security:Strike(src, L('sec.unknown_mode', tostring(mode)))
        return self:_reply(src, false, 'msg.denied')
    end

    self.ticketSeq = self.ticketSeq + 1

    local now = GetGameTimer()
    ticket.id        = ('%d:%d'):format(self.ticketSeq, math.random(100000, 999999))
    ticket.src       = src
    ticket.netId     = netId
    ticket.original  = original
    ticket.current   = current
    ticket.issuedAt  = now
    ticket.notBefore = now + math.floor(ticket.duration * 0.85)
    ticket.expires   = now + TICKET_TTL + ticket.duration

    self.tickets[src] = ticket

    -- Legal changes at a manned location play the clerk scene instead of a
    -- plain progress bar, which adds the reservation phase in between.
    local useScene = ticket.mode == 'legal'
        and Config.Scene.Enabled
        and ticket.location
        and ticket.location.ped ~= nil
        and ticket.location.ped ~= false

    ticket.scene = useScene

    TriggerClientEvent('nlrp-vplates:client:openUI', src, {
        ticket   = ticket.id,
        mode     = ticket.mode,
        plate    = current,
        price    = ticket.price,
        duration = ticket.duration,
        scene    = useScene,
        maxLen   = Config.Plate.MaxLength,
        minLen   = Config.Plate.MinLength,
    })
end

-- ── phase 1.5: reservation (scene flow only) ───────────────────────────────

--- Validates the chosen plate, locks the clerk and reserves the plate, then
--- tells every client to play the scene.
---
--- From here on the plate is FIXED SERVER SIDE: the commit no longer accepts
--- one from the client, so nothing can be swapped while the clerk is walking.
---@param src number
---@param ticketId any
---@param rawPlate any
function PlateService:Reserve(src, ticketId, rawPlate)
    if not Security:CheckRate(src) then
        Security:Strike(src, L('sec.rate_limit'))
        return self:_reply(src, false, 'msg.denied')
    end

    local ticket = self.tickets[src]
    if not ticket or ticket.id ~= ticketId or not ticket.scene or ticket.reserved then
        Security:Strike(src, L('sec.bad_ticket'))
        return self:_reply(src, false, 'msg.denied')
    end

    if GetGameTimer() > ticket.expires then
        self.tickets[src] = nil
        return self:_reply(src, false, 'msg.denied')
    end

    local entity, reason = Security:ResolveVehicle(src, ticket.netId)
    if not entity then
        self.tickets[src] = nil
        self:_deny(src, reason, ticket.netId)
        return self:_reply(src, false, 'msg.no_vehicle')
    end

    if not Vip:CanUse(src, 'legal') then
        self.tickets[src] = nil
        self:_deny(src, L('sec.vip_denied'), ticket.original)
        return self:_reply(src, false, 'msg.vip_only')
    end

    local original = self:_originalPlate(entity)

    if not Ownership:IsOwnedBy(original, Framework:GetIdentifier(src)) then
        self.tickets[src] = nil
        self:_deny(src, L('sec.not_owner'), original)
        return self:_reply(src, false, 'msg.not_owner')
    end

    local plate = Utils.Sanitize(rawPlate)
    local valid, reasonKey, reasonArg = Utils.Validate(plate, 'legal')
    if not valid then
        return self:_reply(src, false, reasonKey, reasonArg)
    end

    if Utils.PlateEquals(plate, self:_currentPlate(entity)) then
        return self:_reply(src, false, 'msg.plate_same')
    end

    -- Database check happens here, before the clerk moves a muscle.
    if not self:_isPlateFree(plate, ticket.netId, src) then
        return self:_reply(src, false, 'msg.plate_taken')
    end

    -- Re-checked here: the vehicle may have been driven away while the
    -- player was typing the plate into the dialog.
    local far, distance = self:_vehicleTooFar(entity, ticket.location)
    if far then
        return self:_reply(src, false, 'msg.too_far', distance)
    end

    if not Occupancy:AcquireClerk(ticket.location.id, src, ticket.netId) then
        return self:_reply(src, false, 'msg.npc_busy')
    end

    if not Occupancy:ReservePlate(plate, src) then
        Occupancy:ReleaseClerk(ticket.location.id, src)
        return self:_reply(src, false, 'msg.plate_taken')
    end

    local now     = GetGameTimer()
    local minTime = Scene.WorkTime()

    ticket.reserved  = true
    ticket.plate     = plate
    ticket.original  = original
    ticket.notBefore = now + math.floor(minTime * 0.85)
    ticket.expires   = now + Scene.MaxTime()

    -- Broadcast: every client that has this clerk streamed in plays the same
    -- scene, so the whole street sees it. Only the requester reports back.
    local worn = self:_currentPlate(entity)

    for _, playerId in ipairs(GetPlayers()) do
        local target = tonumber(playerId)
        TriggerClientEvent('nlrp-vplates:client:sceneStart', target, {
            locationId = ticket.location.id,
            netId      = ticket.netId,
            ticket     = ticket.id,
            -- Lets a client that cannot resolve the network id find the
            -- vehicle by the plate it is still wearing.
            plate      = worn,
            mine       = target == src,
        })
    end
end

--- Frees whatever a ticket was holding. Safe to call twice.
---@param ticket table|nil
--- Frees whatever a ticket was holding. Safe to call twice.
---
--- `keepClerk` is used when the plates are already fitted but the clerk still
--- has to walk back to his desk: he must stay unavailable until he is home,
--- which the client confirms with `sceneFinished`.
---@param ticket table|nil
---@param keepClerk boolean|nil
function PlateService:_releaseTicket(ticket, keepClerk)
    if not ticket or not ticket.reserved then return end
    ticket.reserved = false

    if ticket.plate then Occupancy:ReleasePlate(ticket.plate, ticket.src) end

    if keepClerk then return end
    if ticket.location then Occupancy:ReleaseClerk(ticket.location.id, ticket.src) end
end

-- ── phase 2: commit ────────────────────────────────────────────────────────

---@param src number
---@param ticketId any
---@param rawPlate any
function PlateService:Commit(src, ticketId, rawPlate)
    if not Security:CheckRate(src) then
        Security:Strike(src, L('sec.rate_limit'))
        return self:_reply(src, false, 'msg.denied')
    end

    local ticket = self.tickets[src]
    if not ticket or ticket.id ~= ticketId then
        Security:Strike(src, L('sec.bad_ticket'))
        return self:_reply(src, false, 'msg.denied')
    end

    local now = GetGameTimer()
    self.tickets[src] = nil

    if now > ticket.expires then
        self:_releaseTicket(ticket)
        return self:_reply(src, false, 'msg.denied')
    end

    if now < ticket.notBefore then
        self:_releaseTicket(ticket)
        Security:Strike(src, L('sec.fast_commit'))
        return self:_reply(src, false, 'msg.denied')
    end

    -- The scene flow must go through Reserve first; a direct commit is a bypass.
    if ticket.scene and not ticket.reserved then
        self:_releaseTicket(ticket)
        Security:Strike(src, L('sec.bad_ticket'))
        return self:_reply(src, false, 'msg.denied')
    end

    if not Security:Acquire(src) then
        self:_releaseTicket(ticket)
        return self:_reply(src, false, 'msg.busy')
    end

    local released = false
    local function finish(ok, key, ...)
        if not released then
            released = true
            Security:Release(src)
            -- On success the clerk keeps working: he still has to walk back.
            self:_releaseTicket(ticket, ok == true and ticket.scene)
        end
        self:_reply(src, ok, key, ...)
    end

    -- Re-validate the vehicle: it may have despawned or moved away meanwhile.
    local entity, reason = Security:ResolveVehicle(src, ticket.netId)
    if not entity then
        self:_deny(src, reason, ticket.netId)
        return finish(false, 'msg.no_vehicle')
    end

    -- Reserved tickets carry their own plate; anything the client sends now is
    -- ignored on purpose so the scene cannot be used to smuggle a new value.
    local plate = ticket.reserved and ticket.plate or Utils.Sanitize(rawPlate)
    local valid, reasonKey, reasonArg = Utils.Validate(plate, ticket.mode)
    if not valid then
        return finish(false, reasonKey, reasonArg)
    end

    local original = self:_originalPlate(entity)
    local current  = self:_currentPlate(entity)

    if Utils.PlateEquals(plate, current) then
        return finish(false, 'msg.plate_same')
    end

    if not self:_isPlateFree(plate, ticket.netId, src) then
        return finish(false, 'msg.plate_taken')
    end

    -- Re-checked on commit: VIP could have expired between the two phases.
    if not Vip:CanUse(src, ticket.mode) then
        self:_deny(src, L('sec.vip_denied'), original)
        return finish(false, 'msg.vip_only')
    end

    if ticket.mode == 'legal' then
        return self:_commitLegal(src, ticket, entity, original, plate, finish)
    end

    return self:_commitFake(src, ticket, entity, original, plate, finish)
end

function PlateService:_commitLegal(src, ticket, entity, original, plate, finish)
    local identifier = Framework:GetIdentifier(src)

    if not Ownership:IsOwnedBy(original, identifier) then
        self:_deny(src, L('sec.not_owner'), original)
        return finish(false, 'msg.not_owner')
    end

    local pay     = Config.Locations.Payment
    local price   = ticket.price
    local charged = false
    local tookItem = false

    if pay.Enabled and price > 0 then
        if not Framework:RemoveMoney(src, pay.Account, price) then
            return finish(false, 'msg.no_money', price)
        end
        charged = true
    end

    if pay.RequireItem then
        if not Inventory:Remove(src, pay.Item, pay.ItemAmount) then
            if charged then Framework:AddMoney(src, pay.Account, price) end
            return finish(false, 'msg.no_item')
        end
        tookItem = true
    end

    local written = Ownership:UpdatePlate(original, plate, identifier)
    if not written then
        if charged then Framework:AddMoney(src, pay.Account, price) end
        if tookItem then Inventory:Add(src, pay.Item, pay.ItemAmount) end
        self:_deny(src, L('sec.db_failed'), original)
        return finish(false, 'msg.db_error')
    end

    -- A legal change replaces the identity of the vehicle: the new plate
    -- becomes the original one, and any fake plate on it is dropped.
    self:_clearFake(ticket.netId)
    self:_apply(entity, plate, plate, false)

    Security.vehicleLegalCd:Start(Utils.Key(original))
    Security.vehicleLegalCd:Start(Utils.Key(plate))

    Logger:LegalChange(src, original, plate, ticket.location, price)
    TriggerEvent('nlrp-vplates:server:plateChanged', src, original, plate, 'legal')

    return finish(true, 'msg.success', plate)
end

function PlateService:_commitFake(src, ticket, entity, original, plate, finish)
    if not Config.FakePlate.AllowOnOwnedVehicles and Ownership:IsOwned(original) then
        return finish(false, 'msg.owned_vehicle')
    end

    if Config.FakePlate.ConsumeItem then
        if not Inventory:Remove(src, Config.FakePlate.Item, Config.FakePlate.ItemAmount) then
            return finish(false, 'msg.no_item')
        end
    end

    local netId = ticket.netId
    self:_clearFake(netId)

    local expires = Config.FakePlate.Expiry > 0
        and (GetGameTimer() + Config.FakePlate.Expiry * 1000) or nil

    self.fakes[netId] = {
        plate    = plate,
        original = original,
        entity   = entity,
        src      = src,
        expires  = expires,
    }
    self.fakeByKey[Utils.Key(plate)] = netId

    self:_apply(entity, plate, original, true)

    Security.playerFakeCd:Start(src)

    Logger:FakePlate(src, original, plate, GetEntityModel(entity))
    TriggerEvent('nlrp-vplates:server:plateChanged', src, original, plate, 'fake')

    return finish(true, 'msg.success_fake', plate)
end

---@param netId number
function PlateService:_clearFake(netId)
    local entry = self.fakes[netId]
    if not entry then return end
    self.fakeByKey[Utils.Key(entry.plate)] = nil
    self.fakes[netId] = nil
end

--- Restores the original plate of a faked vehicle (expiry or manual removal).
---@param netId number
function PlateService:RevertFake(netId)
    local entry = self.fakes[netId]
    if not entry then return false end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        self:_apply(entity, entry.original, entry.original, false)
    end

    self:_clearFake(netId)
    return true
end

-- ── janitor: drops dead/expired entries, keeps the registry tiny ───────────

function PlateService:_startJanitor()
    CreateThread(function()
        while true do
            Wait(30000)

            local now = GetGameTimer()

            for netId, entry in pairs(self.fakes) do
                local entity = NetworkGetEntityFromNetworkId(netId)
                local alive  = entity and entity ~= 0 and DoesEntityExist(entity)

                if not alive then
                    self:_clearFake(netId)
                elseif entry.expires and now >= entry.expires then
                    self:RevertFake(netId)
                end
            end

            for src, ticket in pairs(self.tickets) do
                if now > ticket.expires then
                    self.tickets[src] = nil
                    self:_releaseTicket(ticket)
                end
            end
        end
    end)
end

function PlateService:OnPlayerDropped(src)
    local ticket = self.tickets[src]
    self.tickets[src] = nil
    self:_releaseTicket(ticket)
    Occupancy:ReleaseBySource(src)
end

Plates = PlateService.new()

-- ═══════════════════════════════════════════════════════════════════════════
-- Net events
-- ═══════════════════════════════════════════════════════════════════════════

RegisterNetEvent('nlrp-vplates:server:openSession', function(mode, payload)
    Plates:OpenSession(source, mode, payload)
end)

RegisterNetEvent('nlrp-vplates:server:reserve', function(ticketId, plate)
    Plates:Reserve(source, ticketId, plate)
end)

RegisterNetEvent('nlrp-vplates:server:commit', function(ticketId, plate)
    Plates:Commit(source, ticketId, plate)
end)

--- The clerk is back at his desk: release him for the next customer.
--- Only the player holding the lock can release it, and the occupancy janitor
--- covers the case where this never arrives (crash, disconnect, resource stop).
RegisterNetEvent('nlrp-vplates:server:sceneFinished', function(_, locationId)
    if type(locationId) ~= 'string' then return end
    Occupancy:ReleaseClerk(locationId, source)
end)

RegisterNetEvent('nlrp-vplates:server:cancel', function()
    local src = source
    local ticket = Plates.tickets[src]
    Plates.tickets[src] = nil
    Plates:_releaseTicket(ticket)
    Occupancy:ReleaseBySource(src)
    Security:Release(src)
end)

AddEventHandler('playerDropped', function()
    Plates:OnPlayerDropped(source)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- Fake plate item
-- ═══════════════════════════════════════════════════════════════════════════

local function onUseFakePlate(src)
    if not src or src <= 0 then return end
    TriggerClientEvent('nlrp-vplates:client:useFakePlate', src)
end

--- ox_inventory: point the item at this export in your items.lua
---   ['fake_plates'] = { server = { export = 'nlrp-vplates.useFakePlate' } }
exports('useFakePlate', function(event, item, inventory)
    if event ~= 'usingItem' then return end
    onUseFakePlate(inventory.id)
    return false -- never auto-consume: the server consumes it on commit
end)

CreateThread(function()
    local item = Config.FakePlate.Item

    if Framework.name == 'qbx' then
        pcall(function() exports.qbx_core:CreateUseableItem(item, onUseFakePlate) end)
    elseif Framework.name == 'qb' and Framework.core then
        pcall(function() Framework.core.Functions.CreateUseableItem(item, onUseFakePlate) end)
    elseif Framework.name == 'esx' and Framework.core then
        pcall(function()
            Framework.core.RegisterUsableItem(item, onUseFakePlate)
        end)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- Public exports (for other resources)
-- ═══════════════════════════════════════════════════════════════════════════

exports('GetOriginalPlate', function(netId)
    local entry = Plates.fakes[netId]
    return entry and entry.original or nil
end)

exports('IsPlateFake', function(plate)
    return Plates.fakeByKey[Utils.Key(plate)] ~= nil
end)

exports('RevertFakePlate', function(netId)
    return Plates:RevertFake(netId)
end)

exports('IsPlateOwned', function(plate)
    return Ownership:IsOwned(plate)
end)

--- Random plate that satisfies the configured format mask.
--- Returns nil when no format is configured for that mode.
---@param mode string|nil 'legal'|'fake'
exports('GeneratePlate', function(mode)
    local plateFormat = Formats:Get(mode)
    return plateFormat and plateFormat:Generate() or nil
end)

--- Does a plate satisfy the configured format mask? Free-form = always true.
---@param plate string
---@param mode string|nil 'legal'|'fake'
exports('MatchesPlateFormat', function(plate, mode)
    local plateFormat = Formats:Get(mode)
    if not plateFormat then return true end
    return plateFormat:Matches(Utils.Sanitize(plate))
end)
