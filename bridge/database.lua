--[[
    nlrp-vplates | bridge/database.lua  (SERVER ONLY)
    Thin, promise based SQL layer. Auto-detects oxmysql / mysql-async /
    ghmattimysql so the resource never hard-depends on one of them.

    All calls are parameterised — never concatenate user input into SQL.
]]

local DatabaseAdapter = Class('DatabaseAdapter')

function DatabaseAdapter:init()
    self.name      = 'none'
    self.available = false
end

---@return boolean
function DatabaseAdapter:IsAvailable() return false end

---@param sql string
---@param params table|nil
---@return table rows
function DatabaseAdapter:Query(sql, params) return {} end

---@param sql string
---@param params table|nil
---@return number affectedRows
function DatabaseAdapter:Execute(sql, params) return 0 end

---@param sql string
---@param params table|nil
---@return any
function DatabaseAdapter:Scalar(sql, params)
    local rows = self:Query(sql, params)
    local row = rows and rows[1]
    if not row then return nil end
    for _, v in pairs(row) do return v end
    return nil
end

-- ── oxmysql ─────────────────────────────────────────────────────────────────

local OxMySQL = Class('OxMySQL', DatabaseAdapter)

function OxMySQL:init()
    DatabaseAdapter.init(self)
    self.name = 'oxmysql'
end

function OxMySQL:IsAvailable() return Utils.ResourceReady('oxmysql') end

function OxMySQL:Query(sql, params)
    local p = promise.new()
    exports.oxmysql:query(sql, params or {}, function(result)
        p:resolve(result or {})
    end)
    return Citizen.Await(p)
end

function OxMySQL:Execute(sql, params)
    local p = promise.new()
    exports.oxmysql:update(sql, params or {}, function(affected)
        p:resolve(tonumber(affected) or 0)
    end)
    return Citizen.Await(p)
end

-- ── mysql-async ─────────────────────────────────────────────────────────────

local MySQLAsync = Class('MySQLAsync', DatabaseAdapter)

function MySQLAsync:init()
    DatabaseAdapter.init(self)
    self.name = 'mysql-async'
end

function MySQLAsync:IsAvailable() return Utils.ResourceReady('mysql-async') end

function MySQLAsync:Query(sql, params)
    local p = promise.new()
    exports['mysql-async']:mysql_fetch_all(sql, params or {}, function(result)
        p:resolve(result or {})
    end)
    return Citizen.Await(p)
end

function MySQLAsync:Execute(sql, params)
    local p = promise.new()
    exports['mysql-async']:mysql_execute(sql, params or {}, function(affected)
        p:resolve(tonumber(affected) or 0)
    end)
    return Citizen.Await(p)
end

-- ── ghmattimysql ────────────────────────────────────────────────────────────

local GhmattiMySQL = Class('GhmattiMySQL', DatabaseAdapter)

function GhmattiMySQL:init()
    DatabaseAdapter.init(self)
    self.name = 'ghmattimysql'
end

function GhmattiMySQL:IsAvailable() return Utils.ResourceReady('ghmattimysql') end

function GhmattiMySQL:Query(sql, params)
    local p = promise.new()
    exports.ghmattimysql:execute(sql, params or {}, function(result)
        p:resolve(result or {})
    end)
    return Citizen.Await(p)
end

function GhmattiMySQL:Execute(sql, params)
    local rows = self:Query(sql, params)
    if type(rows) == 'table' and rows.affectedRows then return rows.affectedRows end
    return type(rows) == 'number' and rows or 0
end

-- ── Resolver ────────────────────────────────────────────────────────────────

local ORDER = {
    { key = 'oxmysql',      cls = OxMySQL },
    { key = 'mysql-async',  cls = MySQLAsync },
    { key = 'ghmattimysql', cls = GhmattiMySQL },
}

local function resolve()
    local forced = Config.Database

    if forced ~= 'auto' then
        for i = 1, #ORDER do
            if ORDER[i].key == forced then return ORDER[i].cls.new() end
        end
        Utils.Error(('unknown SQL driver: "%s"'):format(tostring(forced)))
    end

    for i = 1, #ORDER do
        local adapter = ORDER[i].cls.new()
        if adapter:IsAvailable() then return adapter end
    end

    return DatabaseAdapter.new()
end

Database = resolve()
Database.available = Database:IsAvailable()

if not Database.available and Framework.hasOwners then
    Utils.Warn('no SQL driver detected - permanent registrations are disabled')
end

Utils.Debug('database =', Database.name)
