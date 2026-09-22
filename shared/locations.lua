--[[
    nlrp-vplates | shared/locations.lua
    Fixed plate-shop locations. Every entry is fully self contained:
    ped + blip + target are configured per location.

    Fields:
      id        unique string id (used as the network contract, keep it stable)
      label     shown in the target / NUI header
      coords    vector4(x, y, z, heading) -> anchor + ped heading
      radius    interaction radius (m) used by polyzone/native fallbacks
      ped       false to disable, or { model = 'hash|name', scenario = '...', frozen = true }
      blip      false to disable, or { sprite, color, scale, label, display }
      price     nil -> Config.Locations.Payment.Price, or a number override
      jobs      nil -> everyone, or { 'mechanic', 'police' } to restrict
      distance  target draw distance (m)
]]

Config.LocationList = {
    {
        id     = 'dmv_mission_row',
        label  = '@location.dmv_mission_row',
        coords = vector4(-955.31, -2051.42, 9.40, 201.26),
        radius = 1.6,
        price  = 2500,
        distance = 2.5,
        ped = {
            model    = 's_m_m_dockwork_01',
            scenario = 'WORLD_HUMAN_CLIPBOARD',
            frozen   = true,
        },
        blip = {
            sprite  = 446,
            color   = 3,
            scale   = 0.75,
            label   = '@location.blip',
            display = 4,
        },
    },
    {
        id     = 'tuning_sandy',
        label  = '@location.tuning_sandy',
        coords = vec4(1175.05, 2640.16, 37.75, 0.0),
        radius = 1.6,
        price  = 3500,
        distance = 2.5,
        ped = {
            model    = 's_m_y_xmech_02',
            scenario = 'WORLD_HUMAN_WELDING',
            frozen   = true,
        },
        blip = false,
    },
    {
        id     = 'lscustoms_burton',
        label  = '@location.lscustoms_burton',
        coords = vec4(-337.13, -136.86, 39.01, 250.0),
        radius = 1.8,
        price  = 4000,
        distance = 2.5,
        jobs   = nil,
        ped = {
            model    = 's_m_y_xmech_01',
            scenario = 'WORLD_HUMAN_CLIPBOARD',
            frozen   = true,
        },
        blip = {
            sprite  = 446,
            color   = 3,
            scale   = 0.7,
            label   = '@location.blip',
            display = 4,
        },
    },
}
