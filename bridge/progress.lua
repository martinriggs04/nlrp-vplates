--[[
    nlrp-vplates | bridge/progress.lua  (CLIENT ONLY)
    Progress bar abstraction.

    Every adapter exposes the exact same call:
        Progress:Run(duration, label) -> boolean completed

    The returned boolean is part of the SECURITY contract, not cosmetics:
    the server issues the ticket with a `notBefore` timestamp and treats an
    early commit as a bypassed progress bar. An adapter that returns `true`
    without actually waiting `duration` would hand players a free strike, so
    every adapter below either blocks for the full duration or reports false.

    Adapters that cannot cancel natively are wrapped in our own watcher, so
    "cancel with BACKSPACE / move away / enter a vehicle" behaves identically
    no matter which resource renders the bar.
]]

local ANIM_DICT = 'mini@repair'
local ANIM_NAME = 'fixing_a_ped'
local CANCEL_KEY = 202 -- BACKSPACE / ESC
local MAX_DRIFT = 3.0

local ProgressAdapter = Class('ProgressAdapter')

function ProgressAdapter:init()
    self.name = 'native'
end

---@return boolean
function ProgressAdapter:IsAvailable() return true end

-- ── shared helpers ─────────────────────────────────────────────────────────

--- Plays the repair animation. Never blocks longer than 2s waiting for the dict.
function ProgressAdapter:_startAnim()
    if not Config.Progress.Animation then return end

    local ped = PlayerPedId()
    RequestAnimDict(ANIM_DICT)

    local timeout = GetGameTimer() + 2000
    while not HasAnimDictLoaded(ANIM_DICT) and GetGameTimer() < timeout do Wait(0) end

    if HasAnimDictLoaded(ANIM_DICT) then
        TaskPlayAnim(ped, ANIM_DICT, ANIM_NAME, 8.0, -8.0, -1, 49, 0.0, false, false, false)
    end
end

function ProgressAdapter:_stopAnim()
    if not Config.Progress.Animation then return end
    ClearPedTasks(PlayerPedId())
    RemoveAnimDict(ANIM_DICT)
end

--- Conditions that abort the action regardless of the rendering resource.
---@param startCoords vector3
---@return boolean aborted
function ProgressAdapter:_shouldAbort(startCoords)
    local ped = PlayerPedId()

    if IsEntityDead(ped) then return true end
    if IsPedInAnyVehicle(ped, false) then return true end
    if #(GetEntityCoords(ped) - startCoords) > MAX_DRIFT then return true end

    return false
end

--- Watchdog for adapters with no native cancel. Runs alongside the bar and
--- flips `state.cancelled` so the adapter can bail out early.
---@param state table
function ProgressAdapter:_watch(state)
    local startCoords = GetEntityCoords(PlayerPedId())

    CreateThread(function()
        while state.running do
            if Config.Progress.AllowCancel and IsControlJustReleased(0, CANCEL_KEY) then
                state.cancelled = true
                break
            end

            if self:_shouldAbort(startCoords) then
                state.cancelled = true
                break
            end

            Wait(0)
        end
    end)
end

---@param duration number ms
---@param label string
---@return boolean completed
function ProgressAdapter:Run(duration, label)
    return false
end

-- ── native (our own NUI bar, zero dependency) ──────────────────────────────

local NativeProgress = Class('NativeProgress', ProgressAdapter)

function NativeProgress:init()
    ProgressAdapter.init(self)
    self.name = 'native'
end

function NativeProgress:Run(duration, label)
    return Nui:Progress(duration, label)
end

-- ── ox_lib ─────────────────────────────────────────────────────────────────

local OxProgress = Class('OxProgress', ProgressAdapter)

function OxProgress:init()
    ProgressAdapter.init(self)
    self.name = 'ox_lib'
end

function OxProgress:IsAvailable()
    return Utils.ResourceReady('ox_lib')
end

--- Called through the export so `@ox_lib/init.lua` is not required in our
--- manifest. ox_lib already blocks for the duration and returns false when
--- the player cancels or dies, which is exactly our contract.
function OxProgress:Run(duration, label)
    local options = {
        duration     = duration,
        label        = label,
        useWhileDead = false,
        canCancel    = Config.Progress.AllowCancel,
        disable      = { move = false, car = true, combat = true },
    }

    if Config.Progress.Animation then
        options.anim = { dict = ANIM_DICT, clip = ANIM_NAME, flag = 49 }
    end

    if Config.Progress.Circle then
        options.position = Config.Progress.Position
        local ok, result = pcall(function() return exports.ox_lib:progressCircle(options) end)
        if ok then return result == true end
        options.position = nil
    end

    return exports.ox_lib:progressBar(options) == true
end

-- ── qb-core / progressbar ──────────────────────────────────────────────────

local QbProgress = Class('QbProgress', ProgressAdapter)

function QbProgress:init()
    ProgressAdapter.init(self)
    self.name = 'qb'
end

function QbProgress:IsAvailable()
    return Utils.ResourceReady('progressbar')
end

--- `progressbar` is callback based, so the call is bridged back into a
--- blocking one: the plate flow must not continue before the bar is done.
function QbProgress:Run(duration, label)
    local state = { running = true, cancelled = false, done = false }

    local options = {
        name         = 'nlrp_vplates_progress',
        duration     = duration,
        label        = label,
        useWhileDead = false,
        canCancel    = Config.Progress.AllowCancel,
        controlDisables = { disableMovement = false, disableCarMovement = true,
                            disableMouse = false, disableCombat = true },
    }

    if Config.Progress.Animation then
        options.animation = { animDict = ANIM_DICT, anim = ANIM_NAME, flags = 49 }
    end

    exports['progressbar']:Progress(options, function(cancelled)
        state.cancelled = state.cancelled or cancelled == true
        state.done      = true
        state.running   = false
    end)

    self:_watch(state)

    -- Hard timeout so a broken callback can never hang the flow forever.
    local deadline = GetGameTimer() + duration + 5000

    while not state.done and GetGameTimer() < deadline do
        if state.cancelled then
            exports['progressbar']:closeProgressbar()
            break
        end
        Wait(0)
    end

    state.running = false

    return state.done and not state.cancelled
end

-- ── qbx_core (ships ox_lib, so it simply reuses that renderer) ─────────────

local QbxProgress = Class('QbxProgress', OxProgress)

function QbxProgress:init()
    OxProgress.init(self)
    self.name = 'qbx'
end

function QbxProgress:IsAvailable()
    return Utils.ResourceReady('qbx_core') and OxProgress.IsAvailable(self)
end

-- ── ESX ────────────────────────────────────────────────────────────────────

local EsxProgress = Class('EsxProgress', ProgressAdapter)

function EsxProgress:init()
    ProgressAdapter.init(self)
    self.name = 'esx'
end

function EsxProgress:IsAvailable()
    return Utils.ResourceReady('esx_progressbar')
end

--- esx_progressbar has no cancel and no completion callback we can rely on,
--- so the wait and the abort rules are enforced here instead.
function EsxProgress:Run(duration, label)
    local state = { running = true, cancelled = false }

    TriggerEvent('esx_progressbar:start', label, duration)

    self:_startAnim()
    self:_watch(state)

    local finish = GetGameTimer() + duration

    while GetGameTimer() < finish and not state.cancelled do
        Wait(0)
    end

    state.running = false
    self:_stopAnim()

    if state.cancelled then
        TriggerEvent('esx_progressbar:cancel')
        return false
    end

    return true
end

-- ── custom ─────────────────────────────────────────────────────────────────

--[[
    ###########################################################################
    ##  CUSTOM PROGRESS BAR - PLUG YOUR OWN RESOURCE IN HERE                 ##
    ###########################################################################

    Set `Config.Progress.Resource = 'custom'` and fill in the two methods.

      IsAvailable()        return true once your resource is running
      Run(duration, label) MUST block for the whole duration and MUST return
                           false when the player cancels or is interrupted

    Returning `true` early is a security hole: the server would receive the
    commit before `notBefore` and flag the player for bypassing the bar.

    A ready-made skeleton for a callback based resource:

        function CustomProgress:Run(duration, label)
            local state = { running = true, cancelled = false, done = false }

            exports['my-progress']:Start(label, duration, function(cancelled)
                state.cancelled = cancelled == true
                state.done      = true
                state.running   = false
            end)

            self:_startAnim()
            self:_watch(state)          -- cancel key + movement + death guard

            local deadline = GetGameTimer() + duration + 5000
            while not state.done and GetGameTimer() < deadline do
                if state.cancelled then
                    exports['my-progress']:Cancel()
                    break
                end
                Wait(0)
            end

            state.running = false
            self:_stopAnim()

            return state.done and not state.cancelled
        end
]]

local CustomProgress = Class('CustomProgress', ProgressAdapter)

function CustomProgress:init()
    ProgressAdapter.init(self)
    self.name = 'custom'
end

function CustomProgress:IsAvailable()
    -- TODO: return Utils.ResourceReady('my-progress')
    return false
end

function CustomProgress:Run(duration, label)
    -- TODO: implement. Until then the native bar is used instead.
    return Nui:Progress(duration, label)
end

-- ── Resolver ───────────────────────────────────────────────────────────────

local ORDER = {
    { key = 'custom', cls = CustomProgress },
    { key = 'qbx',    cls = QbxProgress },
    { key = 'ox_lib', cls = OxProgress },
    { key = 'qb',     cls = QbProgress },
    { key = 'esx',    cls = EsxProgress },
    { key = 'native', cls = NativeProgress },
}

local function resolve()
    local forced = Config.Progress.Resource

    if forced and forced ~= 'auto' then
        for i = 1, #ORDER do
            if ORDER[i].key == forced then
                local adapter = ORDER[i].cls.new()
                if adapter:IsAvailable() then return adapter end
                Utils.Warn(('progress bar "%s" forced but unavailable -> native fallback'):format(forced))
                return NativeProgress.new()
            end
        end
        Utils.Error(('unknown progress resource in config: "%s"'):format(tostring(forced)))
        return NativeProgress.new()
    end

    -- `auto` skips the custom adapter unless it is explicitly selected.
    for i = 2, #ORDER do
        local adapter = ORDER[i].cls.new()
        if adapter:IsAvailable() then return adapter end
    end

    return NativeProgress.new()
end

Progress = resolve()

Utils.Debug('progress =', Progress.name)
