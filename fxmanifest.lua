fx_version 'cerulean'
game 'gta5'

name 'nlrp-vplates'
author 'NewLife Roleplay & Martin Riggs'
description 'Licence plate changer - QBCore / QBX / ESX / Standalone'
version '1.0.0'

-- ─────────────────────────────────────────────────────────────────────────────
-- Load order matters:
--   Class -> Config -> Utils -> Format masks -> Framework bridge -> Locale
-- The locale service reads the framework's own locale convar/config, so the
-- framework bridge has to be resolved before it.
-- ─────────────────────────────────────────────────────────────────────────────

shared_scripts {
    'shared/class.lua',
    'shared/config.lua',
    'shared/locations.lua',
    'shared/utils.lua',
    'shared/pattern.lua',
    'shared/scene.lua',
    'vip/functions.lua',
    'bridge/framework.lua',
    'shared/locale.lua',
}

client_scripts {
    'bridge/target.lua',
    'bridge/notify.lua',
    'bridge/progress.lua',
    'vip/client.lua',
    'client/plates.lua',
    'client/nui.lua',
    'client/locations.lua',
    'client/scene.lua',
    'client/main.lua',
}

server_scripts {
    'bridge/database.lua',
    'bridge/inventory.lua',
    'server/webhook.lua',
    'server/security.lua',
    'server/occupancy.lua',
    'vip/server.lua',
    'server/ownership.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'locales/*.json',
}

-- Everything below is optional at runtime: the resource auto-detects what is
-- actually running and degrades gracefully when something is missing.
dependencies {
    '/server:5848',
    '/onesync',
}
