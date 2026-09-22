--[[
    nlrp-vplates | shared/config.lua
    Everything tweakable lives here. No logic, only data.
]]

Config = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- CORE
-- ─────────────────────────────────────────────────────────────────────────────

Config.Debug = true

--- 'auto' | 'qbx' | 'qb' | 'esx' | 'standalone'
Config.Framework = 'auto'

--- 'auto' | 'ox_inventory' | 'qb-inventory' | 'qs-inventory' | 'core_inventory' | 'none'
Config.Inventory = 'auto'

--- 'auto' | 'ox_target' | 'qb-target' | 'interact' | 'polyzone' | 'native'
--- `native` = zero dependency proximity check drawn through our own NUI prompt.
Config.Target = 'auto'

--- 'auto' | 'oxmysql' | 'mysql-async' | 'ghmattimysql'
Config.Database = 'auto'

-- ─────────────────────────────────────────────────────────────────────────────
-- NOTIFICATIONS & PROGRESS BAR
-- Both are adapters: the rest of the resource does not care what renders them
-- ─────────────────────────────────────────────────────────────────────────────

Config.Notifications = {
    --- 'auto' | 'ox_lib' | 'qbx' | 'qb' | 'esx' | 'custom' | 'native'
    --- `native` = our own NUI toasts, zero dependency (always the fallback).
    --- `custom` = your own resource, see the CustomNotify class in bridge/notify.lua
    --- `auto` picks the first available in the order above, never `custom`.
    Resource = 'auto',

    --- Shown by the adapters that support a title (ox_lib).
    Title    = 'Licence plates',
    Duration = 5000,
    --- ox_lib only: 'top' | 'top-right' | 'bottom' | 'center-right' | ...
    Position = 'top-right',
}

Config.Progress = {
    --- 'auto' | 'ox_lib' | 'qbx' | 'qb' | 'esx' | 'custom' | 'native'
    --- See the CustomProgress class in bridge/progress.lua before using 'custom':
    --- the adapter MUST block for the whole duration and MUST return false on
    --- cancel, otherwise the server flags the player for bypassing the bar.
    Resource = 'auto',

    --- Let the player abort with BACKSPACE. Moving away, dying or entering a
    --- vehicle always aborts, regardless of this setting.
    AllowCancel = true,

    --- Play the repair animation while the bar runs.
    Animation = true,

    --- ox_lib only: render a circle instead of a bar.
    Circle   = false,
    Position = 'bottom',
}

--- 'auto' honours the framework's own convention, in order:
---   `ox:locale` convar (ox_lib / qbx) -> `qb_locale` convar (QBCore)
---   -> `esx:locale` convar / ESX.GetConfig().Locale -> 'en'
--- Set an ISO code here (e.g. 'ro') to force one regardless of the framework.
--- Translations live in `locales/<iso>.json` (ox_lib compatible format).
Config.Locale = 'auto'

-- ─────────────────────────────────────────────────────────────────────────────
-- PLATE RULES  (enforced BOTH client & server — server is the authority)
-- ─────────────────────────────────────────────────────────────────────────────

Config.Plate = {
    MinLength      = 2,
    MaxLength      = 8,   -- GTA V hard limit, do not raise
    ForceUppercase = true,
    AllowSpaces    = true,

    --- Characters allowed after sanitisation. Anything else is stripped.
    AllowedPattern = '[A-Z0-9 ]',

    --- Plate must not be purely spaces / must contain at least one alphanumeric.
    RequireAlphanumeric = true,

    -- ── FORMAT MASK ─────────────────────────────────────────────────────────
    --- Describes, character by character, what a plate must look like.
    ---   1        one random digit  (0-9)
    ---   X        one random letter (A-Z)
    ---   <space>  a literal space, on that exact position
    ---   ^        locks the PRECEDING character (never randomised, must match)
    ---
    --- Any character other than `1`, `X` and `^` is already literal, so `^` is
    --- only mandatory for a literal `1` or `X` (`1^`, `X^`). Writing `N^`
    --- instead of `N` is still recommended, it documents the intent.
    ---
    ---   'N^ 11 XXX'   -> N 47 KQD      mask shown to the player: N ## ???
    ---   'L^S^ XXXXX'  -> LS ACFAS      mask: LS ?????
    ---   '11XXX111'    -> 42QWE913      mask: ##???###
    ---
    --- The mask is enforced on the client (positional input) AND on the server.
    --- Set to `false` to accept any free-form plate.
    --- It cannot start/end with a space and must fit within MaxLength.
    Format = 'N^ 11 XXX',

    --- Optional per-mode overrides. `nil` falls back to `Format` above.
    --- Handy when fake plates must look different from registered ones.
    FormatLegal = nil,
    FormatFake  = nil,

    --- Refuse plates already used by an owned vehicle or an active fake plate.
    EnforceUniqueness = true,

    --- Case-insensitive, matched against the sanitised plate with spaces removed.
    Blacklist = {
        'POLICE', 'POLITIA', 'SHERIFF', 'EMS', 'AMBULANCE', 'SAMS', 'DOJ',
        'ADMIN', 'STAFF', 'OWNER', 'SERVER', 'GOV', 'FBI', 'SWAT',
        'NIGGER', 'NIGGA', 'FAGGOT', 'RAPE', 'HITLER', 'NAZI',
    },

    --- Plates that start with any of these are rejected for normal players.
    BlacklistedPrefixes = { 'PD', 'EMS', 'GOV' },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- VIP  (structure only - the whole logic belongs to the server owner)
-- ─────────────────────────────────────────────────────────────────────────────

Config.VIP = {
    --- Master switch. `false` = the VIP layer is completely inert, zero calls.
    Enabled = false,

    --- Which flow needs VIP. By design the fake plate item stays open to
    --- everyone: it is the criminal path, not a perk.
    RequireForLegal = true,
    RequireForFake  = false,

    --- How long an answer from your `IsVIP()` is cached, in seconds.
    --- Call `exports['nlrp-vplates']:RefreshVIP(src)` to drop it early.
    CacheSeconds = 60,

    --- Fail-safe answer used while `vip/server.lua` is still untouched.
    --- Keep it `false`: enabling VIP without writing the logic must deny
    --- everyone, never grant everyone.
    DefaultResult = false,

    --- Free-form value handed back as the tier name in the ACE example.
    AceGroup = 'vip',
}

-- ─────────────────────────────────────────────────────────────────────────────
-- NPC SCENE  (the clerk physically swaps the plates on the vehicle)
-- ─────────────────────────────────────────────────────────────────────────────

Config.Scene = {
    --- `false` keeps the old behaviour: a plain progress bar, no walking NPC.
    Enabled = true,

    --- Prop held by the clerk while walking to the vehicle.
    Prop         = 'p_num_plate_01',
    --- 28422 = SKEL_R_Hand. 60309 (PH_R_Hand) also works on most peds.
    PropBone     = 28422,
    PropOffset   = vector3(0.12, 0.02, -0.02),
    PropRotation = vector3(-100.0, 20.0, 0.0),

    --- Working animation played at each bumper. Replace with any looping
    --- clip you prefer; it is requested with a timeout and never blocks.
    Anim = {
        dict = 'anim@amb@clubhouse@tutorial@bkr_tut_ig3@',
        clip = 'machinic_loop_mechandplayer',
        flag = 1,
    },

    --- Time spent screwing each plate on, in ms. This is the ONLY part of the
    --- scene the server can predict, so it is what the anti-bypass timing
    --- check is based on. Walking time is never counted against the player.
    WorkDuration = 5000,

    --- Distance (m) kept from the bumper while working.
    BumperOffset = 1.1,

    --- Hard limit between the clerk's desk and the vehicle. Beyond this he
    --- simply cannot walk there in a sensible amount of time, so the request
    --- is refused server side and the player is asked to park closer.
    MaxVehicleDistance = 25.0,

    --- Walking. `Speed`: 1.0 = walk, 2.0 = run.
    --- Anything farther than `RunDistance` metres is covered at `RunSpeed`,
    --- so the clerk does not stroll across a whole parking lot.
    Speed       = 1.0,
    RunSpeed    = 2.0,
    RunDistance = 8.0,

    --- Real metres per second for each gait. Used to turn the measured
    --- distance into a walking budget instead of guessing a fixed timeout.
    WalkRate = 1.1,
    RunRate  = 2.8,

    --- The straight line is never the route actually walked: the clerk goes
    --- around the vehicle and whatever else is in the way. The measured
    --- distance is multiplied by this before the budget is computed.
    PathFactor = 2.0,

    --- Added on top of the computed budget for turning, obstacles and route
    --- recalculation. `ApproachTimeout` is only the upper cap now.
    ApproachGrace   = 4500,
    ApproachTimeout = 30000,
    ReturnTimeout   = 30000,
    --- How close the ped must get before the animation starts.
    ArriveRadius    = 1.2,

    --- Extra pause before the clerk walks back, purely cosmetic.
    FinishPause = 800,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- FIXED LOCATIONS (DMV / plate shops) — see shared/locations.lua for the list
-- ─────────────────────────────────────────────────────────────────────────────

Config.Locations = {
    --- Vehicle must be within this distance of the location anchor to be edited.
    VehicleSearchRadius = 8.0,

    --- Engine must be off while the plate is being swapped.
    RequireEngineOff = true,

    --- Player must be OUT of the vehicle.
    RequireOnFoot = true,

    --- Progress bar duration in ms.
    Duration = 10000,

    Payment = {
        Enabled = true,
        Price   = 2500,
        --- 'cash' | 'bank'
        Account = 'bank',
        --- Optional consumable required on top of the money.
        RequireItem = false,
        Item        = 'plate_kit',
        ItemAmount  = 1,
    },

    --- Cooldown (seconds) between two successful changes on the SAME vehicle.
    VehicleCooldown = 300,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- FAKE PLATES (item based, stolen / unowned vehicles only)
-- ─────────────────────────────────────────────────────────────────────────────

Config.FakePlate = {
    Item        = 'fake_plates',
    ItemAmount  = 1,
    ConsumeItem = true,

    --- Session only: never written to the database, gone on restart/despawn.
    --- Optional soft expiry in seconds (0 = lasts until the vehicle despawns).
    Expiry = 0,

    RequireEngineOff = true,
    RequireOnFoot    = true,
    Duration         = 8000,

    --- Hard rule requested by design: never allowed on an owned vehicle.
    AllowOnOwnedVehicles = false,

    --- Distance the player must be from the vehicle to apply it.
    MaxDistance = 4.0,

    --- Cooldown (seconds) between two fake plate applications by the same player.
    PlayerCooldown = 60,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- SECURITY  (server side, non negotiable)
-- ─────────────────────────────────────────────────────────────────────────────

Config.Security = {
    --- Token bucket: max accepted net events per player, per window.
    MaxRequestsPerWindow = 8,
    WindowSeconds        = 20,

    --- Max distance (m) between the player ped and the targeted vehicle,
    --- verified server side with a small tolerance for desync.
    MaxInteractionDistance = 10.0,

    --- Max distance (m) between the player and the claimed location anchor.
    MaxLocationDistance = 12.0,

    --- Consecutive rejected/forged requests before the player is flagged.
    StrikesBeforeAction = 5,

    --- 'none' | 'kick' | 'ban-event'  ('ban-event' triggers nlrp-vplates:security:ban)
    --- The kick reason is the `msg_kicked` locale string.
    ActionOnFlag = 'kick',
}

-- ─────────────────────────────────────────────────────────────────────────────
-- DATABASE MAPPING  (only used when a framework is detected)
-- ─────────────────────────────────────────────────────────────────────────────

Config.SQL = {
    --- Extra tables whose `plate` column must follow a permanent plate change.
    --- Keep them accurate, they are executed inside the same transaction batch.
    CascadeTables = {
        -- { table = 'player_vehicles', column = 'plate' },
        -- { table = 'vehicle_keys',    column = 'plate' },
    },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- DISCORD LOGGING
-- ─────────────────────────────────────────────────────────────────────────────

Config.Webhook = {
    Enabled   = false,
    URL       = '',
    BotName   = 'nlrp-vplates',
    AvatarURL = '',
    --- Also print every log line in the server console.
    Console   = true,

    Colors = {
        success = 3066993,  -- green
        fake    = 15844367, -- gold
        denied  = 15158332, -- red
        exploit = 10038562, -- dark red
    },
}
