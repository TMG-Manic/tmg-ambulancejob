local TMGCore = exports['tmg-core']:GetCoreObject()


-- [[ TMG MAINFRAME: EMS JOB MODULE ]]
local PlayerJob = {}
local onDuty = false
local currentGarage = 1 -- Initialized to 1 to prevent nil errors

-- [[ 1. UTILITIES & VEHICLE MANAGEMENT ]]

local function getAuthorizedVehicles(grade)
    local accessibleVehicles = {}
    for availableGrade, vehicles in pairs(Config.AuthorizedVehicles) do
        if grade >= availableGrade then
            for vehicleName, vehicleLabel in pairs(vehicles) do
                accessibleVehicles[vehicleName] = vehicleLabel
            end
        end
    end
    return accessibleVehicles
end

function TakeOutVehicle(vehicleInfo)
    local coords = Config.Locations['vehicle'][currentGarage]
    TMGCore.Functions.TriggerCallback('TMGCore:Server:SpawnVehicle', function(netId)
        local veh = NetToVeh(netId)
        SetVehicleNumberPlateText(veh, Lang:t('info.amb_plate') .. tostring(math.random(1000, 9999)))
        SetEntityHeading(veh, coords.w)
        exports['LegacyFuel']:SetFuel(veh, 100.0)
        TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
        if Config.VehicleSettings[vehicleInfo] ~= nil then
            TMGCore.Shared.SetDefaultVehicleExtras(veh, Config.VehicleSettings[vehicleInfo].extras)
        end
        TriggerEvent('vehiclekeys:client:SetOwner', TMGCore.Functions.GetPlate(veh))
        SetVehicleEngineOn(veh, true, true)
    end, vehicleInfo, coords, true)
end

function MenuGarage()
    local vehicleMenu = {
        { header = Lang:t('menu.amb_vehicles'), isMenuHeader = true }
    }
    local grade = (PlayerJob and PlayerJob.grade) and PlayerJob.grade.level or 0
    local authorizedVehicles = getAuthorizedVehicles(grade)
    
    for veh, label in pairs(authorizedVehicles) do
        vehicleMenu[#vehicleMenu + 1] = {
            header = label, txt = '',
            params = { event = 'ambulance:client:TakeOutVehicle', args = { vehicle = veh } }
        }
    end
    vehicleMenu[#vehicleMenu + 1] = {
        header = Lang:t('menu.close'), txt = '', params = { event = 'tmg-menu:client:closeMenu' }
    }
    exports['tmg-menu']:openMenu(vehicleMenu)
end

RegisterNetEvent('ambulance:client:TakeOutVehicle', function(data)
    TakeOutVehicle(data.vehicle)
end)

-- [[ 2. PLAYER & JOB STATE SYNC ]]

RegisterNetEvent('TMGCore:Client:OnJobUpdate', function(JobInfo)
    PlayerJob = JobInfo
    if PlayerJob.name == 'ambulance' then
        onDuty = PlayerJob.onduty
        if PlayerJob.onduty then
            TriggerServerEvent('hospital:server:AddDoctor', PlayerJob.name)
        else
            TriggerServerEvent('hospital:server:RemoveDoctor', PlayerJob.name)
        end
    end
end)

RegisterNetEvent('TMGCore:Client:SetDuty', function(duty)
    if PlayerJob.name == 'ambulance' and duty ~= onDuty then
        if duty then
            TriggerServerEvent('hospital:server:AddDoctor', PlayerJob.name)
        else
            TriggerServerEvent('hospital:server:RemoveDoctor', PlayerJob.name)
        end
    end
    onDuty = duty
end)

RegisterNetEvent('TMGCore:Client:OnPlayerLoaded', function()
    exports.spawnmanager:setAutoSpawn(false)
    local ped = PlayerPedId()
    local player = PlayerId()
    
    CreateThread(function()
        Wait(5000)
        SetEntityMaxHealth(ped, 200)
        SetEntityHealth(ped, 200)
        SetPlayerHealthRechargeMultiplier(player, 0.0)
        SetPlayerHealthRechargeLimit(player, 0.0)
    end)
    
    CreateThread(function()
        Wait(1000)
        TMGCore.Functions.GetPlayerData(function(PlayerData)
            PlayerJob = PlayerData.job
            onDuty = PlayerData.job.onduty
            SetPedArmour(PlayerPedId(), PlayerData.metadata['armor'])
            
            if (not PlayerData.metadata['inlaststand'] and PlayerData.metadata['isdead']) then
                MedState.deathTime = Config.ReviveInterval
                if OnDeath then OnDeath() end
                if DeathTimer then DeathTimer() end
            elseif (PlayerData.metadata['inlaststand'] and not PlayerData.metadata['isdead']) then
                if SetLaststand then SetLaststand(true) end
            else
                TriggerServerEvent('hospital:server:SetDeathStatus', false)
                TriggerServerEvent('hospital:server:SetLaststandStatus', false)
            end
            
            if PlayerJob.name == 'ambulance' and onDuty then
                TriggerServerEvent('hospital:server:AddDoctor', PlayerJob.name)
            end
        end)
    end)
end)

RegisterNetEvent('TMGCore:Client:OnPlayerUnload', function()
    if PlayerJob.name == 'ambulance' and onDuty then
        TriggerServerEvent('hospital:server:RemoveDoctor', PlayerJob.name)
    end
end)

-- [[ 3. MEDICAL PROCEDURES (REVIVE, TREAT, STATUS) ]]

function Status()
    if MedState.statusChecking then
        local statusMenu = { { header = Lang:t('menu.status'), isMenuHeader = true } }
        for _, v in pairs(MedState.statusChecks) do
            statusMenu[#statusMenu + 1] = {
                header = v.label, txt = '', params = { event = 'hospital:client:TreatWounds' }
            }
        end
        statusMenu[#statusMenu + 1] = { header = Lang:t('menu.close'), txt = '', params = { event = 'tmg-menu:client:closeMenu' } }
        exports['tmg-menu']:openMenu(statusMenu)
    end
end

RegisterNetEvent('hospital:client:CheckStatus', function()
    local player, distance = TMGCore.Functions.GetClosestPlayer() 
    if player ~= -1 and distance < 5.0 then
        local playerId = GetPlayerServerId(player)
        TMGCore.Functions.TriggerCallback('hospital:GetPlayerStatus', function(result)
            if result then
                MedState.statusChecks = {} -- Clear Matrix for fresh read
                for k, v in pairs(result) do
                    if k ~= 'BLEED' and k ~= 'WEAPONWOUNDS' then
                        MedState.statusChecks[#MedState.statusChecks + 1] = {
                            bone = Config.BoneIndexes[k],
                            label = v.label .. ' (' .. Config.WoundStates[v.severity] .. ')'
                        }
                    elseif k == 'WEAPONWOUNDS' then
                        for _, v2 in pairs(v) do
                            TriggerEvent('chat:addMessage', { color = { 255, 0, 0 }, multiline = false, args = { Lang:t('info.status'), TMGCore.Shared.Weapons[v2].damagereason } })
                        end
                    elseif k == 'BLEED' and v > 0 then
                        TriggerEvent('chat:addMessage', { color = { 255, 0, 0 }, multiline = false, args = { Lang:t('info.status'), Lang:t('info.is_status', { status = Config.BleedingStates[v].label }) } })
                    else
                        TMGCore.Functions.Notify(Lang:t('success.healthy_player'), 'success')
                    end
                end
                MedState.statusChecking = true
                Status()
            end
        end, playerId)
    else
        TMGCore.Functions.Notify(Lang:t('error.no_player'), 'error')
    end
end)

RegisterNetEvent('hospital:client:RevivePlayer', function()
    if TMGCore.Functions.HasItem('firstaid') then
        local player, distance = TMGCore.Functions.GetClosestPlayer()
        if player ~= -1 and distance < 5.0 then
            local playerId = GetPlayerServerId(player)
            local dict = MedicalAnims.healAction.dict 
            local anim = MedicalAnims.healAction.anim
            
            TMGCore.Functions.Progressbar('hospital_revive', Lang:t('progress.revive'), 5000, false, true, {
                disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true,
            }, { animDict = dict, anim = anim, flags = 33, }, {}, {}, function() -- Done
                StopAnimTask(PlayerPedId(), dict, 'exit', 1.0)
                TMGCore.Functions.Notify(Lang:t('success.revived'), 'success')
                TriggerServerEvent('hospital:server:RevivePlayer', playerId)
            end, function() -- Cancel
                StopAnimTask(PlayerPedId(), dict, 'exit', 1.0)
                TMGCore.Functions.Notify(Lang:t('error.canceled'), 'error')
            end)
        else
            TMGCore.Functions.Notify(Lang:t('error.no_player'), 'error')
        end
    else
        TMGCore.Functions.Notify(Lang:t('error.no_firstaid'), 'error')
    end
end)

RegisterNetEvent('hospital:client:TreatWounds', function()
    if TMGCore.Functions.HasItem('bandage') then
        local player, distance = TMGCore.Functions.GetClosestPlayer()
        if player ~= -1 and distance < 5.0 then
            local playerId = GetPlayerServerId(player)
            local dict = MedicalAnims.healAction.dict
            local anim = MedicalAnims.healAction.anim
            
            TMGCore.Functions.Progressbar('hospital_healwounds', Lang:t('progress.healing'), 5000, false, true, {
                disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true,
            }, { animDict = dict, anim = anim, flags = 33, }, {}, {}, function() -- Done
                StopAnimTask(PlayerPedId(), dict, 'exit', 1.0)
                TMGCore.Functions.Notify(Lang:t('success.helped_player'), 'success')
                TriggerServerEvent('hospital:server:TreatWounds', playerId)
            end, function() -- Cancel
                StopAnimTask(PlayerPedId(), dict, 'exit', 1.0)
                TMGCore.Functions.Notify(Lang:t('error.canceled'), 'error')
            end)
        else
            TMGCore.Functions.Notify(Lang:t('error.no_player'), 'error')
        end
    else
        TMGCore.Functions.Notify(Lang:t('error.no_bandage'), 'error')
    end
end)

-- [[ 4. ELEVATOR LOGIC ]]

RegisterNetEvent('tmg-ambulancejob:elevator_roof', function(index)
    local ped = PlayerPedId()
    local targetIndex = index or 1 
    
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(10) end
    
    local coords = Config.Locations['main'][targetIndex]
    if coords then
        SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
        SetEntityHeading(ped, coords.w)
    end
    
    Wait(100)
    DoScreenFadeIn(1000)
end)

RegisterNetEvent('tmg-ambulancejob:elevator_main', function(index)
    local ped = PlayerPedId()
    local targetIndex = index or 1 
    
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(10) end
    
    local coords = Config.Locations['roof'][targetIndex]
    if coords then
        SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
        SetEntityHeading(ped, coords.w)
    end
    
    Wait(100)
    DoScreenFadeIn(1000)
end)

RegisterNetEvent('EMSToggle:Duty', function()
    onDuty = not onDuty
    TriggerServerEvent('TMGCore:ToggleDuty')
    TriggerServerEvent('police:server:UpdateBlips')
end)

-- [[ 5. SINGLETON JOB LISTENER ]]

local isJobListening = false

function StopJobListener() isJobListening = false end

local function JobInteractionControls(mode, index)
    if isJobListening then return end 
    CreateThread(function()
        isJobListening = true
        while isJobListening do
            if IsControlJustReleased(0, 38) then
                exports['tmg-core']:KeyPressed(38)
                
                if mode == 'sign' then TriggerEvent('EMSToggle:Duty')
                elseif mode == 'stash' then TriggerServerEvent('tmg-ambulancejob:server:stash')
                elseif mode == 'roof' then TriggerEvent('tmg-ambulancejob:elevator_main', index)
                elseif mode == 'main' then TriggerEvent('tmg-ambulancejob:elevator_roof', index)
                elseif mode == 'vehicle' then
                    local ped = PlayerPedId()
                    if IsPedInAnyVehicle(ped, false) then
                        TMGCore.Functions.DeleteVehicle(GetVehiclePedIsIn(ped))
                    else
                        currentGarage = index
                        MenuGarage()
                    end
                elseif mode == 'heli' then
                    local ped = PlayerPedId()
                    if IsPedInAnyVehicle(ped, false) then
                        TMGCore.Functions.DeleteVehicle(GetVehiclePedIsIn(ped))
                    else
                        local coords = Config.Locations['helicopter'][index]
                        TMGCore.Functions.TriggerCallback('TMGCore:Server:SpawnVehicle', function(netId)
                            local veh = NetToVeh(netId)
                            SetVehicleNumberPlateText(veh, Lang:t('info.heli_plate') .. tostring(math.random(1000, 9999)))
                            SetEntityHeading(veh, coords.w)
                            SetVehicleLivery(veh, 1) 
                            exports['LegacyFuel']:SetFuel(veh, 100.0)
                            TaskWarpPedIntoVehicle(PlayerPedId(), veh, -1)
                            TriggerEvent('vehiclekeys:client:SetOwner', TMGCore.Functions.GetPlate(veh))
                            SetVehicleEngineOn(veh, true, true, false)
                        end, Config.Helicopter, coords, true)
                    end
                end
                isJobListening = false 
            end
            Wait(0)
        end
    end)
end

-- [[ 6. REGISTRATION MATRIX ]]

local function RegisterJobZones()
    if Config.UseTarget then
        for i = 1, #Config.Locations['duty'] do
            local v = Config.Locations['duty'][i]
            exports['tmg-target']:AddBoxZone('duty' .. i, vector3(v.x, v.y, v.z), 1.5, 1, {
                name = 'duty' .. i, heading = -20, minZ = v.z - 2, maxZ = v.z + 2,
            }, { options = { { type = 'client', event = 'EMSToggle:Duty', icon = 'fa fa-clipboard', label = 'Sign In/Off duty', job = 'ambulance' } }, distance = 1.5 })
        end
        -- Stash Target
        for i = 1, #Config.Locations['stash'] do
            local v = Config.Locations['stash'][i]
            exports['tmg-target']:AddBoxZone('stash' .. i, vector3(v.x, v.y, v.z), 1, 1, {
                name = 'stash' .. i, heading = -20, minZ = v.z - 2, maxZ = v.z + 2,
            }, { options = { { type = 'server', event = 'tmg-ambulancejob:server:stash', icon = 'fa fa-hand', label = 'Open Stash', job = 'ambulance' } }, distance = 1.5 })
        end
        -- Roof Elevator Target
        for i = 1, #Config.Locations['roof'] do
            local v = Config.Locations['roof'][i]
            exports['tmg-target']:AddBoxZone('roof' .. i, vector3(v.x, v.y, v.z), 2, 2, {
                name = 'roof' .. i, heading = -20, minZ = v.z - 2, maxZ = v.z + 2,
            }, { options = { { type = 'client', action = function() TriggerEvent('tmg-ambulancejob:elevator_main', i) end, icon = 'fas fa-hand-point-up', label = 'Take Elevator', job = 'ambulance' } }, distance = 8 })
        end
        -- Main Elevator Target
        for i = 1, #Config.Locations['main'] do
            local v = Config.Locations['main'][i]
            exports['tmg-target']:AddBoxZone('main' .. i, vector3(v.x, v.y, v.z), 1.5, 1.5, {
                name = 'main' .. i, heading = -20, minZ = v.z - 2, maxZ = v.z + 2,
            }, { options = { { type = 'client', action = function() TriggerEvent('tmg-ambulancejob:elevator_roof', i) end, icon = 'fas fa-hand-point-up', label = 'Take Elevator', job = 'ambulance' } }, distance = 8 })
        end
        -- Vehicle Target (TMG Added for Parity)
        if Config.Locations['vehicle'] then
            for i = 1, #Config.Locations['vehicle'] do
                local v = Config.Locations['vehicle'][i]
                exports['tmg-target']:AddBoxZone('amb_veh' .. i, vector3(v.x, v.y, v.z), 3.0, 3.0, {
                    name = 'amb_veh' .. i, heading = 70, minZ = v.z - 2, maxZ = v.z + 2,
                }, { options = { { type = 'client', action = function() currentGarage = i MenuGarage() end, icon = 'fas fa-car', label = 'Garage', job = 'ambulance' } }, distance = 3 })
            end
        end
    else
        -- PolyZone Initialization
        local signPoly, stashPoly, roofPoly, mainPoly, vehPoly, heliPoly = {}, {}, {}, {}, {}, {}        
        -- Build Arrays
        for i = 1, #Config.Locations['duty'] do local v = Config.Locations['duty'][i] signPoly[#signPoly + 1] = BoxZone:Create(vector3(v.x, v.y, v.z), 1.5, 1, { name = 'sign' .. i, heading = -20, minZ = v.z - 2, maxZ = v.z + 2 }) end
        for i = 1, #Config.Locations['stash'] do local v = Config.Locations['stash'][i] stashPoly[#stashPoly + 1] = BoxZone:Create(vector3(v.x, v.y, v.z), 1, 1, { name = 'stash' .. i, heading = -20, minZ = v.z - 2, maxZ = v.z + 2 }) end
        for i = 1, #Config.Locations['roof'] do local v = Config.Locations['roof'][i] roofPoly[#roofPoly + 1] = BoxZone:Create(vector3(v.x, v.y, v.z), 2, 2, { name = 'roof' .. i, heading = 70, minZ = v.z - 2, maxZ = v.z + 2, data = { id = i } }) end
        for i = 1, #Config.Locations['main'] do local v = Config.Locations['main'][i] mainPoly[#mainPoly + 1] = BoxZone:Create(vector3(v.x, v.y, v.z), 1.5, 1.5, { name = 'main' .. i, heading = 70, minZ = v.z - 2, maxZ = v.z + 2, data = { id = i } }) end
        for i = 1, #Config.Locations['vehicle'] do local v = Config.Locations['vehicle'][i] vehPoly[#vehPoly + 1] = BoxZone:Create(vector3(v.x, v.y, v.z), 5, 5, { name = 'vehicle' .. i, heading = 70, minZ = v.z - 2, maxZ = v.z + 2, data = { id = i } }) end
        for i = 1, #Config.Locations['helicopter'] do local v = Config.Locations['helicopter'][i] heliPoly[#heliPoly + 1] = BoxZone:Create(vector3(v.x, v.y, v.z), 5, 5, { name = 'helicopter' .. i, heading = 70, minZ = v.z - 2, maxZ = v.z + 2, data = { id = i } }) end

        -- Create Combos
        local signCombo = ComboZone:Create(signPoly, { name = 'signcombo', debugPoly = false })
        signCombo:onPlayerInOut(function(isPointInside)
            if isPointInside and PlayerJob.name == 'ambulance' then
                exports['tmg-core']:DrawText(onDuty and Lang:t('text.offduty_button') or Lang:t('text.onduty_button'), 'left')
                JobInteractionControls('sign')
            else StopJobListener() exports['tmg-core']:HideText() end
        end)

        local stashCombo = ComboZone:Create(stashPoly, { name = 'stashCombo', debugPoly = false })
        stashCombo:onPlayerInOut(function(isPointInside)
            if isPointInside and PlayerJob.name == 'ambulance' and onDuty then
                exports['tmg-core']:DrawText(Lang:t('text.pstash_button'), 'left')
                JobInteractionControls('stash')
            else StopJobListener() exports['tmg-core']:HideText() end
        end)

        local roofCombo = ComboZone:Create(roofPoly, { name = 'roofCombo', debugPoly = false })
        roofCombo:onPlayerInOut(function(isPointInside, _, zone)
            if isPointInside and PlayerJob.name == 'ambulance' then
                if onDuty then exports['tmg-core']:DrawText(Lang:t('text.elevator_main'), 'left') JobInteractionControls('roof', zone.data.id)
                else exports['tmg-core']:DrawText(Lang:t('error.not_ems'), 'left') end
            else StopJobListener() exports['tmg-core']:HideText() end
        end)

        local mainCombo = ComboZone:Create(mainPoly, { name = 'mainPoly', debugPoly = false })
        mainCombo:onPlayerInOut(function(isPointInside, _, zone)
            if isPointInside and PlayerJob.name == 'ambulance' then
                if onDuty then exports['tmg-core']:DrawText(Lang:t('text.elevator_roof'), 'left') JobInteractionControls('main', zone.data.id)
                else exports['tmg-core']:DrawText(Lang:t('error.not_ems'), 'left') end
            else StopJobListener() exports['tmg-core']:HideText() end
        end)

        local vehCombo = ComboZone:Create(vehPoly, { name = 'vehPoly', debugPoly = false })
        vehCombo:onPlayerInOut(function(isPointInside, _, zone)
            if isPointInside and PlayerJob.name == 'ambulance' and onDuty then
                exports['tmg-core']:DrawText(Lang:t('text.veh_button'), 'left')
                JobInteractionControls('vehicle', zone.data.id)
            else StopJobListener() exports['tmg-core']:HideText() end
        end)

        local heliCombo = ComboZone:Create(heliPoly, { name = 'heliPoly', debugPoly = false })
        heliCombo:onPlayerInOut(function(isPointInside, _, zone)
            if isPointInside and PlayerJob.name == 'ambulance' and onDuty then
                exports['tmg-core']:DrawText(Lang:t('text.heli_button'), 'left')
                JobInteractionControls('heli', zone.data.id)
            else StopJobListener() exports['tmg-core']:HideText() end
        end)
    end
end

CreateThread(RegisterJobZones)