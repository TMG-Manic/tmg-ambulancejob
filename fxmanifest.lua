fx_version 'cerulean'
game 'gta5'
lua54 'yes'
author 'TMG_Manic'
description 'This is the ambulance job, has health and other assorted things attached to it that are necessary to function.'
version '1.0.0'

shared_scripts {
	'@tmg-core/shared/locale.lua',
	'locales/en.lua',
	'locales/*.lua',
	'config.lua'
}

client_scripts {
	'client/main.lua',
	'client/wounding.lua',
	'client/laststand.lua',
	'client/job.lua',
	'client/dead.lua',
	'@PolyZone/client.lua',
	'@PolyZone/BoxZone.lua',
	'@PolyZone/ComboZone.lua'
}

server_scripts {
	'server/main.lua'
}

-- Declares the tmg-core dependency this resource already relies on via
-- exports['tmg-core']:GetCoreObject(). Without it FXServer starts this resource even when
-- tmg-core failed, and it throws "No such export GetCoreObject" at load instead of
-- refusing to start.
dependencies { 'tmg-core' }
