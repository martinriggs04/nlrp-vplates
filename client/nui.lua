--[[
    nlrp-vplates | client/nui.lua  (CLIENT ONLY)
    Self-contained NUI layer: input dialog, progress bar, notifications and the
    interaction prompt. Zero external UI dependencies.
]]

local NuiService = Class('NuiService')

function NuiService:init()
    self.open       = false
    self.session    = nil
    self.promptOpen = false
    self.busy       = false
end

---@param action string
---@param data table|nil
function NuiService:_post(action, data)
    SendNUIMessage({ action = action, data = data })
end

---@param payload table server-issued session descriptor
function NuiService:Open(payload)
    if self.open then return end

    self.open    = true
    self.session = payload

    SetNuiFocus(true, true)

    -- The whole `ui.*` group is handed over as-is: adding a string to the
    -- JSON locale makes it available to the NUI without touching any Lua.
    local strings = Locale:Group('ui')
    strings.subtitle = payload.mode == 'fake' and strings.subtitle_fake or strings.subtitle_legal
    strings.badge    = payload.mode == 'fake' and strings.badge_fake or strings.badge_legal

    -- The mask lives in the shared config, so the client resolves it locally
    -- instead of trusting anything sent over the network. The server re-runs
    -- the exact same check on commit.
    local plateFormat = Formats:Get(payload.mode)
    local exported    = plateFormat and plateFormat:Export() or nil

    strings.hint = exported
        and L('ui.hint_format', exported.mask, exported.example)
        or  L('ui.hint', payload.maxLen)

    self:_post('open', {
        mode     = payload.mode,
        plate    = payload.plate,
        price    = payload.price,
        maxLen   = payload.maxLen,
        minLen   = payload.minLen,
        format   = exported,
        strings  = strings,
    })end

function NuiService:Close(silent)
    if not self.open then return end

    self.open = false
    SetNuiFocus(false, false)
    self:_post('close')

    if not silent then
        TriggerServerEvent('nlrp-vplates:server:cancel')
    end

    self.session = nil
end

---@param ok boolean
---@param message string
function NuiService:Notify(ok, message)
    self:_post('notify', { ok = ok, message = message })
end

---@param label string
function NuiService:ShowPrompt(label)
    if self.promptOpen then return end
    self.promptOpen = true
    self:_post('prompt', { visible = true, label = label, key = L('target.prompt_key') })
end

function NuiService:HidePrompt()
    if not self.promptOpen then return end
    self.promptOpen = false
    self:_post('prompt', { visible = false })
end

--- Blocking progress bar. Returns false if the player cancelled or moved away.
---@param duration number ms
---@param label string
---@return boolean completed
function NuiService:Progress(duration, label)
    local ped = PlayerPedId()

    self.busy = true
    self:_post('progress', { visible = true, duration = duration, label = label, hint = L('ui.cancel_hint') })

    RequestAnimDict('mini@repair')
    local timeout = GetGameTimer() + 2000
    while not HasAnimDictLoaded('mini@repair') and GetGameTimer() < timeout do Wait(0) end

    if HasAnimDictLoaded('mini@repair') then
        TaskPlayAnim(ped, 'mini@repair', 'fixing_a_ped', 8.0, -8.0, -1, 49, 0.0, false, false, false)
    end

    local startCoords = GetEntityCoords(ped)
    local finish      = GetGameTimer() + duration
    local completed   = true

    while GetGameTimer() < finish do
        Wait(0)

        if IsControlJustReleased(0, 202) then -- BACKSPACE / ESC
            completed = false
            break
        end

        if IsPedInAnyVehicle(ped, false) or IsEntityDead(ped)
            or #(GetEntityCoords(ped) - startCoords) > 3.0 then
            completed = false
            break
        end
    end

    ClearPedTasks(ped)
    RemoveAnimDict('mini@repair')
    self:_post('progress', { visible = false })
    self.busy = false

    return completed
end

Nui = NuiService.new()

-- ── NUI callbacks ──────────────────────────────────────────────────────────

RegisterNUICallback('vplates:submit', function(data, cb)
    cb('ok')

    local session = Nui.session
    Nui.open = false
    SetNuiFocus(false, false)
    Nui:_post('close')

    if not session then return end
    Nui.session = nil

    local plate = type(data) == 'table' and data.plate or nil
    if type(plate) ~= 'string' then
        TriggerServerEvent('nlrp-vplates:server:cancel')
        return
    end

    -- Legal changes with a clerk: the server validates and reserves the plate
    -- first, then broadcasts the scene. The commit happens when it ends.
    if session.scene then
        Nui.busy = true
        TriggerServerEvent('nlrp-vplates:server:reserve', session.ticket, plate)
        return
    end

    CreateThread(function()
        -- Flagged here (not inside the adapter) so the busy state holds no
        -- matter which resource renders the bar.
        Nui.busy = true
        local completed = Progress:Run(session.duration, L('ui.working'))
        Nui.busy = false

        if not completed then
            Notify:Send('error', L('msg.cancelled'))
            TriggerServerEvent('nlrp-vplates:server:cancel')
            return
        end

        TriggerServerEvent('nlrp-vplates:server:commit', session.ticket, plate)
    end)
end)

RegisterNUICallback('vplates:cancel', function(_, cb)
    cb('ok')
    Nui:Close()
end)

-- ── events from other client modules / the native target fallback ──────────

RegisterNetEvent('nlrp-vplates:client:openUI', function(payload)
    if type(payload) ~= 'table' then return end
    Nui:Open(payload)
end)

RegisterNetEvent('nlrp-vplates:client:result', function(ok, message)
    -- Any failure ends the flow, so the busy flag must never survive it.
    if ok ~= true then Nui.busy = false end
    Notify:Send(ok == true and 'success' or 'error', message)
end)

AddEventHandler('nlrp-vplates:client:showPrompt', function(label)
    Nui:ShowPrompt(label or L('target.label'))
end)

AddEventHandler('nlrp-vplates:client:hidePrompt', function()
    Nui:HidePrompt()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
