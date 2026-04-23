-- [[ TMG MAINFRAME: LAST STAND PROTOCOL ]]
local TMGCore = exports['tmg-core']:GetCoreObject()

-- Legacy Global Exports (Kept for compatibility with other resources)
InLaststand = false 
LaststandTime = 0

-- [[ 1. UTILITIES ]]
local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local timeout = 0
    while not HasAnimDictLoaded(dict) do
        Wait(10)
        timeout = timeout + 1
        if timeout > 100 then return false end 
    end
    return true
end

-- [[ 2. CORE LOGIC ]]
function SetLaststand(bool)
    local ped = PlayerPedId()

    if bool then
        -- SINGLETON GUARD
        if MedState.inLastStand then return end 

        MedState.inLastStand = true
        MedState.timer = Config.ReviveInterval -- Unified Matrix Timer
        
        -- Sync Legacy Globals
        InLaststand = true 
        LaststandTime = MedState.timer

        TriggerServerEvent('InteractSound_SV:PlayOnSource', 'demo', 0.1)

        CreateThread(function()
            -- Non-Blocking Physics Check
            local settleTimeout = 0
            while (GetEntitySpeed(ped) > 0.5 or IsPedRagdoll(ped)) and settleTimeout < 50 do 
                Wait(100) 
                settleTimeout = settleTimeout + 1
            end

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
                
                if loadAnimDict('veh@low@front_ps@idle_duck') then
                    TaskPlayAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 1.0, 8.0, -1, 1, -1, false, false, false)
                end
            else
                NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z + 0.5, heading, true, false)
                if loadAnimDict('combat@damage@writhe') then
                    TaskPlayAnim(ped, 'combat@damage@writhe', 'writhe_loop', 1.0, 8.0, -1, 1, -1, false, false, false)
                end
            end
            
            SetEntityHealth(ped, 150)
            TriggerServerEvent('hospital:server:ambulanceAlert', Lang:t('info.civ_down'))
        end)

    else
        -- STATE TERMINATION
        MedState.inLastStand = false
        MedState.timer = 0
        InLaststand = false
        LaststandTime = 0
        
        StopAnimTask(ped, 'combat@damage@writhe', 'writhe_loop', 1.0)
        StopAnimTask(ped, 'veh@low@front_ps@idle_duck', 'sit', 1.0)
    end

    TriggerServerEvent('hospital:server:SetLaststandStatus', bool)
end

-- [[ 3. HEARTBEAT ENGINE ]]
CreateThread(function()
    while true do
        local sleep = 1000
        if MedState.inLastStand then
            MedState.timer = MedState.timer - 1
            LaststandTime = MedState.timer -- Sync legacy global

            if MedState.timer <= 0 then
                MedState.inLastStand = false
                InLaststand = false
                TMGCore.Functions.Notify(Lang:t('error.bled_out'), 'error')
                SetLaststand(false)

                -- Forensic Death Sequence
                local player = PlayerId()
                local ped = PlayerPedId()
                local killer_2, killerWeapon = NetworkGetEntityKillerOfPlayer(player)
                local killer = GetPedSourceOfDeath(ped)
                if killer_2 ~= 0 and killer_2 ~= -1 then killer = killer_2 end
                
                local killerId = NetworkGetPlayerIndexFromPed(killer)
                local killerName = killerId ~= -1 and GetPlayerName(killerId) .. ' (' .. GetPlayerServerId(killerId) .. ')' or Lang:t('info.self_death')
                
                local weaponLabel = (TMGCore.Shared.Weapons[killerWeapon] and TMGCore.Shared.Weapons[killerWeapon].label) or 'Unknown'
                
                TriggerServerEvent('tmg-log:server:CreateLog', 'death', Lang:t('logs.death_log_title', { playername = GetPlayerName(player), playerid = GetPlayerServerId(player) }), 'red', Lang:t('logs.death_log_message', { killername = killerName, playername = GetPlayerName(player), weaponlabel = weaponLabel, weaponname = "Unknown" }))
                
                -- Matrix Reset
                MedState.deathTime = 0
                if OnDeath then OnDeath() end
                if DeathTimer then DeathTimer() end
            end
        end
        Wait(sleep)
    end
end)

-- [[ 4. EVENTS ]]

RegisterNetEvent('hospital:client:isEscorted', function(bool)
    MedState.isEscorted = bool -- Corrected Pointer to Matrix
end)

RegisterNetEvent('hospital:client:UseFirstAid', function()
    -- Native proximity check
    local player, distance = TMGCore.Functions.GetClosestPlayer() 
    if player ~= -1 and distance < 1.5 then
        TriggerServerEvent('hospital:server:UseFirstAid', GetPlayerServerId(player))
    end
end)

RegisterNetEvent('hospital:client:CanHelp', function(helperId)
    local canHelp = (MedState.inLastStand and MedState.timer <= 300)
    TriggerServerEvent('hospital:server:CanHelp', helperId, canHelp)
end)

RegisterNetEvent('hospital:client:HelpPerson', function(targetId)
    local ped = PlayerPedId()
    TMGCore.Functions.Progressbar('hospital_revive', Lang:t('progress.revive'), math.random(30000, 60000), false, true, {
        disableMovement = true, -- TMG Security Fix
        disableCarMovement = true,
        disableMouse = false,
        disableCombat = true,
    }, {
        animDict = 'mini@cpr@char_a@cpr_str', 
        anim = 'cpr_pumpchest',
        flags = 1,
    }, {}, {}, function() -- Success
        ClearPedTasks(ped)
        TMGCore.Functions.Notify(Lang:t('success.revived'), 'success')
        TriggerServerEvent('hospital:server:RevivePlayer', targetId)
    end, function() -- Cancel
        ClearPedTasks(ped)
        TMGCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)