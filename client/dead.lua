local TMGCore = exports['tmg-core']:GetCoreObject()

if not MedState then 
    MedState = { isDead = false, inLastStand = false, deathTime = 0, emsNotified = false, isEscorted = false, isInBed = false } 
end

local DeadState = {
    animDict = 'dead',
    anim = 'dead_a',
    vehDict = 'veh@low@front_ps@idle_duck',
    vehAnim = 'sit',
    holdToRespawn = 5,
    timerActive = false
}


local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local timeout = 0
    while not HasAnimDictLoaded(dict) do
        Wait(10)
        timeout = timeout + 1
        if timeout > 100 then return false end -- 1000ms timeout safety
    end
    return true
end

local function DrawTxt(x, y, width, height, scale, text, r, g, b, a)
    SetTextFont(GetConvar('tmg_locale', 'en') == 'en' and 4 or 1)
    SetTextProportional(0)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    SetTextDropShadow(0, 0, 0, 0, 255)
    SetTextEdge(2, 0, 0, 0, 255)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x - width / 2, y - height / 2 + 0.005)
end


function OnDeath()
    if MedState.isDead then return end 
    
    MedState.isDead = true
    TriggerServerEvent('hospital:server:SetDeathStatus', true)
    TriggerServerEvent('InteractSound_SV:PlayOnSource', 'demo', 0.1)
    
    local ped = PlayerPedId()

    CreateThread(function()
        local settleTimeout = 0
        while (GetEntitySpeed(ped) > 0.5 or IsPedRagdoll(ped)) and settleTimeout < 50 do
            Wait(100)
            settleTimeout = settleTimeout + 1
        end

        if MedState.isDead then
            local pos = GetEntityCoords(ped)
            local heading = GetEntityHeading(ped)

            if IsPedInAnyVehicle(ped, false) then
                local veh = GetVehiclePedIsIn(ped, false)
                local vehseats = GetVehicleModelNumberOfSeats(GetEntityModel(veh))
                
                NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z + 0.5, heading, true, false)
                
                for i = -1, vehseats - 1 do
                    if GetPedInVehicleSeat(veh, i) == ped or IsVehicleSeatFree(veh, i) then
                        SetPedIntoVehicle(ped, veh, i)
                        break
                    end
                end
                
                if loadAnimDict(DeadState.vehDict) then
                    TaskPlayAnim(ped, DeadState.vehDict, DeadState.vehAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                end
            else
                NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z + 0.5, heading, true, false)
                if loadAnimDict(DeadState.animDict) then
                    TaskPlayAnim(ped, DeadState.animDict, DeadState.anim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                end
            end

            SetEntityInvincible(ped, true)
            SetEntityHealth(ped, GetEntityMaxHealth(ped))
            TriggerServerEvent('hospital:server:ambulanceAlert', Lang:t('info.civ_died'))
        end
    end)
end


function DeathTimer()
    if DeadState.timerActive then return end
    
    CreateThread(function()
        DeadState.timerActive = true
        DeadState.holdToRespawn = 5

        while MedState.isDead do
            Wait(1000)
            MedState.deathTime = MedState.deathTime - 1

            if MedState.deathTime <= 0 then
                if IsControlPressed(0, 38) and DeadState.holdToRespawn <= 0 and not MedState.isInBed then
                    TriggerEvent('hospital:client:RespawnAtHospital')
                    DeadState.holdToRespawn = 5
                elseif IsControlPressed(0, 38) then
                    DeadState.holdToRespawn = math.max(0, DeadState.holdToRespawn - 1)
                elseif IsControlReleased(0, 38) then
                    DeadState.holdToRespawn = 5
                end
            end
        end
        DeadState.timerActive = false
    end)
end

AddEventHandler('gameEventTriggered', function(eventName, data)
    if eventName ~= 'CEventNetworkEntityDamage' then return end

    local victim, attacker, victimDied, weapon = data[1], data[2], data[4], data[7]
    if not IsEntityAPed(victim) then return end
    
    if victimDied and NetworkGetPlayerIndexFromPed(victim) == PlayerId() and IsEntityDead(PlayerPedId()) then
        if not MedState.inLastStand then
            if SetLaststand then SetLaststand(true) end
        elseif MedState.inLastStand and not MedState.isDead then
            if SetLaststand then SetLaststand(false) end
            
            local playerid = NetworkGetPlayerIndexFromPed(victim)
            local playerName = GetPlayerName(playerid) .. ' (' .. GetPlayerServerId(playerid) .. ')'
            
            local killerId = NetworkGetPlayerIndexFromPed(attacker)
            local killerName = killerId ~= -1 and GetPlayerName(killerId) .. ' (' .. GetPlayerServerId(killerId) .. ')' or Lang:t('info.self_death')
            
            local weaponLabel = (TMGCore.Shared.Weapons[weapon] and TMGCore.Shared.Weapons[weapon].label) or 'Unknown'
            local weaponName = (TMGCore.Shared.Weapons[weapon] and TMGCore.Shared.Weapons[weapon].name) or 'Unknown'
            
            TriggerServerEvent('tmg-log:server:CreateLog', 'death', Lang:t('logs.death_log_title', { playername = playerName, playerid = GetPlayerServerId(playerid) }), 'red', Lang:t('logs.death_log_message', { killername = killerName, playername = playerName, weaponlabel = weaponLabel, weaponname = weaponName }))
            
            MedState.deathTime = Config.DeathTime
            OnDeath()
            DeathTimer()
        end
    end
end)

-- [[ 5. STATE CONTROL LOOP (UI & ANIMATIONS) ]]

CreateThread(function()
while true do
        local sleep = 1000
        if MedState.isDead or MedState.inLastStand then
            sleep = 0 
            local ped = PlayerPedId()

            DisableAllControlActions(0)
            
            DisableControlAction(0, 36, true) -- INPUT_DUCK
            DisableControlAction(0, 289, true) -- INPUT_REPLAY_SCREENSHOT (F2 often interferes)
            
            EnableControlAction(0, 1, true)   -- Look LR
            EnableControlAction(0, 2, true)   -- Look UD
            EnableControlAction(0, 245, true) -- Chat
            EnableControlAction(0, 249, true) -- Voice
            EnableControlAction(0, 322, true) -- ESC Menu

            if not IsEntityPlayingAnim(ped, "combat@damage@writhe", "writhe_loop", 3) and 
               not IsEntityPlayingAnim(ped, "dead", "dead_a", 3) and 
               not MedState.isInBed and not MedState.isEscorted then
                
                local dict = MedState.isDead and "dead" or "combat@damage@writhe"
                local anim = MedState.isDead and "dead_a" or "writhe_loop"
                
                TaskPlayAnim(ped, dict, anim, 8.0, 8.0, -1, 1, 0, false, false, false)
            end

            if MedState.isDead then
                if not MedState.isInBed then
                    if MedState.deathTime > 0 then
                        DrawTxt(0.93, 1.44, 1.0, 1.0, 0.6, Lang:t('info.respawn_txt', { deathtime = math.ceil(MedState.deathTime) }), 255, 255, 255, 255)
                    else
                        DrawTxt(0.865, 1.44, 1.0, 1.0, 0.6, Lang:t('info.respawn_revive', { holdtime = DeadState.holdToRespawn, cost = Config.BillCost }), 255, 255, 255, 255)
                    end
                end

                if IsPedInAnyVehicle(ped, false) then
                    if not IsEntityPlayingAnim(ped, DeadState.vehDict, DeadState.vehAnim, 3) then
                        loadAnimDict(DeadState.vehDict)
                        TaskPlayAnim(ped, DeadState.vehDict, DeadState.vehAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                    end
                elseif not MedState.isInBed then
                    if not IsEntityPlayingAnim(ped, DeadState.animDict, DeadState.anim, 3) then
                        loadAnimDict(DeadState.animDict)
                        TaskPlayAnim(ped, DeadState.animDict, DeadState.anim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                    end
                end

                SetCurrentPedWeapon(ped, `WEAPON_UNARMED`, true)
                
            elseif MedState.inLastStand then
                if LaststandTime > Config.MinimumRevive then
                    DrawTxt(0.94, 1.44, 1.0, 1.0, 0.6, Lang:t('info.bleed_out', { time = math.ceil(LaststandTime) }), 255, 255, 255, 255)
                else
                    DrawTxt(0.845, 1.44, 1.0, 1.0, 0.6, Lang:t('info.bleed_out_help', { time = math.ceil(LaststandTime) }), 255, 255, 255, 255)
                    
                    if not MedState.emsNotified then
                        DrawTxt(0.91, 1.40, 1.0, 1.0, 0.6, Lang:t('info.request_help'), 255, 255, 255, 255)
                        if IsControlJustPressed(0, 47) then 
                            TriggerServerEvent('hospital:server:ambulanceAlert', Lang:t('info.civ_down'))
                            MedState.emsNotified = true
                        end
                    else
                        DrawTxt(0.90, 1.40, 1.0, 1.0, 0.6, Lang:t('info.help_requested'), 255, 255, 255, 255)
                    end
                end

                local lsDict, lsAnim = 'combat@damage@writhe', 'writhe_loop'
                if not MedState.isEscorted then
                    if IsPedInAnyVehicle(ped, false) then
                        if not IsEntityPlayingAnim(ped, DeadState.vehDict, DeadState.vehAnim, 3) then
                            loadAnimDict(DeadState.vehDict)
                            TaskPlayAnim(ped, DeadState.vehDict, DeadState.vehAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                        end
                    else
                        if not IsEntityPlayingAnim(ped, lsDict, lsAnim, 3) then
                            loadAnimDict(lsDict)
                            TaskPlayAnim(ped, lsDict, lsAnim, 1.0, 1.0, -1, 1, 0, 0, 0, 0)
                        end
                    end
                else
                    if IsPedInAnyVehicle(ped, false) and IsEntityPlayingAnim(ped, DeadState.vehDict, DeadState.vehAnim, 3) then
                        StopAnimTask(ped, DeadState.vehDict, DeadState.vehAnim, 3)
                    elseif IsEntityPlayingAnim(ped, lsDict, lsAnim, 3) then
                        StopAnimTask(ped, lsDict, lsAnim, 3)
                    end
                end
            end
        end
        Wait(sleep)
    end
end)