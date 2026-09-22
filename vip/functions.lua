--[[
    nlrp-vplates | vip/functions.lua  (SHARED)

    VIP layer - STRUCTURE ONLY.
    ---------------------------------------------------------------------------
    This file defines the CONTRACT. It deliberately contains no real business
    logic: how a player becomes VIP is entirely up to the server owner.

    What you implement:
        vip/server.lua -> VipService:IsVIP(source)   <- the authoritative check
        vip/client.lua -> optional local cache used for UI hints only

    What you must NOT change:
        VipService:CanUse()  - the entry point used by the plate service
        VipService:Resolve() - the cached wrapper around your IsVIP()

    Rules baked into this layer:
      * The SERVER is the only authority. The client copy exists so the UI can
        show a hint; it is never trusted for a decision.
      * Fail-safe by design: as long as IsVIP() is not implemented it returns
        `Config.VIP.DefaultResult` (false), so enabling VIP without writing any
        logic denies everyone instead of granting everyone.
      * Every denial goes through the locale system (`msg.vip_only`).
]]

VipService = Class('VipService')

function VipService:init()
    self.enabled = Config.VIP.Enabled == true
    self.side    = IsDuplicityVersion() and 'server' or 'client'
    self.cache   = {}

    Utils.Debug(('vip layer loaded (%s side, enabled=%s)'):format(self.side, tostring(self.enabled)))
end

-- ── cache ──────────────────────────────────────────────────────────────────

---@param key string
---@return boolean|nil value nil = cache miss
---@return string|nil tier
function VipService:_cached(key)
    local entry = self.cache[key]
    if not entry then return nil end

    if GetGameTimer() > entry.expires then
        self.cache[key] = nil
        return nil
    end

    return entry.value, entry.tier
end

---@param key string
---@param value boolean
---@param tier string|nil
function VipService:_store(key, value, tier)
    local ttl = (tonumber(Config.VIP.CacheSeconds) or 0) * 1000
    if ttl <= 0 then return end

    self.cache[key] = {
        value   = value == true,
        tier    = tier,
        expires = GetGameTimer() + ttl,
    }
end

--- Drops a cached result. Call it whenever a player buys or loses VIP.
---@param key any nil = flush everything
function VipService:Invalidate(key)
    if key == nil then
        self.cache = {}
        return
    end

    self.cache[tostring(key)] = nil
end

-- ── public API (do not override) ───────────────────────────────────────────

---@return boolean
function VipService:IsEnabled()
    return self.enabled
end

--- Cached wrapper around the owner implemented `IsVIP`.
---@param source any server id (server side) or ignored (client side)
---@return boolean isVip
---@return string|nil tier
function VipService:Resolve(source)
    local key = tostring(source)
    local cached, cachedTier = self:_cached(key)
    if cached ~= nil then return cached, cachedTier end

    local ok, tier = self:IsVIP(source)

    -- Anything that is not an explicit `true` counts as "not VIP".
    ok = ok == true
    self:_store(key, ok, tier)

    return ok, tier
end

--- The single entry point used by the plate service.
--- Returns true when the player is allowed to run this flow.
---@param source any
---@param mode string 'legal'|'fake'
---@return boolean
function VipService:CanUse(source, mode)
    if not self.enabled then return true end

    local required
    if mode == 'fake' then
        required = Config.VIP.RequireForFake == true
    else
        required = Config.VIP.RequireForLegal == true
    end

    if not required then return true end

    return self:Resolve(source) == true
end

-- ── owner implemented (see vip/server.lua) ─────────────────────────────────

--- ###########################################################################
--- ##  IMPLEMENT YOUR OWN LOGIC IN `vip/server.lua`                         ##
--- ###########################################################################
--- Default: fail-safe. This file never grants access.
---@param source any
---@return boolean isVip
---@return string|nil tier
function VipService:IsVIP(source)
    return Config.VIP.DefaultResult == true, nil
end
