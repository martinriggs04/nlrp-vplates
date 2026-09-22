--[[
    nlrp-vplates | shared/scene.lua
    Timing contract for the NPC scene.

    Client and server must agree on how long the scene is allowed to take,
    otherwise the anti-bypass check would either flag honest players or let
    cheaters through. Both sides derive their numbers from this single file.

    Two different values, on purpose:

      WorkTime()  the part of the scene the server CAN predict: the clerk
                  screwing a plate on each bumper. Walking depends on the
                  navmesh, traffic and where the vehicle was parked, so it is
                  never counted against the player. This is what `notBefore`
                  is built on.

      MaxTime()   the worst case, used only for the ticket expiry and the
                  occupancy lock timeout, so a crashed client can never keep
                  the clerk busy forever.
]]

Scene = {}

--- Guaranteed minimum duration of the scene, in ms.
---@return number
function Scene.WorkTime()
    local cfg = Config.Scene
    if not cfg.Enabled then return Config.Locations.Duration end

    -- Two bumpers, rear first then front.
    return cfg.WorkDuration * 2
end

--- Worst case duration of the scene, in ms.
---
--- Covers the whole sequence including the walk back to the desk, because the
--- clerk lock is only released once he is home. The commit itself happens
--- much earlier (right after the second plate), so it always lands well
--- inside the ticket deadline even when both walks time out.
---@return number
function Scene.MaxTime()
    local cfg = Config.Scene
    if not cfg.Enabled then return Config.Locations.Duration + 10000 end

    return Scene.WorkTime()
        + cfg.ApproachTimeout * 2
        + cfg.ReturnTimeout
        + cfg.FinishPause
        + 10000 -- slack for model/anim streaming on a loaded client
end
