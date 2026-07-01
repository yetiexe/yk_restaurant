fx_version 'cerulean'
game 'gta5'

author 'Yeti King (YK)'
description 'YK Restaurant - player-owned/managed restaurant business for Qbox'
version '1.0.0'
repository ''

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'config/shared.lua'
}

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'config/shared.lua'
}

-- NOTE: no `dependencies` block on purpose. server.cfg already ensures
-- ox_lib/qbx_core/ox_target/[ox]/[qbx] before [yk], and all export calls happen at
-- runtime. A dependencies block here made FXServer silently refuse to auto-start the
-- resource at boot while ox_inventory/ox_target were still initializing.

lua54 'yes'
use_experimental_fxv2_oal 'yes'
