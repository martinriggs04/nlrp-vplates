--[[
    nlrp-vplates | server/webhook.lua  (SERVER ONLY)
    Discord logging with a small batching queue so a burst of activity never
    spawns dozens of simultaneous HTTP requests.
]]

local cfg = Config.Webhook

local LoggerService = Class('LoggerService')

function LoggerService:init()
    self.enabled = cfg.Enabled and type(cfg.URL) == 'string' and cfg.URL ~= ''
    self.queue   = {}
    self.running = false

    if self.enabled and not cfg.URL:find('^https://discord') then
        Utils.Warn('Config.Webhook.URL does not look like a valid Discord webhook')
    end
end

---@param src number
---@return string
function LoggerService:_identity(src)
    if not src or src <= 0 then return L('log.server') end
    local name    = Framework:GetName(src)
    local license = GetPlayerIdentifierByType(src, 'license') or 'unknown'
    local discord = GetPlayerIdentifierByType(src, 'discord')
    local parts   = ('**%s** (id: %d)\n`%s`'):format(name, src, license)
    if discord then
        parts = parts .. ('\n<@%s>'):format(discord:gsub('discord:', ''))
    end
    return parts
end

---@param embed table
function LoggerService:_enqueue(embed)
    if not self.enabled then return end

    self.queue[#self.queue + 1] = embed
    if self.running then return end
    self.running = true

    CreateThread(function()
        while #self.queue > 0 do
            local batch = {}
            for _ = 1, math.min(10, #self.queue) do
                batch[#batch + 1] = table.remove(self.queue, 1)
            end

            PerformHttpRequest(cfg.URL, function() end, 'POST', json.encode({
                username   = cfg.BotName,
                avatar_url = cfg.AvatarURL ~= '' and cfg.AvatarURL or nil,
                embeds     = batch,
            }), { ['Content-Type'] = 'application/json' })

            Wait(1200)
        end
        self.running = false
    end)
end

---@param title string
---@param color number
---@param fields table
function LoggerService:_send(title, color, fields)
    if cfg.Console then
        local flat = {}
        for i = 1, #fields do
            flat[#flat + 1] = ('%s=%s'):format(fields[i].name, (fields[i].value:gsub('[\n`*]', ' ')))
        end
        print(('^3[vplates]^7 %s | %s'):format(title, table.concat(flat, ' | ')))
    end

    self:_enqueue({
        title     = title,
        color     = color,
        fields    = fields,
        footer    = { text = ('nlrp-vplates • %s'):format(os.date('%Y-%m-%d %H:%M:%S')) },
    })
end

---@param src number
---@param oldPlate string
---@param newPlate string
---@param location table
---@param price number
function LoggerService:LegalChange(src, oldPlate, newPlate, location, price)
    self:_send(L('log.legal_title'), cfg.Colors.success, {
        { name = L('log.field_player'),  value = self:_identity(src), inline = false },
        { name = L('log.field_old'),    value = ('`%s`'):format(oldPlate), inline = true },
        { name = L('log.field_new'),      value = ('`%s`'):format(newPlate), inline = true },
        { name = L('log.field_location'),  value = tostring(T(location.label) or location.id), inline = true },
        { name = L('log.field_cost'),     value = ('$%s'):format(price), inline = true },
    })
end

---@param src number
---@param oldPlate string
---@param newPlate string
---@param model string
function LoggerService:FakePlate(src, oldPlate, newPlate, model)
    self:_send(L('log.fake_title'), cfg.Colors.fake, {
        { name = L('log.field_player'),  value = self:_identity(src), inline = false },
        { name = L('log.field_original'), value = ('`%s`'):format(oldPlate), inline = true },
        { name = L('log.field_fake'),     value = ('`%s`'):format(newPlate), inline = true },
        { name = L('log.field_vehicle'),  value = ('`%s`'):format(model or '?'), inline = true },
    })
end

---@param src number
---@param reason string
---@param detail string|nil
function LoggerService:Denied(src, reason, detail)
    self:_send(L('log.denied_title'), cfg.Colors.denied, {
        { name = L('log.field_player'), value = self:_identity(src), inline = false },
        { name = L('log.field_reason'),   value = tostring(reason), inline = true },
        { name = L('log.field_details'), value = ('`%s`'):format(tostring(detail or '-')), inline = true },
    })
end

---@param src number
---@param reason string
---@param strikes number
function LoggerService:Exploit(src, reason, strikes)
    self:_send('⚠️ ' .. L('log.exploit_title'), cfg.Colors.exploit, {
        { name = L('log.field_player'),  value = self:_identity(src), inline = false },
        { name = L('log.field_reason'),    value = ('`%s`'):format(tostring(reason)), inline = true },
        { name = L('log.field_strikes'),  value = ('%d/%d'):format(strikes, Config.Security.StrikesBeforeAction), inline = true },
    })
end

Logger = LoggerService.new()
