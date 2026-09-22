# nlrp-vplates

Licence plate changer for FiveM.
One codebase, four frameworks, five interaction systems, zero hard dependencies.

---

## What it does

| Mode | Trigger | Vehicle | Persistence |
|---|---|---|---|
| **Legal** | Fixed locations from the config (ped + blip + target) | Only vehicles **you own** | Permanent, written to the database |
| **Fake** | `fake_plates` inventory item | Only **unowned** vehicles (stolen) | Session only, never written to the database |

Hard rule: the fake plate item **never works** on a legally registered vehicle.

---

## Compatibility (auto-detected)

| Layer | Supported |
|---|---|
| Framework | `qbx_core`, `qb-core`, `es_extended`, standalone |
| Interaction | `ox_target`, `qb-target`, `interact`, `PolyZone`, native fallback |
| Inventory | `ox_inventory`, `qb-inventory` / `lj-inventory`, `qs-inventory`, `core_inventory` |
| Notifications | `ox_lib`, `qbx_core`, `QBCore`, `ESX`, custom, native NUI |
| Progress bar | `ox_lib`, `qbx_core`, `progressbar`, `esx_progressbar`, custom, native NUI |
| SQL | `oxmysql`, `mysql-async`, `ghmattimysql` |
| UI | Own NUI dialog (format mask, live preview) — no `ox_lib`, no `qb-input` |

Everything is detected at start-up. Any layer can be pinned manually in
`shared/config.lua` (`Config.Framework`, `Config.Target`, `Config.Inventory`,
`Config.Database`).

In **standalone** there is no vehicle ownership: every vehicle counts as unowned,
so only fake plates are available.

---

## Localisation

Translations live in `locales/<iso>.json` and use the **ox_lib locale format**:

```json
{
    "msg": {
        "success": "Licence plate changed to %s."
    }
}
```

* nested objects are flattened into dotted keys → `msg.success`
* values are formatted with `string.format` → `%s`, `%d`, `%.1f`
* `"${other.key}"` references another entry and is resolved at load time

Adding a language = dropping a new file next to `en.json`. Nothing else changes.
Missing keys automatically fall back to the English value, so a partial
translation can never produce an empty notification.

### Language selection

`Config.Locale = 'auto'` follows each framework's own convention, in order:

| Priority | Source | Framework convention |
|---|---|---|
| 1 | `Config.Locale` (when not `'auto'`) | manual override |
| 2 | `ox:locale` convar | ox_lib / qbx_core (`setr ox:locale "ro"`) |
| 3 | `qb_locale` convar | QBCore (`setr qb_locale "ro"`) |
| 4 | `esx:locale` convar, then `ESX.GetConfig().Locale` | ESX Legacy |
| 5 | `en` | fallback |

Both convars are declared with `setr`, so they are replicated and resolve
identically on the client and the server.

### Using ox_lib instead

The JSON files are drop-in compatible with `lib.locale()`. If your server already
standardises on ox_lib, add `'@ox_lib/init.lua'` to `shared_scripts`, delete
`shared/locale.lua` and replace it with:

```lua
lib.locale()
L = locale
```

Keys, files and call sites stay exactly the same.

### Strings in the config

`shared/locations.lua` can reference the locale instead of hardcoding text:
any value starting with `@` is resolved through the locale table.

```lua
label = '@location.dmv_mission_row',   -- resolved via locales/<iso>.json
blip  = { label = '@location.blip' },
```

Plain strings still work if you prefer a fixed, untranslated name.

---

## Plate format

`Config.Plate.Format` pins the exact shape of every plate, character by character.

| Symbol | Meaning |
|---|---|
| `1` | one random digit (`0-9`) |
| `X` | one random letter (`A-Z`) |
| *space* | a literal space, on that exact position |
| `^` | locks the **preceding** character: never randomised, must match exactly |

Any character that is not `1`, `X` or `^` is already literal, so `^` is only
mandatory when you need a literal `1` or `X` (`1^`, `X^`). Writing `N^` instead
of `N` is still recommended — it documents the intent.

```lua
Config.Plate.Format = 'N^ 11 XXX'   -- N 47 KQD    mask shown to the player: N ## ???
Config.Plate.Format = 'L^S^ XXXXX'  -- LS ACFAS    mask: LS ?????
Config.Plate.Format = '11XXX111'    -- 42QWE913    mask: ##???###
Config.Plate.Format = false         -- free-form, only Min/MaxLength apply
```

Optional per-mode overrides, useful when fake plates must look different from
registered ones:

```lua
Config.Plate.FormatLegal = 'L^S^ 11 XXX',
Config.Plate.FormatFake  = 'XXX 111',
```

### How it is enforced

The mask is compiled **once** at start-up into a slot list (`shared/pattern.lua`),
then used on both sides:

- **Client** — the player types only the editable characters. Literal slots are
  inserted automatically and a character that does not fit the next slot (a
  letter where a digit is expected) is simply ignored, so a wrong shape cannot
  even be produced. A dice button fills the whole plate at random.
- **Server** — the composed plate is re-matched against the same mask on commit.
  The client is never trusted; a crafted event with `AAA111` on a `N ## ???`
  server is rejected with `msg.plate_format`.

The mask is validated at load: it cannot start or end with a space, cannot
contain double spaces (the sanitiser collapses them, so such a plate would be
impossible), cannot exceed `MaxLength`, and must keep at least one random slot.
A broken mask never blocks the resource — it is reported in the console and the
plates fall back to free-form validation.

Blacklist and uniqueness rules still apply on top of the mask.

### Format exports

```lua
exports['nlrp-vplates']:GeneratePlate('legal')            -- 'N 47 KQD'
exports['nlrp-vplates']:MatchesPlateFormat('N 47 KQD')    -- true
```

---

## VIP gating (structure only)

`Config.VIP.Enabled = true` reserves the **legal** plate change at the fixed
locations for VIP players. Fake plates stay open to everyone by design — that is
the criminal path, not a perk. Flip `RequireForFake` if you disagree.

```lua
Config.VIP = {
    Enabled         = false,
    RequireForLegal = true,
    RequireForFake  = false,
    CacheSeconds    = 60,
    DefaultResult   = false,  -- fail-safe
}
```

The resource ships the **structure and the contract only** — how a player
becomes VIP is your call, so the logic is yours to write:

| File | Role | You edit it? |
|---|---|---|
| `vip/functions.lua` | shared contract, cache, `CanUse()` entry point | no |
| `vip/server.lua` | `VipService:IsVIP(source)` — the authoritative check | **yes** |
| `vip/client.lua` | mirror of the pushed status, UI hints only | optional |

`vip/server.lua` contains three commented examples to start from: an ACE
permission, a static identifier whitelist and a database query. Delete what you
do not need and return `true` only when the player really is VIP.

```lua
function VipService:IsVIP(source)
    if IsPlayerAceAllowed(source, 'vplates.vip') then return true, 'gold' end
    return false
end
```

Guarantees around it:

- **Fail-safe.** Untouched, `IsVIP()` returns `Config.VIP.DefaultResult`
  (`false`), so enabling VIP without writing any logic denies everyone instead
  of granting everyone.
- **Server-only authority.** The check runs on `OpenSession` (so the UI never
  even opens) and again on `Commit`, in case VIP expired in between. The client
  copy exists purely so the UI can stay honest; forging it locally only earns a
  rejected request.
- **Cached** for `CacheSeconds`, flushed on `playerDropped`.
- **Logged** as a regular denial (`sec.vip_denied`), not as an exploit.
- **Localised** — the refusal is `msg.vip_only`, never a hardcoded string.
- **Zero cost when disabled**: `CanUse()` returns on the first line.

```lua
exports['nlrp-vplates']:IsPlayerVIP(source)   -- server, authoritative
exports['nlrp-vplates']:RefreshVIP(source)    -- server, call on buy/renew/expire
exports['nlrp-vplates']:IsVIP()               -- client, UI hint only
```

---

## Notifications & progress bar

Both are adapters, picked in the config. The rest of the resource calls a single
method and never knows what renders it.

```lua
Config.Notifications.Resource = 'auto'  -- 'ox_lib' | 'qbx' | 'qb' | 'esx' | 'custom' | 'native'
Config.Progress.Resource      = 'auto'  -- same list
```

| Value | Notifications | Progress bar |
|---|---|---|
| `ox_lib` | `exports.ox_lib:notify` | `exports.ox_lib:progressBar` / `progressCircle` |
| `qbx` | `exports.qbx_core:Notify` | ox_lib (shipped with qbx_core) |
| `qb` | `QBCore:Notify` | `progressbar` |
| `esx` | `ESX.ShowNotification` | `esx_progressbar` |
| `native` | our NUI toasts | our NUI bar |
| `custom` | your resource | your resource |

`auto` picks the first available in that order and falls back to `native`.
`custom` is never auto-selected — you have to ask for it explicitly.

ox_lib is called through its **exports**, so `@ox_lib/init.lua` is not added to
our manifest and the resource keeps zero hard dependencies. Forcing a resource
that is not running logs a warning and falls back to `native` instead of
erroring.

```lua
Config.Progress.AllowCancel = true   -- BACKSPACE aborts
Config.Progress.Animation   = true   -- repair animation while the bar runs
Config.Progress.Circle      = false  -- ox_lib only
```

Moving away, dying or entering a vehicle always aborts, whatever the setting.

### Plugging in your own resource

Set `Resource = 'custom'` and fill in the two methods in the `CustomNotify` /
`CustomProgress` classes — same approach as the VIP layer, we ship the contract
and you write the logic.

```lua
function CustomNotify:IsAvailable() return Utils.ResourceReady('my-notify') end
function CustomNotify:Send(kind, message)
    exports['my-notify']:Show(kind, message)   -- kind = success | error | info
end
```

> **Progress bars are security relevant.** `Run(duration, label)` must block for
> the full duration and must return `false` on cancel. Returning `true` early
> makes the commit arrive before the server's `notBefore` timestamp, and the
> player gets flagged for bypassing the bar. `bridge/progress.lua` contains a
> ready-made skeleton for callback-based resources, including the built-in
> cancel/movement/death watcher (`self:_watch(state)`).

The plate input dialog stays our own NUI on purpose: no external library can do
the positional format mask, the live preview or the dice button.

---

## NPC scene

When a player uses a manned location, the clerk does not stand still behind a
progress bar. He actually does the job:

1. drops his idle scenario and unfreezes,
2. takes a `p_num_plate_01` plate in hand,
3. walks to the **rear** bumper, faces the car and works,
4. walks to the **front** bumper and works again,
5. walks back to his desk, is put back to the exact original position and
   heading, restarts his scenario and puts the prop away.

The scene is broadcast, so every player with the ped streamed in sees the same
thing — not just the customer.

```lua
Config.Scene = {
    Enabled      = true,          -- false = plain progress bar, no walking NPC
    Prop         = 'p_num_plate_01',
    PropBone     = 28422,         -- SKEL_R_Hand (60309 = PH_R_Hand)
    PropOffset   = vector3(0.12, 0.02, -0.02),
    PropRotation = vector3(-100.0, 20.0, 0.0),
    Anim         = { dict = '...', clip = '...', flag = 1 },
    WorkDuration = 5000,          -- per bumper
    BumperOffset = 1.1,           -- distance kept from the bumper

    MaxVehicleDistance = 25.0,    -- refuse the job beyond this

    Speed       = 1.0,            -- 1.0 walk, 2.0 run
    RunSpeed    = 2.0,
    RunDistance = 8.0,            -- farther than this, the clerk runs
    WalkRate    = 1.1,            -- real m/s, used to size the walking budget
    RunRate     = 2.8,
    PathFactor  = 2.0,            -- the route is never the straight line
    ApproachGrace   = 4500,
    ApproachTimeout = 30000,      -- upper cap only
    ReturnTimeout   = 30000,
    ArriveRadius    = 1.2,
    FinishPause     = 800,
}
```

> The default animation and the prop offsets are sensible defaults, not tuned
> values. Expect to nudge `PropOffset` / `PropRotation` once on your server.

### How the vehicle is located

Nothing is assumed. Before the clerk moves:

1. the vehicle handle is resolved from the network id **and verified against
   the plate it is currently wearing** — a recycled handle can never send the
   clerk to the wrong car;
2. if the network id cannot be resolved locally, the vehicle is found by
   scanning `GetGamePool('CVehicle')` for that plate;
3. `GetEntityCoords(vehicle)` is read and the real distance to the clerk is
   measured;
4. if it exceeds `MaxVehicleDistance` the job is refused and the player is told
   to park closer (`msg.too_far`). The server checks the same thing at
   `openSession` and again at `reserve`, so the UI never opens for a car that
   is out of range.

With `Config.Debug = true` each step is printed, including both coordinate
sets, the plate read off the vehicle, the distance and the walking budget.

### Pathing

Peds spawned frozen are usually not anchored to the navmesh, so every
pathfinding task fails silently. Before moving, the clerk is unfrozen and
re-seated on the ground (a correction larger than 2 m is refused — that means
the probe hit something else).

Only two movement tasks are used, and the choice matters:

- `TaskFollowNavMeshToCoord`, given **one short probe window** (~1.6 s). The
  only thing checked is whether the clerk actually got closer — a reported
  route means nothing if he is still standing on the kerb. Scenery peds are
  frequently not anchored to a navmesh polygon, and the task then walks them
  off in a random direction instead of failing, which no amount of re-issuing
  recovers.
- `TaskGoStraightToCoord`, the workhorse fallback, with
  `distanceToSlide = 0.0` so the ped is never slid or teleported.

Before tasking, `AddNavmeshRequiredRegion` streams in the navmesh around the
destination and the ped's path flags are opened up (climbovers, drops), because
neither is on by default and a route cannot be computed without them.

`TaskGoToCoordAnyMeans` is deliberately **not** used: "any means" includes
commandeering a nearby vehicle, so the clerk walks away from the car to go
find one to drive.

The walking budget is **derived from the measured distance**
(`distance × PathFactor / rate + ApproachGrace`, capped by `ApproachTimeout`),
and the clerk switches to a run past `RunDistance`. `PathFactor` pays for the
detour around the vehicle, because the straight line is never the route
actually walked.

If he still cannot reach a bumper, the animation does **not** play: the scene
is aborted with `msg.scene_failed` and nothing is charged.

Bumper positions come from `GetModelDimensions` and are projected onto the
ground using the **vehicle's** own height as the sanity reference — the clerk
may be standing on a kerb, or floating if his configured coordinates are off,
so his feet are not a reliable baseline. The arrival check compares horizontal
distance only.

### One customer at a time

Clerk occupancy is **server-authoritative** (`server/occupancy.lua`). While a
scene is running the location is locked; the target option is greyed out on
every client as a courtesy, and a forged request is rejected server side with
`msg.npc_busy`. The lock is only released when the clerk is back at his desk,
or by a janitor if the customer crashed mid-scene.

### Plate reservation

The plate is checked against the owned-vehicles table the moment the player
confirms it, but it is written ~20 s later, when the scene ends. In between it
is **reserved**, so two players can never walk away with the same plate.

### Timing contract

The legal flow has three phases instead of two:

| phase | what happens |
|---|---|
| `openSession` | validation, VIP, ownership, price, clerk must be free — then the UI opens |
| `reserve` | plate validated + DB-checked, clerk locked, plate reserved, **plate stored server side**, scene broadcast |
| `commit` | fired the moment the second plate is fitted: timing + full revalidation, payment, database write |
| `sceneFinished` | the clerk is back at his desk — the location unlocks for the next customer |

Because walking time depends on the navmesh, traffic and where the car was
parked, only `WorkDuration * 2` counts against the anti-bypass timer
(`shared/scene.lua`). The worst case is used solely for ticket expiry and the
lock timeout.

The commit is deliberately sent **before** the walk back, not after. Waiting
for the return trip can add another 15 s and would push the request past the
ticket deadline, which the server would then reject.

From `reserve` onwards the plate is **fixed server side**: `commit` ignores any
plate sent by the client, so the scene cannot be used to smuggle a new value in.

If the ped is not streamed in, or the scene cannot start for any reason, the
flow silently falls back to the configured progress bar.

---

## Installation

1. Copy the `nlrp-vplates` folder into `resources/`.
2. Add to `server.cfg`:
   ```
   ensure nlrp-vplates
   ```
3. Configure the locations in `shared/locations.lua` and everything else in
   `shared/config.lua`.
4. Register the `fake_plates` item in your inventory (see below).

### Item: ox_inventory

`ox_inventory/data/items.lua`:

```lua
['fake_plates'] = {
    label = 'Fake plates',
    weight = 800,
    stack = true,
    close = true,
    description = 'A set of unmarked licence plates.',
    server = {
        export = 'nlrp-vplates.useFakePlate'
    }
},
```

### Item: qb-inventory / lj-inventory

`qb-core/shared/items.lua`:

```lua
['fake_plates'] = {
    name = 'fake_plates', label = 'Fake plates', weight = 800,
    type = 'item', image = 'fake_plates.png', unique = false,
    useable = true, shouldClose = true, description = 'A set of unmarked plates.'
},
```

### Item: ESX

```sql
INSERT INTO items (name, label, weight, rare, can_remove) VALUES ('fake_plates', 'Fake plates', 1, 0, 1);
```

### Item: qs-inventory / core_inventory

Declare the item as `useable` in your inventory's item file; usage is picked up
through the framework's usable-item registration (QBCore/ESX).

---

## Database

The resource **creates no tables**. It uses what already exists:

| Framework | Table | Owner column | Plate column |
|---|---|---|---|
| QBCore / QBX | `player_vehicles` | `citizenid` | `plate` |
| ESX | `owned_vehicles` | `owner` | `plate` (+ JSON `vehicle.plate`) |

If other tables hold the plate (keys, garages, insurance), list them in
`Config.SQL.CascadeTables` — they are updated together with a legal change:

```lua
Config.SQL.CascadeTables = {
    { table = 'vehicle_keys', column = 'plate' },
    { table = 'player_insurance', column = 'plate' },
}
```

Table and column names are validated against `^[%w_]+$` before reaching SQL
(identifiers cannot be bound as parameters, so they go through a strict whitelist).

---

## Security

Nothing the client sends is trusted. Every request goes through:

- **Token bucket** per player (`Config.Security.MaxRequestsPerWindow`).
- **Two-phase ticket flow**: the server issues a ticket with a `notBefore`
  timestamp; a commit arriving before 85% of the progress-bar duration means the
  progress bar was bypassed → strike.
- **One active ticket** per player plus an anti-parallelism lock.
- **Full revalidation on commit**: entity exists, is a vehicle, distance to the
  ped, distance to the location anchor, job, ownership, cooldown, uniqueness.
- **Ownership re-checked atomically inside the UPDATE `WHERE`** (race-condition proof).
- **Rollback**: money and items are returned if the database write fails.
- **Identical sanitisation** on client and server; the server has the final say.
- **No `innerHTML`** in the NUI plus a restrictive CSP → a crafted plate cannot inject markup.
- **Strikes** → kick or ban event (`Config.Security.ActionOnFlag`).
- Everything, including blocked attempts, is forwarded to the Discord webhook.

---

## Performance

- Peds are streamed in/out by distance (spawn 100 m, despawn 150 m); the
  streaming thread sleeps 5 s while the player is far from every location.
- The native interaction fallback runs **one single thread** for all zones with
  adaptive sleep (1000 ms → 250 ms → 0 ms only while actually inside a zone).
- The plate blacklist is pre-indexed into a set (`O(1)`), not scanned per request.
- Ownership cache with a 15 s TTL, invalidated on every write.
- Plates propagate through replicated **state bags**: no sync loops, and late
  joiners render the same plate as everyone else.
- Discord logs are flushed in batches of up to 10 embeds.

---

## Exports (server)

```lua
exports['nlrp-vplates']:GetOriginalPlate(netId)   -- real plate of a "dressed up" vehicle
exports['nlrp-vplates']:IsPlateFake(plate)        -- true if this plate is a live fake
exports['nlrp-vplates']:RevertFakePlate(netId)    -- restore the original plate
exports['nlrp-vplates']:IsPlateOwned(plate)       -- true if the plate belongs to an owned vehicle
```

Server event fired after every successful change:

```lua
AddEventHandler('nlrp-vplates:server:plateChanged', function(src, oldPlate, newPlate, mode)
    -- mode: 'legal' | 'fake'
end)
```

Useful for MDT / police work: `IsPlateFake` + `GetOriginalPlate` let a plate
scanner flag a vehicle running fake plates.

---

## Structure

```
nlrp-vplates/
├── fxmanifest.lua
├── shared/     class.lua (OOP core), config.lua, locations.lua, utils.lua, pattern.lua, locale.lua
├── locales/    en.json, ro.json
├── vip/        functions.lua (contract), server.lua (your logic), client.lua (UI mirror)
├── bridge/     framework.lua, database.lua, inventory.lua, target.lua, notify.lua, progress.lua
├── client/     plates.lua, nui.lua, locations.lua, main.lua
├── server/     webhook.lua, security.lua, ownership.lua, main.lua
└── html/       index.html, style.css, app.js
```

Every compatibility layer is a class implementing the same interface; the rest of
the code neither knows nor cares which framework or target the server runs.
