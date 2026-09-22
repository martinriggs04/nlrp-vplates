--[[
    nlrp-vplates | client/scene.lua  (CLIENT ONLY)

    The clerk physically changes the plates.

    Sequence, played on EVERY client that currently has the ped streamed in,
    so the whole street sees the same thing:

        1. drop the idle scenario and unfreeze
        2. take a `p_num_plate_01` plate in hand
        3. walk to the REAR bumper, face the vehicle, work
        4. walk to the FRONT bumper, face the vehicle, work
        5. walk back to the desk, restore the exact original position,
           heading and scenario, put the prop away

    Only the player who requested the change reports the result back to the
    server. Everyone else just watches. The clerk stays locked server side
    until the whole sequence has finished, so a second player cannot start a
    change halfway through.

    Nothing here decides anything: the server already fixed the plate when it
    issued the reservation, and it re-validates everything on commit.
]]

local SceneDirector = Class('SceneDirector')

--- Distance (m) that counts as real progress towards the target.
local PROGRESS_STEP    = 0.25
--- How long the navmesh gets to prove it produced a usable route. It either
--- moves the ped within this window or it never will: the live logs showed
--- the ped standing still for three seconds and then drifting away, and no
--- amount of re-issuing ever recovered it.
local NAVMESH_PROBE    = 1600
--- How long the ped may gain no ground before the task is re-issued.
local PROGRESS_TIMEOUT = 2000
--- Moving this much further away than the start means the task is doing
--- something else entirely, not planning a route around an obstacle.
local WRONG_WAY_MARGIN = 1.0

function SceneDirector:init()
    self.active = {}
end

-- ── helpers ────────────────────────────────────────────────────────────────

---@param model string|number
---@param timeout number
---@return boolean
local function loadModel(model, timeout)
    local hash = type(model) == 'number' and model or joaat(model)
    if HasModelLoaded(hash) then return true, hash end

    RequestModel(hash)
    local deadline = GetGameTimer() + (timeout or 5000)
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end

    return HasModelLoaded(hash), hash
end

---@param dict string
---@return boolean
local function loadAnim(dict)
    if HasAnimDictLoaded(dict) then return true end

    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 5000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do Wait(0) end

    return HasAnimDictLoaded(dict)
end

--- Drops a point onto the ground. Bumper offsets are computed from the
--- vehicle origin, which sits roughly half a metre above the tarmac; pathing
--- to that height makes the ped walk to a spot it can never stand on.
---
--- `referenceZ` (the clerk's own foot height) guards against a bad probe:
--- collision is not always loaded, and a ground hit metres away from the
--- surface everyone is standing on is worse than no correction at all.
---@param pos vector3
---@param referenceZ number|nil
---@return vector3
local function onGround(pos, referenceZ)
    local found, z = GetGroundZFor_3dCoord(pos.x, pos.y, pos.z + 1.0, false)

    if found and (not referenceZ or math.abs(z - referenceZ) <= 3.0) then
        return vector3(pos.x, pos.y, z)
    end

    if referenceZ then return vector3(pos.x, pos.y, referenceZ) end
    return pos
end

--- Horizontal distance only: the ped stands on the floor, the target may not.
---@param a vector3
---@param b vector3
---@return number
local function flatDistance(a, b)
    return #(vector2(a.x, a.y) - vector2(b.x, b.y))
end

--- True when the vehicle really is the one we were told to work on.
--- `resolveVehicle` can otherwise hand back a stale handle or, through the
--- pool scan, a completely different car.
---@param vehicle number
---@param plate string|nil
---@return boolean
local function plateMatches(vehicle, plate)
    if type(plate) ~= 'string' or plate == '' then return true end
    return Utils.Key(GetVehicleNumberPlateText(vehicle)) == Utils.Key(plate)
end

--- Finds a vehicle anywhere in the world by the plate it is currently wearing.
--- Used as a fallback when the network id cannot be resolved locally, which
--- happens whenever the vehicle is not streamed in on this client.
---@param plate string|nil
---@return number vehicle handle, 0 when not found
local function findVehicleByPlate(plate)
    if type(plate) ~= 'string' or plate == '' then return 0 end

    local wanted = Utils.Key(plate)
    local pool   = GetGamePool('CVehicle')

    for i = 1, #pool do
        local vehicle = pool[i]
        if DoesEntityExist(vehicle) and Utils.Key(GetVehicleNumberPlateText(vehicle)) == wanted then
            return vehicle
        end
    end

    return 0
end

--- Network id first, plate lookup second. The network id result is verified
--- against the plate as well, so a recycled handle can never send the clerk
--- to the wrong car.
---@param netId number
---@param plate string|nil
---@return number vehicle handle, 0 when not found
local function resolveVehicle(netId, plate)
    if NetworkDoesNetworkIdExist(netId) then
        local vehicle = NetToVeh(netId)
        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) and plateMatches(vehicle, plate) then
            return vehicle
        end
    end

    return findVehicleByPlate(plate)
end

--- Gait and its real speed for a given distance.
---@param distance number
---@return number speed, number metresPerSecond
local function gaitFor(distance)
    local cfg = Config.Scene

    if cfg.RunDistance and distance > cfg.RunDistance then
        return cfg.RunSpeed or 2.0, cfg.RunRate or 2.8
    end

    return cfg.Speed, cfg.WalkRate or 1.1
end

--- Walking budget derived from the MEASURED distance. A fixed timeout is what
--- made the clerk give up halfway: 12 s of walking only covers ~13 metres.
--- `PathFactor` pays for the detour around the vehicle and any obstacle,
--- because the straight line is never the route actually walked.
---@param distance number
---@return number ms
local function budgetFor(distance)
    local cfg     = Config.Scene
    local _, rate = gaitFor(distance)

    local walked = distance * (cfg.PathFactor or 2.0)
    local ms     = (walked / math.max(rate, 0.1)) * 1000 + (cfg.ApproachGrace or 4500)

    return math.floor(math.min(math.max(ms, 8000), cfg.ApproachTimeout))
end

--- World position in front of / behind a vehicle, projected onto the ground.
---@param vehicle number
---@param rear boolean
---@param referenceZ number|nil the clerk's foot height
---@return vector3
local function bumperPoint(vehicle, rear, referenceZ)
    local min, max = GetModelDimensions(GetEntityModel(vehicle))
    local offset   = Config.Scene.BumperOffset

    local y = rear and (min.y - offset) or (max.y + offset)
    return onGround(GetOffsetFromEntityInWorldCoords(vehicle, 0.0, y, 0.0), referenceZ)
end

--- Walks the ped to a point.
---
--- Deliberately NOT using `TaskGoToCoordAnyMeans`: "any means" includes
--- commandeering a nearby vehicle, which makes the clerk walk away from the
--- car to go find one. Only two tasks are used here, and neither can do that:
---
---   1. `TaskFollowNavMeshToCoord`, given one short probe window. Either it
---      moves the ped almost immediately or it never will — a scenery ped
---      standing on a kerb is often not anchored to a navmesh polygon, and
---      the task then silently walks him off in a random direction instead
---      of failing. Re-issuing it does not recover that.
---   2. `TaskGoStraightToCoord`, the workhorse fallback. `distanceToSlide`
---      is 0.0, so the ped is never slid or teleported.
---
---@param ped number
---@param target vector3
---@param timeout number|nil derived from the distance when omitted
---@return boolean arrived
function SceneDirector:_walkTo(ped, target, timeout)
    if not DoesEntityExist(ped) then return false end

    local radius   = Config.Scene.ArriveRadius
    local start    = GetEntityCoords(ped)
    local distance = flatDistance(start, target)

    local speed    = gaitFor(distance)
    timeout        = timeout or budgetFor(distance)
    local deadline = GetGameTimer() + timeout

    Utils.Debug(('clerk walking %.1f m to (%.2f, %.2f, %.2f), budget %d ms, speed %.1f')
        :format(distance, target.x, target.y, target.z, timeout, speed))

    -- Pathing around a parked car needs the ped to be allowed to leave the
    -- pavement, and the navmesh for the destination has to be streamed in
    -- before any route can be computed. Neither is on by default.
    AddNavmeshRequiredRegion(target.x, target.y)
    SetPedPathCanUseClimbovers(ped, true)
    SetPedPathCanDropFromHeight(ped, true)
    SetPedPathAvoidFire(ped, false)
    SetPedPathPreferToAvoidWater(ped, false)

    local direct = false

    local function issue()
        ClearPedTasks(ped)

        if direct then
            TaskGoStraightToCoord(ped, target.x, target.y, target.z, speed, timeout,
                GetEntityHeading(ped), 0.0)
        else
            TaskFollowNavMeshToCoord(ped, target.x, target.y, target.z, speed, timeout,
                radius, true, 0)
        end
    end

    local function goDirect(reason)
        if direct then return end

        direct = true
        Utils.Debug(('navmesh gave up (%s), walking straight instead'):format(reason))
        issue()
    end

    issue()

    local best     = distance
    local lastGain = GetGameTimer()
    local probeEnd = GetGameTimer() + NAVMESH_PROBE
    local lastLog  = 0

    while GetGameTimer() < deadline do
        if not DoesEntityExist(ped) then return false end

        local now  = GetGameTimer()
        local pos  = GetEntityCoords(ped)
        local left = flatDistance(pos, target)

        if left <= radius then
            Utils.Debug(('clerk arrived, %.1f m from the target'):format(left))
            return true
        end

        if now - lastLog >= 1000 then
            lastLog = now
            Utils.Debug(('  walking: %.1f m left (best %.1f, %s)')
                :format(left, best, direct and 'direct' or 'navmesh'))
        end

        if left < best - PROGRESS_STEP then
            best     = left
            lastGain = now
        end

        if not direct then
            -- One chance, judged on the only thing that matters: did the ped
            -- actually get closer? A reported route means nothing if he is
            -- still standing on the kerb.
            if left > distance + WRONG_WAY_MARGIN then
                goDirect('heading the wrong way')
            elseif GetNavmeshRouteResult(ped) == 3 then
                goDirect('no route')
            elseif now >= probeEnd and best > distance - PROGRESS_STEP then
                goDirect('no movement')
            elseif now - lastGain > PROGRESS_TIMEOUT then
                goDirect('stalled')
            end
        elseif now - lastGain > PROGRESS_TIMEOUT then
            -- The straight walk is blocked by something solid. Re-issuing is
            -- cheap and usually shakes the ped loose.
            lastGain = now
            Utils.Debug(('clerk stalled %.1f m out, re-issuing the direct walk'):format(left))
            issue()
        end

        Wait(100)
    end

    local left = flatDistance(GetEntityCoords(ped), target)
    Utils.Debug(('clerk ran out of time, %.1f m short (best %.1f)'):format(left, best))

    return left <= radius * 2.0
end

--- Plays the working animation at one bumper.
---@param ped number
---@param vehicle number
---@param duration number
---@return boolean completed
function SceneDirector:_work(ped, vehicle, duration)
    if not DoesEntityExist(ped) then return false end

    if DoesEntityExist(vehicle) then
        TaskTurnPedToFaceEntity(ped, vehicle, 800)
        Wait(800)
    end

    local anim = Config.Scene.Anim

    if loadAnim(anim.dict) then
        TaskPlayAnim(ped, anim.dict, anim.clip, 8.0, -8.0, duration, anim.flag or 1, 0.0, false, false, false)
    end

    local deadline = GetGameTimer() + duration

    while GetGameTimer() < deadline do
        if not DoesEntityExist(ped) then return false end
        Wait(100)
    end

    if DoesEntityExist(ped) then ClearPedTasks(ped) end

    return true
end

---@param ped number
---@return number|nil prop
function SceneDirector:_giveProp(ped)
    local cfg = Config.Scene
    if not cfg.Prop then return nil end

    local loaded, hash = loadModel(cfg.Prop, 3000)
    if not loaded then
        Utils.Warn(('scene prop "%s" could not be loaded'):format(tostring(cfg.Prop)))
        return nil
    end

    local coords = GetEntityCoords(ped)
    local prop   = CreateObject(hash, coords.x, coords.y, coords.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)

    AttachEntityToEntity(
        prop, ped, GetPedBoneIndex(ped, cfg.PropBone),
        cfg.PropOffset.x, cfg.PropOffset.y, cfg.PropOffset.z,
        cfg.PropRotation.x, cfg.PropRotation.y, cfg.PropRotation.z,
        true, true, false, true, 1, true
    )

    return prop
end

---@param prop number|nil
local function removeProp(prop)
    if prop and DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        DeleteEntity(prop)
    end
end

--- Puts the clerk back exactly where he started, scenario included.
---@param entry table
---@param ped number
function SceneDirector:_restore(entry, ped)
    if not DoesEntityExist(ped) then return end

    local cfg = Config.Scene

    self:_walkTo(ped, entry.origin, cfg.ReturnTimeout)

    if not DoesEntityExist(ped) then return end

    -- Snapped at the very end so the clerk is always exactly where he was,
    -- even if something blocked his way home.
    ClearPedTasks(ped)
    SetEntityCoordsNoOffset(ped, entry.origin.x, entry.origin.y, entry.origin.z, false, false, false)
    SetEntityHeading(ped, entry.heading)

    local pedCfg = entry.data.ped
    if pedCfg and pedCfg.scenario then
        TaskStartScenarioInPlace(ped, pedCfg.scenario, 0, true)
    end

    if not pedCfg or pedCfg.frozen ~= false then
        FreezeEntityPosition(ped, true)
    end
end

-- ── main sequence ──────────────────────────────────────────────────────────

--- Runs the whole scene.
---
--- `onWorkDone` is fired the moment BOTH plates are fitted, before the clerk
--- walks back. The commit must not wait for the return trip: walking home can
--- take another 15 s and would push the request past the ticket deadline.
---@param locationId string
---@param netId number
---@param plate string|nil plate worn by the vehicle before the change
---@param onWorkDone fun()|nil
---@return string status 'ok' | 'unavailable' | 'failed'
function SceneDirector:Play(locationId, netId, plate, onWorkDone)
    if self.active[locationId] then return 'unavailable' end

    local entry = Locations:Get(locationId)
    if not entry or not entry.ped or not DoesEntityExist(entry.ped) then
        Utils.Debug(('scene %s: clerk not streamed in'):format(locationId))
        return 'unavailable'
    end

    local ped     = entry.ped
    local vehicle = resolveVehicle(netId, plate)

    if vehicle == 0 then
        Utils.Debug(('scene %s: vehicle not found locally (plate %s)'):format(locationId, tostring(plate)))
        return 'unavailable'
    end

    -- The vehicle is read from the world, not assumed: exact coordinates,
    -- the plate it is actually wearing and the real distance to walk.
    local pedCoords = GetEntityCoords(ped)
    local vehCoords = GetEntityCoords(vehicle)
    local distance  = #(pedCoords - vehCoords)

    Utils.Debug(('scene %s: clerk (%.2f, %.2f, %.2f) -> vehicle "%s" (%.2f, %.2f, %.2f), %.1f m')
        :format(locationId, pedCoords.x, pedCoords.y, pedCoords.z,
                GetVehicleNumberPlateText(vehicle),
                vehCoords.x, vehCoords.y, vehCoords.z, distance))

    if distance > Config.Scene.MaxVehicleDistance then
        Utils.Debug(('scene %s: vehicle %.1f m away, limit is %.1f m')
            :format(locationId, distance, Config.Scene.MaxVehicleDistance))
        return 'far'
    end

    self.active[locationId] = true
    entry.busy = true

    local cfg  = Config.Scene
    local prop = nil
    local ok   = false

    -- Everything runs inside a guarded block: whatever happens, the clerk
    -- must end up back at his desk and the prop must not be left behind.
    local success, err = pcall(function()
        FreezeEntityPosition(ped, false)
        ClearPedTasksImmediately(ped)
        SetBlockingOfNonTemporaryEvents(ped, true)

        -- A ped spawned frozen is usually not anchored to the navmesh, and
        -- every pathfinding task then fails without any error. Re-seating him
        -- on the ground fixes it. A large correction is refused: that means
        -- the probe hit something else, and dropping the clerk through a
        -- floor would break the walk far worse than a wrong height.
        local current  = GetEntityCoords(ped)
        local grounded = onGround(current)

        if math.abs(grounded.z - current.z) <= 2.0 then
            SetEntityCoordsNoOffset(ped, grounded.x, grounded.y, grounded.z, false, false, false)
            Utils.Debug(('clerk grounded: %.2f -> %.2f'):format(current.z, grounded.z))
        else
            Utils.Debug(('ground probe rejected: %.2f -> %.2f'):format(current.z, grounded.z))
        end

        SetPedKeepTask(ped, true)
        Wait(100)

        -- The vehicle sits on the surface the plates have to be reached from,
        -- so its own height is the only sane reference for the bumper probes.
        -- The clerk may be standing on a kerb, or floating if his configured
        -- coordinates are off.
        local groundRef = vehCoords.z

        prop = self:_giveProp(ped)

        -- Rear plate. The walk result decides whether the animation plays at
        -- all: working in mid-air ten metres from the car is what made the
        -- old version look like the clerk never went anywhere.
        if not self:_walkTo(ped, bumperPoint(vehicle, true, groundRef)) then
            Utils.Debug('clerk could not reach the rear bumper')
            return
        end
        if not self:_work(ped, vehicle, cfg.WorkDuration) then return end

        -- The vehicle may have been re-created by the streamer in the
        -- meantime, which invalidates the handle we started with.
        vehicle = resolveVehicle(netId, plate)
        if vehicle == 0 then
            Utils.Debug('vehicle disappeared between the two bumpers')
            return
        end

        -- Front plate.
        if not self:_walkTo(ped, bumperPoint(vehicle, false, groundRef)) then
            Utils.Debug('clerk could not reach the front bumper')
            return
        end
        if not self:_work(ped, vehicle, cfg.WorkDuration) then return end

        ok = true
    end)

    if not success then
        Utils.Error(('scene failed at %s: %s'):format(locationId, tostring(err)))
    end

    -- Reported here, so the plate changes while the clerk is still standing
    -- at the bumper and the server never sees a late request.
    if ok and onWorkDone then
        local reported, reportErr = pcall(onWorkDone)
        if not reported then Utils.Error(tostring(reportErr)) end
    end

    if ok then Wait(cfg.FinishPause) end

    removeProp(prop)
    self:_restore(entry, ped)

    entry.busy = false
    self.active[locationId] = nil

    return ok and 'ok' or 'failed'
end

Director = SceneDirector.new()

-- ── replication ────────────────────────────────────────────────────────────

--- Fired at every client so the whole street sees the same scene. Only the
--- requester reports the outcome back.
RegisterNetEvent('nlrp-vplates:client:sceneStart', function(payload)
    if type(payload) ~= 'table' then return end

    local locationId = payload.locationId
    local netId      = payload.netId

    if type(locationId) ~= 'string' or not Utils.IsPositiveInt(netId) then return end

    CreateThread(function()
        local reported = false

        --- Sent as soon as the plates are fitted, never after the walk back.
        ---@param completed boolean
        ---@param reasonKey string|nil
        local function report(completed, reasonKey)
            if reported then return end
            reported = true

            Nui.busy = false

            if not completed then
                Notify:Send('error', L(reasonKey or 'msg.cancelled'))
                TriggerServerEvent('nlrp-vplates:server:cancel')
                return
            end

            TriggerServerEvent('nlrp-vplates:server:commit', payload.ticket)
        end

        local status = Director:Play(locationId, netId, payload.plate, payload.mine and function()
            report(true)
        end or nil)

        if not payload.mine then return end

        if not reported then
            if status == 'unavailable' then
                -- The clerk or the vehicle is not streamed in here: fall back
                -- to the configured progress bar so the flow still completes.
                report(Progress:Run(Scene.WorkTime(), L('ui.working')))
            elseif status == 'far' then
                report(false, 'msg.too_far')
            else
                report(false, 'msg.scene_failed')
            end
        end

        -- The clerk only becomes available again once he is back at his desk.
        TriggerServerEvent('nlrp-vplates:server:sceneFinished', payload.ticket, locationId)
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for locationId in pairs(Director.active) do
        local entry = Locations:Get(locationId)
        if entry and entry.ped and DoesEntityExist(entry.ped) then
            ClearPedTasksImmediately(entry.ped)
        end
    end
end)
