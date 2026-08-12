local TMGCore = exports['tmg-core']:GetCoreObject() -- This resolves your line 303 error
local PlayerInjuries = {}
local PlayerWeaponWounds = {}
local doctorCount = 0
local doctorCalled = false
local Doctors = {}

-- Fix: the bed 'taken' flags in the shared config were only ever flipped client side,
-- so every server-side "is this bed free" scan saw all beds as free and dumped every
-- patient into bed 1. Occupancy is tracked here instead.
local OccupiedBeds = {}     -- [hospitalIndex][bedId] = true
local OccupiedJailBeds = {} -- [bedId] = true
local PlayerBeds = {}       -- [src] = { bedId = number, hospitalIndex = number|nil }

-- Flags a bed as occupied by src and remembers it so it can be released later.
-- A nil hospitalIndex means a jail bed.
local function TakeBed(src, bedId, hospitalIndex)
	if hospitalIndex then
		if not OccupiedBeds[hospitalIndex] then OccupiedBeds[hospitalIndex] = {} end
		OccupiedBeds[hospitalIndex][bedId] = true
	else
		OccupiedJailBeds[bedId] = true
	end
	PlayerBeds[src] = { bedId = bedId, hospitalIndex = hospitalIndex }
end

-- Frees whatever bed src was occupying, if any.
local function ReleaseBed(src)
	local bed = PlayerBeds[src]
	if not bed then return end
	if bed.hospitalIndex then
		if OccupiedBeds[bed.hospitalIndex] then OccupiedBeds[bed.hospitalIndex][bed.bedId] = nil end
	else
		OccupiedJailBeds[bed.bedId] = nil
	end
	PlayerBeds[src] = nil
end

-- First free bed index for a hospital, or for the jail beds when hospitalIndex is
-- nil. Returns nil when every bed is occupied.
local function GetFreeBed(hospitalIndex)
	if hospitalIndex then
		local hospital = Config.Locations['hospital'][hospitalIndex]
		if not hospital then return nil end
		for i = 1, #hospital['beds'] do
			if not (OccupiedBeds[hospitalIndex] and OccupiedBeds[hospitalIndex][i]) then return i end
		end
	else
		for i = 1, #Config.Locations['jailbeds'] do
			if not OccupiedJailBeds[i] then return i end
		end
	end
	return nil
end

-- Events

-- Compatibility with txAdmin Menu's heal options.
-- This is an admin only server side event that will pass the target player id or -1.
-- Only accepts calls from the txAdmin/monitor resource; fully revives and
-- heals the given player id (or -1 for all/self, per txAdmin convention).
AddEventHandler('txAdmin:events:healedPlayer', function(eventData)
	if GetInvokingResource() ~= 'monitor' or type(eventData) ~= 'table' or type(eventData.id) ~= 'number' then
		return
	end

	TriggerClientEvent('hospital:client:Revive', eventData.id)
	TriggerClientEvent('hospital:client:HealInjuries', eventData.id, 'full')
end)

-- Assigns a specific hospital bed to the calling player, broadcasts the
-- bed as taken, charges the treatment bill, and emails the bill receipt.
RegisterNetEvent('hospital:server:SendToBed', function(bedId, isRevive, hospitalIndex)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if not Player then return end
	local hospital = Config.Locations['hospital'][hospitalIndex]
	if not hospital or not hospital['beds'][bedId] then return end
	-- Fix: the requested bed can already be occupied by the time this arrives, so
	-- fall back to the first free one and only refuse when the hospital is full.
	if OccupiedBeds[hospitalIndex] and OccupiedBeds[hospitalIndex][bedId] then
		bedId = GetFreeBed(hospitalIndex)
		if not bedId then return TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.beds_taken'), 'error') end
	end
	TakeBed(src, bedId, hospitalIndex)
	TriggerClientEvent('hospital:client:SendToBed', src, bedId, hospital['beds'][bedId], isRevive)
	TriggerClientEvent('hospital:client:SetBed', -1, bedId, true, hospitalIndex)
	Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
	exports['tmg-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
	TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost, hospital['name'])
end)

-- Respawns the player into a free bed: a jail bed if they're jailed,
-- otherwise a bed at the given hospital (falling back to bed 1 if none are
-- free); optionally wipes their inventory via tmgnosql, then charges and
-- emails the treatment bill.
RegisterNetEvent('hospital:server:RespawnAtHospital', function(hospitalIndex)
    local src = source
    local Player = TMGCore.Functions.GetPlayer(src)
    
    -- Function to handle inventory wipe via NoSQL
    local function WipeInventoryNoSQL(targetPlayer)
        targetPlayer.Functions.ClearInventory()
        exports['tmgnosql']:SaveToCollection('players', 
            { citizenid = targetPlayer.PlayerData.citizenid }, 
            { inventory = {} }
        )
        TriggerClientEvent('TMGCore:Notify', targetPlayer.PlayerData.source, Lang:t('error.possessions_taken'), 'error')
    end

    -- Fix: both bed scans read the shared config's `taken` flags, which only the
    -- clients ever write, so the first bed always looked free and everyone ended up
    -- in it. The server-side occupancy table is authoritative now, and the bed is
    -- claimed for this player before they are sent to it. Bed 1 stays the fallback
    -- when every bed really is full, since the player still has to respawn somewhere.
    -- The jail fallback also broadcast 'SetBed' instead of 'SetBed2', so it flagged a
    -- hospital bed rather than the jail bed it just used.
    if Player.PlayerData.metadata['injail'] > 0 then
        local bedId = GetFreeBed() or 1
        TakeBed(src, bedId, nil)
        TriggerClientEvent('hospital:client:SendToBed', src, bedId, Config.Locations['jailbeds'][bedId], true)
        TriggerClientEvent('hospital:client:SetBed2', -1, bedId, true)
        if Config.WipeInventoryOnRespawn then WipeInventoryNoSQL(Player) end -- Fixed NoSQL
    else
        -- Regular Hospital Beds
        local bedId = GetFreeBed(hospitalIndex) or 1
        TakeBed(src, bedId, hospitalIndex)
        TriggerClientEvent('hospital:client:SendToBed', src, bedId, Config.Locations['hospital'][hospitalIndex]['beds'][bedId], true)
        TriggerClientEvent('hospital:client:SetBed', -1, bedId, true, hospitalIndex)
        if Config.WipeInventoryOnRespawn then WipeInventoryNoSQL(Player) end -- Fixed NoSQL
    end

    -- Common Money Logic
    local hospital = Config.Locations['hospital'][hospitalIndex]
    Player.Functions.RemoveMoney('bank', Config.BillCost, 'respawned-at-hospital')
    exports['tmg-banking']:AddMoney('ambulance', Config.BillCost, 'Player treatment')
    TriggerClientEvent('hospital:client:SendBillEmail', src, Config.BillCost, hospital and hospital['name'])
end)

-- Broadcasts an EMS alert (with the sender's coords and message text) to
-- every on-duty ambulance job player.
RegisterNetEvent('hospital:server:ambulanceAlert', function(text)
	local src = source
	local ped = GetPlayerPed(src)
	local coords = GetEntityCoords(ped)
	local players = TMGCore.Functions.GetTMGPlayers()
	for _, v in pairs(players) do
		if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
			TriggerClientEvent('hospital:client:ambulanceAlert', v.PlayerData.source, coords, text)
		end
	end
end)

-- Marks the bed the caller is actually occupying as free again for all clients.
-- Fix: the server never cleared its own occupancy, so a bed stayed claimed for the rest of the
-- session once someone had used it. The broadcast also echoed the client's own id/hospitalIndex,
-- which need not be the bed this player holds -- so a crafted call freed someone else's bed on
-- every client while releasing only its own server-side record. Both now come from PlayerBeds.
RegisterNetEvent('hospital:server:LeaveBed', function()
	local src = source
	local bed = PlayerBeds[src]
	if not bed then return end

	local bedId, hospitalIndex = bed.bedId, bed.hospitalIndex
	ReleaseBed(src)
	TriggerClientEvent('hospital:client:SetBed', -1, bedId, false, hospitalIndex)
end)

-- Stores the calling player's current injury/bleed data server-side, used
-- by status checks and doctor treatment.
RegisterNetEvent('hospital:server:SyncInjuries', function(data)
	local src = source
	PlayerInjuries[src] = data
end)

-- Stores the calling player's list of recorded weapon-wound entries
-- server-side.
RegisterNetEvent('hospital:server:SetWeaponDamage', function(data)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player then
		PlayerWeaponWounds[Player.PlayerData.source] = data
	end
end)

-- Clears the calling player's tracked weapon wounds, both in memory and in
-- their persisted 'injuries' metadata.
RegisterNetEvent('hospital:server:RestoreWeaponDamage', function()
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if not Player then return end
	PlayerWeaponWounds[Player.PlayerData.source] = nil
	Player.Functions.SetMetaData('injuries', {})
end)

-- Persists the calling player's dead/alive state to their metadata.
RegisterNetEvent('hospital:server:SetDeathStatus', function(isDead)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('isdead', isDead)
	end
end)

-- Persists the calling player's last-stand state to their metadata.
RegisterNetEvent('hospital:server:SetLaststandStatus', function(bool)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('inlaststand', bool)
	end
end)

-- Persists the calling player's current armor value to their metadata.
RegisterNetEvent('hospital:server:SetArmor', function(amount)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player then
		Player.Functions.SetMetaData('armor', amount)
	end
end)

-- Doctor-side wound treatment: if the caller is on the ambulance job,
-- consumes a bandage from them and fully heals the target patient.
RegisterNetEvent('hospital:server:TreatWounds', function(playerId)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	local Patient = TMGCore.Functions.GetPlayer(playerId)
	if Patient then
		if Player.PlayerData.job.name == 'ambulance' then
			exports['tmg-inventory']:RemoveItem(src, 'bandage', 1, false, 'hospital:server:TreatWounds')
			TriggerClientEvent('tmg-inventory:client:ItemBox', src, TMGCore.Shared.Items['bandage'], 'remove')
			TriggerClientEvent('hospital:client:HealInjuries', Patient.PlayerData.source, 'full')
		end
	end
end)

-- Registers the calling player as an on-duty ambulance doctor, increments
-- and broadcasts the global doctor count.
RegisterNetEvent('hospital:server:AddDoctor', function(job)
	if job == 'ambulance' then
		local src = source
		doctorCount = doctorCount + 1
		TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
		Doctors[src] = true
	end
end)

-- Deregisters the calling player as an on-duty ambulance doctor,
-- decrements and broadcasts the global doctor count.
RegisterNetEvent('hospital:server:RemoveDoctor', function(job)
	if job == 'ambulance' then
		local src = source
		doctorCount = doctorCount - 1
		TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
		Doctors[src] = nil
	end
end)

-- On disconnect, removes the player from the on-duty doctor count if they
-- were registered as one, and frees any bed they were still occupying.
AddEventHandler('playerDropped', function()
	local src = source
	-- Fix: a player who disconnected while in a bed left it flagged as occupied.
	ReleaseBed(src)
	if Doctors[src] then
		doctorCount = doctorCount - 1
		TriggerClientEvent('hospital:client:SetDoctorCount', -1, doctorCount)
		Doctors[src] = nil
	end
end)

-- Revives a target patient if the caller is an EMS doctor or holds a first
-- aid kit; charges cash for the 'oldMan' (self-service) path, otherwise
-- just consumes the kit. If neither condition is met the revive is simply
-- refused.
RegisterNetEvent('hospital:server:RevivePlayer', function(playerId, isOldMan)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	local Patient = TMGCore.Functions.GetPlayer(playerId)
	local oldMan = isOldMan or false
	if Patient then
		if Player.PlayerData.job.name == 'ambulance' or TMGCore.Functions.HasItem(src, 'firstaid', 1) then
			if oldMan then
				if Player.Functions.RemoveMoney('cash', 5000, 'revived-player') then
					exports['tmg-inventory']:RemoveItem(src, 'firstaid', 1, false, 'hospital:server:RevivePlayer')
					TriggerClientEvent('tmg-inventory:client:ItemBox', src, TMGCore.Shared.Items['firstaid'], 'remove')
					TriggerClientEvent('hospital:client:Revive', Patient.PlayerData.source)
				else
					TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_enough_money'), 'error')
				end
			else
				exports['tmg-inventory']:RemoveItem(src, 'firstaid', 1, false, 'hospital:server:RevivePlayer')
				TriggerClientEvent('tmg-inventory:client:ItemBox', src, TMGCore.Shared.Items['firstaid'], 'remove')
				TriggerClientEvent('hospital:client:Revive', Patient.PlayerData.source)
			end
		else
			-- Fix: this branch used to permanently ban the caller. Losing the ambulance
			-- job, going off duty or having the first aid kit consumed between the
			-- client request and this handler are all things that happen to legitimate
			-- players, so the revive is refused with a notification instead.
			TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.no_firstaid'), 'error')
		end
	end
end)

-- Notifies all on-duty doctors that a patient needs attention at the given
-- hospital, throttled by Config.DocCooldown to prevent alert spam.
RegisterNetEvent('hospital:server:SendDoctorAlert', function(hospitalName)
	local src = source
	if not doctorCalled then
		doctorCalled = true
		local players = TMGCore.Functions.GetTMGPlayers()
		for _, v in pairs(players) do
			if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
				TriggerClientEvent('TMGCore:Notify', v.PlayerData.source, Lang:t('info.dr_needed', { hospital = hospitalName }), 'ambulance')
			end
		end
		SetTimeout(Config.DocCooldown * 60000, function()
			doctorCalled = false
		end)
	else
		TriggerClientEvent('TMGCore:Notify', src, 'Doctor has already been notified', 'error')
	end
end)

-- Forwards a first-aid-use attempt to the target player's client to confirm
-- whether they can currently be helped.
RegisterNetEvent('hospital:server:UseFirstAid', function(targetId)
	local src = source
	local Target = TMGCore.Functions.GetPlayer(targetId)
	if Target then
		TriggerClientEvent('hospital:client:CanHelp', targetId, src)
	end
end)

-- Relays the target's "can be helped" answer back to the would-be helper:
-- starts the CPR help sequence if allowed, otherwise notifies them it's not
-- possible.
RegisterNetEvent('hospital:server:CanHelp', function(helperId, canHelp)
	local src = source
	if canHelp then
		TriggerClientEvent('hospital:client:HelpPerson', helperId, src)
	else
		TriggerClientEvent('TMGCore:Notify', helperId, Lang:t('error.cant_help'), 'error')
	end
end)

-- Consumes one bandage from the calling player's inventory.
RegisterNetEvent('hospital:server:removeBandage', function()
	local Player = TMGCore.Functions.GetPlayer(source)
	if not Player then return end
	exports['tmg-inventory']:RemoveItem(source, 'bandage', 1, false, 'hospital:server:removeBandage')
end)

-- Consumes one IFAK from the calling player's inventory.
RegisterNetEvent('hospital:server:removeIfaks', function()
	local Player = TMGCore.Functions.GetPlayer(source)
	if not Player then return end
	exports['tmg-inventory']:RemoveItem(source, 'ifaks', 1, false, 'hospital:server:removeIfaks')
end)

-- Consumes one painkillers item from the calling player's inventory.
RegisterNetEvent('hospital:server:removePainkillers', function()
	local Player = TMGCore.Functions.GetPlayer(source)
	if not Player then return end
	exports['tmg-inventory']:RemoveItem(source, 'painkillers', 1, false, 'hospital:server:removePainkillers')
end)

-- Resets the calling player's hunger/thirst metadata to full and syncs the
-- new values to their HUD.
RegisterNetEvent('hospital:server:resetHungerThirst', function()
	local Player = TMGCore.Functions.GetPlayer(source)

	if not Player then return end

	Player.Functions.SetMetaData('hunger', 100)
	Player.Functions.SetMetaData('thirst', 100)

	TriggerClientEvent('hud:client:UpdateNeeds', source, 100, 100)
end)

-- Opens the calling player's personal ambulance-job stash inventory, keyed
-- by their citizen id.
RegisterNetEvent('tmg-ambulancejob:server:stash', function()
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if not Player then return end
	local citizenId = Player.PlayerData.citizenid
	local stashName = 'ambulancestash_' .. citizenId
	exports['tmg-inventory']:OpenInventory(src, stashName)
end)

-- Callbacks

-- Returns the number of currently on-duty ambulance doctors.
TMGCore.Functions.CreateCallback('hospital:GetDoctors', function(_, cb)
	local amount = 0
	local players = TMGCore.Functions.GetTMGPlayers()
	for _, v in pairs(players) do
		if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
			amount = amount + 1
		end
	end
	cb(amount)
end)

-- Returns a combined injury report for the given player: bleed level,
-- damaged limbs, and weapon-wound entries.
TMGCore.Functions.CreateCallback('hospital:GetPlayerStatus', function(_, cb, playerId)
	local Player = TMGCore.Functions.GetPlayer(playerId)
	local injuries = {}
	injuries['WEAPONWOUNDS'] = {}
	if Player then
		if PlayerInjuries[Player.PlayerData.source] then
			if (PlayerInjuries[Player.PlayerData.source].isBleeding > 0) then
				injuries['BLEED'] = PlayerInjuries[Player.PlayerData.source].isBleeding
			end
			for k, _ in pairs(PlayerInjuries[Player.PlayerData.source].limbs) do
				if PlayerInjuries[Player.PlayerData.source].limbs[k].isDamaged then
					injuries[k] = PlayerInjuries[Player.PlayerData.source].limbs[k]
				end
			end
		end
		if PlayerWeaponWounds[Player.PlayerData.source] then
			for k, v in pairs(PlayerWeaponWounds[Player.PlayerData.source]) do
				injuries['WEAPONWOUNDS'][k] = v
			end
		end
	end
	cb(injuries)
end)

-- Returns the calling player's current bleed level, or nil if unknown.
TMGCore.Functions.CreateCallback('hospital:GetPlayerBleeding', function(source, cb)
	local src = source
	if PlayerInjuries[src] and PlayerInjuries[src].isBleeding then
		cb(PlayerInjuries[src].isBleeding)
	else
		cb(nil)
	end
end)

-- Commands

-- /911e command: sends an EMS report (custom message or default civilian
-- call text) with the caller's location to all on-duty doctors.
TMGCore.Commands.Add('911e', Lang:t('info.ems_report'), { { name = 'message', help = Lang:t('info.message_sent') } }, false, function(source, args)
	local src = source
	local message
	if args[1] then message = table.concat(args, ' ') else message = Lang:t('info.civ_call') end
	local ped = GetPlayerPed(src)
	local coords = GetEntityCoords(ped)
	local players = TMGCore.Functions.GetTMGPlayers()
	for _, v in pairs(players) do
		if v.PlayerData.job.name == 'ambulance' and v.PlayerData.job.onduty then
			TriggerClientEvent('hospital:client:ambulanceAlert', v.PlayerData.source, coords, message)
		end
	end
end)

-- /status command: EMS-only, opens the health-check flow on a nearby player.
TMGCore.Commands.Add('status', Lang:t('info.check_health'), {}, false, function(source, _)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:CheckStatus', src)
	else
		TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

-- /heal command: EMS-only, triggers the bandage/wound-treatment flow on a
-- nearby player.
TMGCore.Commands.Add('heal', Lang:t('info.heal_player'), {}, false, function(source, _)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:TreatWounds', src)
	else
		TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

-- /revivep command: EMS-only, triggers the first-aid revive flow on a
-- nearby player.
TMGCore.Commands.Add('revivep', Lang:t('info.revive_player'), {}, false, function(source, _)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player.PlayerData.job.name == 'ambulance' then
		TriggerClientEvent('hospital:client:RevivePlayer', src)
	else
		TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_ems'), 'error')
	end
end)

-- /revive command (admin): fully revives the target player id, or the
-- caller themselves if no id is given.
TMGCore.Commands.Add('revive', Lang:t('info.revive_player_a'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = TMGCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:Revive', Player.PlayerData.source)
		else
			TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:Revive', src)
	end
end, 'admin')

-- /setpain command (admin): forces bleed/bone trauma on the target player
-- id, or the caller themselves if no id is given.
TMGCore.Commands.Add('setpain', Lang:t('info.pain_level'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = TMGCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:SetPain', Player.PlayerData.source)
		else
			TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:SetPain', src)
	end
end, 'admin')

-- /kill command (admin): kills the target player id, or the caller
-- themselves if no id is given.
TMGCore.Commands.Add('kill', Lang:t('info.kill'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = TMGCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:KillPlayer', Player.PlayerData.source)
		else
			TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:KillPlayer', src)
	end
end, 'admin')

-- /aheal command (admin): fully heals the target player id, or the caller
-- themselves if no id is given.
TMGCore.Commands.Add('aheal', Lang:t('info.heal_player_a'), { { name = 'id', help = Lang:t('info.player_id') } }, false, function(source, args)
	local src = source
	if args[1] then
		local Player = TMGCore.Functions.GetPlayer(tonumber(args[1]))
		if Player then
			TriggerClientEvent('hospital:client:adminHeal', Player.PlayerData.source)
		else
			TriggerClientEvent('TMGCore:Notify', src, Lang:t('error.not_online'), 'error')
		end
	else
		TriggerClientEvent('hospital:client:adminHeal', src)
	end
end, 'admin')

-- Items

-- Handles using an 'ifaks' item: if the player still has it, triggers the
-- client-side IFAK use flow.
TMGCore.Functions.CreateUseableItem('ifaks', function(source, item)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UseIfaks', src)
	end
end)

-- Handles using a 'bandage' item: if the player still has it, triggers the
-- client-side bandage use flow.
TMGCore.Functions.CreateUseableItem('bandage', function(source, item)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UseBandage', src)
	end
end)

-- Handles using a 'painkillers' item: if the player still has it, triggers
-- the client-side painkillers use flow.
TMGCore.Functions.CreateUseableItem('painkillers', function(source, item)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UsePainkillers', src)
	end
end)

-- Handles using a 'firstaid' item: if the player still has it, triggers the
-- client-side first-aid use flow.
TMGCore.Functions.CreateUseableItem('firstaid', function(source, item)
	local src = source
	local Player = TMGCore.Functions.GetPlayer(src)
	if Player.Functions.GetItemByName(item.name) ~= nil then
		TriggerClientEvent('hospital:client:UseFirstAid', src)
	end
end)

-- Export for other resources to query the current on-duty doctor count.
exports('GetDoctorCount', function() return doctorCount end)
