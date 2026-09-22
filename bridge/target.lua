--[[
    nlrp-vplates | bridge/target.lua  (CLIENT ONLY)
    Interaction abstraction: ox_target, qb-target, interact, PolyZone and a
    dependency-free native fallback all expose the exact same three methods.

    Zones are only ever created once, at resource start, and destroyed on stop.
]]

local ZONE_PREFIX = 'nlrp_vplates_'

local TargetAdapter = Class('TargetAdapter')

function TargetAdapter:init()
    self.name    = 'native'
    self.handles = {}
end

---@return boolean
function TargetAdapter:IsAvailable() return true end

---@param id string
---@param entity number
---@param opts table { label, icon, distance, onSelect, canInteract }
function TargetAdapter:AddEntity(id, entity, opts) end

---@param id string
---@param coords vector3
---@param opts table { label, icon, distance, radius, onSelect }
function TargetAdapter:AddCoords(id, coords, opts) end

---@param id string
function TargetAdapter:Remove(id) end

function TargetAdapter:RemoveAll()
    for id in pairs(self.handles) do self:Remove(id) end
    self.handles = {}
end

-- ── ox_target ───────────────────────────────────────────────────────────────

local OxTarget = Class('OxTarget', TargetAdapter)

function OxTarget:init()
    TargetAdapter.init(self)
    self.name = 'ox_target'
end

function OxTarget:IsAvailable() return Utils.ResourceReady('ox_target') end

function OxTarget:AddEntity(id, entity, opts)
    local name = ZONE_PREFIX .. id
    exports.ox_target:addLocalEntity(entity, {
        {
            name        = name,
            icon        = opts.icon or 'fa-solid fa-id-card',
            label       = opts.label,
            distance    = opts.distance or 2.5,
            canInteract = opts.canInteract,
            onSelect    = opts.onSelect,
        },
    })
    self.handles[id] = { kind = 'entity', entity = entity, name = name }
end

function OxTarget:AddCoords(id, coords, opts)
    local name = ZONE_PREFIX .. id
    local handle = exports.ox_target:addSphereZone({
        coords   = coords,
        radius   = opts.radius or 1.5,
        debug    = Config.Debug,
        options  = {
            {
                name        = name,
                icon        = opts.icon or 'fa-solid fa-id-card',
                label       = opts.label,
                distance    = opts.distance or 2.5,
                canInteract = opts.canInteract,
                onSelect    = opts.onSelect,
            },
        },
    })
    self.handles[id] = { kind = 'zone', handle = handle }
end

function OxTarget:Remove(id)
    local h = self.handles[id]
    if not h then return end
    if h.kind == 'entity' then
        if DoesEntityExist(h.entity) then
            exports.ox_target:removeLocalEntity(h.entity, { h.name })
        end
    else
        exports.ox_target:removeZone(h.handle)
    end
    self.handles[id] = nil
end

-- ── qb-target ───────────────────────────────────────────────────────────────

local QBTarget = Class('QBTarget', TargetAdapter)

function QBTarget:init()
    TargetAdapter.init(self)
    self.name = 'qb-target'
end

function QBTarget:IsAvailable() return Utils.ResourceReady('qb-target') end

function QBTarget:_options(id, opts)
    return {
        {
            type     = 'client',
            icon     = opts.icon or 'fas fa-id-card',
            label    = opts.label,
            action   = opts.onSelect,
            canInteract = opts.canInteract,
        },
    }
end

function QBTarget:AddEntity(id, entity, opts)
    exports['qb-target']:AddTargetEntity(entity, {
        options  = self:_options(id, opts),
        distance = opts.distance or 2.5,
    })
    self.handles[id] = { kind = 'entity', entity = entity }
end

function QBTarget:AddCoords(id, coords, opts)
    local name = ZONE_PREFIX .. id
    local radius = opts.radius or 1.5
    exports['qb-target']:AddCircleZone(name, vector3(coords.x, coords.y, coords.z), radius, {
        name  = name,
        debugPoly = Config.Debug,
        useZ  = true,
    }, {
        options  = self:_options(id, opts),
        distance = opts.distance or 2.5,
    })
    self.handles[id] = { kind = 'zone', name = name }
end

function QBTarget:Remove(id)
    local h = self.handles[id]
    if not h then return end
    if h.kind == 'entity' then
        if DoesEntityExist(h.entity) then
            exports['qb-target']:RemoveTargetEntity(h.entity)
        end
    else
        exports['qb-target']:RemoveZone(h.name)
    end
    self.handles[id] = nil
end

-- ── interact ────────────────────────────────────────────────────────────────

local InteractTarget = Class('InteractTarget', TargetAdapter)

function InteractTarget:init()
    TargetAdapter.init(self)
    self.name = 'interact'
end

function InteractTarget:IsAvailable() return Utils.ResourceReady('interact') end

function InteractTarget:AddEntity(id, entity, opts)
    local name = ZONE_PREFIX .. id
    exports.interact:AddLocalEntityInteraction({
        entity      = entity,
        id          = name,
        distance    = (opts.distance or 2.5) + 3.0,
        interactDst = opts.distance or 2.5,
        name        = name,
        options     = {
            {
                label  = opts.label,
                action = opts.onSelect,
                canInteract = opts.canInteract,
            },
        },
    })
    self.handles[id] = { kind = 'entity', entity = entity, name = name }
end

function InteractTarget:AddCoords(id, coords, opts)
    local name = ZONE_PREFIX .. id
    exports.interact:AddInteraction({
        coords      = vector3(coords.x, coords.y, coords.z),
        id          = name,
        distance    = (opts.distance or 2.5) + 3.0,
        interactDst = opts.distance or 2.5,
        name        = name,
        options     = {
            {
                label  = opts.label,
                action = opts.onSelect,
                canInteract = opts.canInteract,
            },
        },
    })
    self.handles[id] = { kind = 'zone', name = name }
end

function InteractTarget:Remove(id)
    local h = self.handles[id]
    if not h then return end
    if h.kind == 'entity' then
        if DoesEntityExist(h.entity) then
            exports.interact:RemoveLocalEntityInteraction(h.entity, h.name)
        end
    else
        exports.interact:RemoveInteraction(h.name)
    end
    self.handles[id] = nil
end

-- ── Native proximity fallback (also the base for PolyZone) ──────────────────
-- One single thread for every zone, with adaptive sleep:
--   * 1500 ms when the player is far from all zones
--   * 0 ms only while actually standing inside one (to catch the keypress)

local NativeTarget = Class('NativeTarget', TargetAdapter)

function NativeTarget:init()
    TargetAdapter.init(self)
    self.name    = 'native'
    self.zones   = {}
    self.count   = 0
    self.running = false
    self.active  = nil
end

function NativeTarget:IsAvailable() return true end

function NativeTarget:_register(id, coords, opts)
    self.zones[id] = {
        id       = id,
        coords   = vector3(coords.x, coords.y, coords.z),
        radius   = opts.radius or 1.5,
        distance = opts.distance or 2.5,
        label    = opts.label,
        onSelect = opts.onSelect,
        canInteract = opts.canInteract,
    }
    self.handles[id] = true
    self.count = self.count + 1
    self:_start()
end

function NativeTarget:AddCoords(id, coords, opts)
    self:_register(id, coords, opts)
end

function NativeTarget:AddEntity(id, entity, opts)
    -- Entities are static peds here: anchor on their spawn position.
    local coords = GetEntityCoords(entity)
    self:_register(id, coords, opts)
end

function NativeTarget:Remove(id)
    if self.zones[id] then
        self.zones[id] = nil
        self.handles[id] = nil
        self.count = self.count - 1
        if self.active == id then
            self.active = nil
            TriggerEvent('nlrp-vplates:client:hidePrompt')
        end
    end
end

function NativeTarget:_start()
    if self.running then return end
    self.running = true

    CreateThread(function()
        while self.running and self.count > 0 do
            local sleep = 1000
            local ped   = PlayerPedId()
            local pos   = GetEntityCoords(ped)
            local inside

            for id, zone in pairs(self.zones) do
                local dist = #(pos - zone.coords)
                if dist <= zone.distance then
                    inside = zone
                    sleep  = 0
                    break
                elseif dist <= 25.0 then
                    sleep = 250
                end
            end

            if inside then
                if self.active ~= inside.id then
                    self.active = inside.id
                    TriggerEvent('nlrp-vplates:client:showPrompt', inside.label)
                end
                if IsControlJustReleased(0, 38) then -- E
                    TriggerEvent('nlrp-vplates:client:hidePrompt')
                    self.active = nil
                    local allowed = not inside.canInteract or inside.canInteract() ~= false
                    if allowed then inside.onSelect() end
                    Wait(500)
                end
            elseif self.active then
                self.active = nil
                TriggerEvent('nlrp-vplates:client:hidePrompt')
            end

            Wait(sleep)
        end

        self.running = false
    end)
end

function NativeTarget:RemoveAll()
    self.running = false
    self.zones   = {}
    self.handles = {}
    self.count   = 0
    self.active  = nil
end

-- ── PolyZone ────────────────────────────────────────────────────────────────
-- Uses PolyZone's own optimised in/out detection instead of our loop.

local PolyZoneTarget = Class('PolyZoneTarget', NativeTarget)

function PolyZoneTarget:init()
    NativeTarget.init(self)
    self.name  = 'polyzone'
    self.polys = {}
end

function PolyZoneTarget:IsAvailable()
    return Utils.ResourceReady('PolyZone') and CircleZone ~= nil
end

function PolyZoneTarget:_register(id, coords, opts)
    local zone = CircleZone:Create(vector3(coords.x, coords.y, coords.z), opts.distance or 2.5, {
        name      = ZONE_PREFIX .. id,
        useZ      = true,
        debugPoly = Config.Debug,
    })

    local state = { inside = false, thread = false }

    zone:onPlayerInOut(function(isInside)
        state.inside = isInside

        if isInside then
            TriggerEvent('nlrp-vplates:client:showPrompt', opts.label)
            if state.thread then return end
            state.thread = true

            CreateThread(function()
                while state.inside do
                    if IsControlJustReleased(0, 38) then
                        TriggerEvent('nlrp-vplates:client:hidePrompt')
                        local allowed = not opts.canInteract or opts.canInteract() ~= false
                        if allowed then opts.onSelect() end
                        Wait(500)
                    end
                    Wait(0)
                end
                state.thread = false
            end)
        else
            TriggerEvent('nlrp-vplates:client:hidePrompt')
        end
    end)

    self.polys[id]   = zone
    self.handles[id] = true
end

function PolyZoneTarget:Remove(id)
    local zone = self.polys[id]
    if zone then
        zone:destroy()
        self.polys[id] = nil
    end
    self.handles[id] = nil
end

function PolyZoneTarget:RemoveAll()
    for id in pairs(self.polys) do self:Remove(id) end
    self.polys   = {}
    self.handles = {}
end

-- ── Resolver ────────────────────────────────────────────────────────────────

local ORDER = {
    { key = 'ox_target', cls = OxTarget },
    { key = 'qb-target', cls = QBTarget },
    { key = 'interact',  cls = InteractTarget },
    { key = 'polyzone',  cls = PolyZoneTarget },
    { key = 'native',    cls = NativeTarget },
}

local function resolve()
    local forced = Config.Target

    if forced ~= 'auto' then
        for i = 1, #ORDER do
            if ORDER[i].key == forced then
                local adapter = ORDER[i].cls.new()
                if adapter:IsAvailable() then return adapter end
                Utils.Warn(('target "%s" forced but unavailable -> native fallback'):format(forced))
                return NativeTarget.new()
            end
        end
        Utils.Error(('unknown target in config: "%s"'):format(tostring(forced)))
    end

    for i = 1, #ORDER do
        local adapter = ORDER[i].cls.new()
        if adapter:IsAvailable() then return adapter end
    end

    return NativeTarget.new()
end

Target = resolve()

Utils.Debug('target =', Target.name)
