--[[
    nlrp-vplates | bridge/notify.lua  (CLIENT ONLY)
    Notification abstraction.

    Every adapter exposes the exact same call:
        Notify:Send(kind, message)     kind = 'success' | 'error' | 'info'

    The message ALWAYS comes from the locale system; no adapter ever builds
    text of its own. When the configured resource is missing the adapter falls
    back to our own NUI toasts, so a notification is never silently lost.
]]

local NotifyAdapter = Class('NotifyAdapter')

function NotifyAdapter:init()
    self.name = 'native'
end

---@return boolean
function NotifyAdapter:IsAvailable() return true end

---@param kind string 'success'|'error'|'info'
---@param message string
function NotifyAdapter:Send(kind, message) end

-- ── native (our own NUI toasts, zero dependency) ───────────────────────────

local NativeNotify = Class('NativeNotify', NotifyAdapter)

function NativeNotify:init()
    NotifyAdapter.init(self)
    self.name = 'native'
end

function NativeNotify:Send(kind, message)
    Nui:Notify(kind == 'success', message)
end

-- ── ox_lib ─────────────────────────────────────────────────────────────────

local OxNotify = Class('OxNotify', NotifyAdapter)

function OxNotify:init()
    NotifyAdapter.init(self)
    self.name = 'ox_lib'
end

function OxNotify:IsAvailable()
    return Utils.ResourceReady('ox_lib')
end

--- Called through the export, so `@ox_lib/init.lua` never has to be added to
--- our manifest: the resource keeps zero hard dependencies.
function OxNotify:Send(kind, message)
    exports.ox_lib:notify({
        title       = Config.Notifications.Title,
        description = message,
        type        = kind == 'error' and 'error' or (kind == 'success' and 'success' or 'inform'),
        position    = Config.Notifications.Position,
        duration    = Config.Notifications.Duration,
    })
end

-- ── qbx_core (ox_lib under the hood, but routed through the core export) ───

local QbxNotify = Class('QbxNotify', NotifyAdapter)

function QbxNotify:init()
    NotifyAdapter.init(self)
    self.name = 'qbx'
end

function QbxNotify:IsAvailable()
    return Utils.ResourceReady('qbx_core')
end

function QbxNotify:Send(kind, message)
    local kinds = { success = 'success', error = 'error', info = 'inform' }
    exports.qbx_core:Notify(message, kinds[kind] or 'inform', Config.Notifications.Duration)
end

-- ── QBCore ─────────────────────────────────────────────────────────────────

local QbNotify = Class('QbNotify', NotifyAdapter)

function QbNotify:init()
    NotifyAdapter.init(self)
    self.name = 'qb'
end

function QbNotify:IsAvailable()
    return Utils.ResourceReady('qb-core')
end

function QbNotify:Send(kind, message)
    -- qb-core expects 'success' | 'error' | 'primary'.
    local kinds = { success = 'success', error = 'error', info = 'primary' }
    TriggerEvent('QBCore:Notify', message, kinds[kind] or 'primary', Config.Notifications.Duration)
end

-- ── ESX ────────────────────────────────────────────────────────────────────

local EsxNotify = Class('EsxNotify', NotifyAdapter)

function EsxNotify:init()
    NotifyAdapter.init(self)
    self.name = 'esx'
end

function EsxNotify:IsAvailable()
    return Utils.ResourceReady('es_extended')
end

function EsxNotify:Send(kind, message)
    if Framework and Framework.core and Framework.core.ShowNotification then
        Framework.core.ShowNotification(message, kind == 'error', Config.Notifications.Duration)
        return
    end

    TriggerEvent('esx:showNotification', message)
end

-- ── custom ─────────────────────────────────────────────────────────────────

--[[
    ###########################################################################
    ##  CUSTOM NOTIFICATIONS - PLUG YOUR OWN RESOURCE IN HERE                ##
    ###########################################################################

    Set `Config.Notifications.Resource = 'custom'` and fill in the two methods
    below. Everything else in the resource keeps working untouched.

      IsAvailable()      return true once your resource is running
      Send(kind, msg)    kind is always 'success', 'error' or 'info'

    `message` is already translated. Never build text here.
]]

local CustomNotify = Class('CustomNotify', NotifyAdapter)

function CustomNotify:init()
    NotifyAdapter.init(self)
    self.name = 'custom'
end

function CustomNotify:IsAvailable()
    -- TODO: return Utils.ResourceReady('my-notify')
    return false
end

function CustomNotify:Send(kind, message)
    -- TODO: exports['my-notify']:Show(kind, message, Config.Notifications.Duration)
end

-- ── Resolver ───────────────────────────────────────────────────────────────

-- `qbx_core` comes before `ox_lib` on purpose: on a qbx server the core is the
-- one that decides how a notification looks, and it may wrap or override it.
local ORDER = {
    { key = 'custom', cls = CustomNotify },
    { key = 'qbx',    cls = QbxNotify },
    { key = 'ox_lib', cls = OxNotify },
    { key = 'qb',     cls = QbNotify },
    { key = 'esx',    cls = EsxNotify },
    { key = 'native', cls = NativeNotify },
}

local function resolve()
    local forced = Config.Notifications.Resource

    if forced and forced ~= 'auto' then
        for i = 1, #ORDER do
            if ORDER[i].key == forced then
                local adapter = ORDER[i].cls.new()
                if adapter:IsAvailable() then return adapter end
                Utils.Warn(('notifications "%s" forced but unavailable -> native fallback'):format(forced))
                return NativeNotify.new()
            end
        end
        Utils.Error(('unknown notification resource in config: "%s"'):format(tostring(forced)))
        return NativeNotify.new()
    end

    -- `auto` skips the custom adapter unless it is explicitly selected.
    for i = 2, #ORDER do
        local adapter = ORDER[i].cls.new()
        if adapter:IsAvailable() then return adapter end
    end

    return NativeNotify.new()
end

Notify = resolve()

Utils.Debug('notifications =', Notify.name)
