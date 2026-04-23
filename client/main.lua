local TMGCore = exports['tmg-core']:GetCoreObject()

MedState = {
    isDead = false,
    inLastStand = false,
    isBleeding = 0,
    isInBed = false,
    canLeaveBed = true,
    doctorCount = 0,
    hospitalLocation = 1,
    onPainKillers = false,
    deathTime = 0,
    emsNotified = false,
    isEscorted = false,
    bleedTick = 0,
    advanceBleed = 0,
    fadeOut = 0,
    blackout = 0,
    
    bedOccupying = nil,
    bedData = nil,
    bedObject = nil,
    cam = nil,
    
    statusChecking = false,
    statusChecks = {},
    statusCheckTime = 0,
    damageList = {},
    injured = {}
}

local MedicalAnims = {
    bedExit = { dict = 'switch@franklin@bed', anim = 'sleep_getup_rubeyes' },
    bedIdle = { dict = 'anim@gangops@morgue@table@', anim = 'body_search' },
    healAction = { dict = 'mini@cpr@char_a@cpr_str', anim = 'cpr_pumpchest' }
}

local BodyParts = {
    ['HEAD']       = { label = Lang:t('body.head'), severity = 0, damaged = false },
    ['NECK']       = { label = Lang:t('body.neck'), severity = 0, damaged = false },
    ['SPINE']      = { label = Lang:t('body.spine'), severity = 0, damaged = false, limp = true },
    ['UPPER_BODY'] = { label = Lang:t('body.upper_body'), severity = 0, damaged = false },
    ['LOWER_BODY'] = { label = Lang:t('body.lower_body'), severity = 0, damaged = false, limp = true },
    ['LARM']       = { label = Lang:t('body.left_arm'), severity = 0, damaged = false },
    ['LHAND']      = { label = Lang:t('body.left_hand'), severity = 0, damaged = false },
    ['LFINGER']    = { label = Lang:t('body.left_fingers'), severity = 0, damaged = false },
    ['LLEG']       = { label = Lang:t('body.left_leg'), severity = 0, damaged = false, limp = true },
    ['LFOOT']      = { label = Lang:t('body.left_foot'), severity = 0, damaged = false, limp = true },
    ['RARM']       = { label = Lang:t('body.right_arm'), severity = 0, damaged = false },
    ['RHAND']      = { label = Lang:t('body.right_hand'), severity = 0, damaged = false },
    ['RFINGER']    = { label = Lang:t('body.right_fingers'), severity = 0, damaged = false },
    ['RLEG']       = { label = Lang:t('body.right_leg'), severity = 0, damaged = false, limp = true },
    ['RFOOT']      = { label = Lang:t('body.right_foot'), severity = 0, damaged = false, limp = true },
}

local PartCategories = {
    LLEG = 1, RLEG = 1, LFOOT = 1, RFOOT = 1,
    LARM = 2, RARM = 2, LHAND = 2, RHAND = 2, LFINGER = 2, RFINGER = 2,
    HEAD = 3
}
local limpCount, legCount, armcount, headCount = 0, 0, 0, 0
local isListening = false
local moveState = { isLimping = false, animSet = 'move_m@injured' }


CreateThread(function()
    while true do
        local sleep = 1000
        if MedState.isDead or MedState.isBleeding > 0 then
            sleep = 0 
            if MedState.isBleeding > 0 then
                if GetGameTimer() > MedState.bleedTick then
                    local ped = PlayerPedId()
                    SetEntityHealth(ped, GetEntityHealth(ped) - MedState.isBleeding)
                    MedState.bleedTick = GetGameTimer() + 5000 
                end
            end
        end
        Wait(sleep)
    end
end)

CreateThread(function()
    local limbTimer = 0 
    while true do
        local sleep = 1000 
        
        if MedState.isInBed then
            if MedState.canLeaveBed then
                sleep = 0
                exports['tmg-core']:DrawText(Lang:t('text.bed_out'))
                
                if IsControlJustReleased(0, 38) then -- [E]
                    exports['tmg-core']:KeyPressed(38)
                    LeaveBed()
                    exports['tmg-core']:HideText()
                end
            else
                sleep = 250 
            end
        end

        if MedState.statusChecking then
            sleep = math.min(sleep, 1000)
            MedState.statusCheckTime = MedState.statusCheckTime - 1
            if MedState.statusCheckTime <= 0 then
                MedState.statusChecks = {}
                MedState.statusChecking = false
            end
        end

        limbTimer = limbTimer + sleep
        if limbTimer >= (1000 * Config.MessageTimer) then
            DoLimbAlert()
            limbTimer = 0
        end

        Wait(sleep)
    end
end)

CreateThread(function()
    local pHealth, pArmor = nil, nil
    while true do
        local ped = PlayerPedId()
        local health, armor = GetEntityHealth(ped), GetPedArmour(ped)
        pHealth = pHealth or health
        pArmor = pArmor or armor

        local healthChanged = (pHealth ~= health)
        local armorChanged = (pArmor ~= armor and armor < (pArmor - Config.ArmorDamage) and armor > 0)

        if healthChanged or armorChanged then
            local damageDone = pHealth - health
            local hit, bone = GetPedLastDamageBone(ped)
            local weapon = GetDamagingWeapon(ped)
            local bodypart = Config.Bones[bone] or 'NONE'

            if hit and bodypart ~= 'NONE' and weapon then
                local isWeakShot = (bodypart == 'SPINE' or bodypart == 'UPPER_BODY') and armorChanged
                local isNothingWeapon = (weapon == Config.WeaponClasses['NOTHING'])
                local shouldSkip = isWeakShot or isNothingWeapon

                if damageDone >= Config.HealthDamage then
                    if not shouldSkip then
                        if IsDamagingEvent(damageDone, weapon) then
                            CheckDamage(ped, bone, weapon, damageDone)
                        end
                    elseif armorChanged then
                        TriggerServerEvent('hospital:server:SetArmor', armor)
                    end
                elseif Config.AlwaysBleedChanceWeapons[weapon] and not shouldSkip then
                    if math.random(100) < Config.AlwaysBleedChance then
                        ApplyBleed(1)
                    end
                end
            end
            CheckWeaponDamage(ped)
        end

        pHealth, pArmor = health, armor
        if not MedState.isInBed then ProcessDamage(ped) end
        Wait(100)
    end
end)

CreateThread(function()
    local stations = Config.Locations['stations']
    for i = 1, #stations do
        local station = stations[i]
        local blip = AddBlipForCoord(station.coords.x, station.coords.y, station.coords.z)
        SetBlipSprite(blip, 61)
        SetBlipAsShortRange(blip, true)
        SetBlipScale(blip, 0.8)
        SetBlipColour(blip, 25)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(station.label)
        EndTextCommandSetBlipName(blip)
    end
end)


function getClosestAvailableBed(hospitalIndex)
    local hospital = Config.Locations['hospital'][hospitalIndex]
    if not hospital or not hospital.beds then return 1 end

    for i = 1, #hospital.beds do
        if not hospital.beds[i].taken then
            return i
        end
    end
    return 1 
end

local WeaponHashes = {}
CreateThread(function()
    for weaponHash, data in pairs(Config.Weapons) do
        WeaponHashes[#WeaponHashes + 1] = { hash = weaponHash, data = data }
    end
end)

local CachedWeaponHashes = {}
CreateThread(function()
    for k, v in pairs(TMGCore.Shared.Weapons) do
        CachedWeaponHashes[#CachedWeaponHashes + 1] = { hash = GetHashKey(k), name = k, reason = v.damagereason }
    end
end)

function GetDamagingWeapon(ped)
    for i = 1, #WeaponHashes do
        local weapon = WeaponHashes[i]
        if HasPedBeenDamagedByWeapon(ped, weapon.hash, 0) then
            return weapon.data
        end
    end
    return nil
end

function IsDamagingEvent(damageDone, weapon)
    if damageDone < 5 then return false end
    if Config.ForceInjuryWeapons[weapon] then return true end
    local multi = damageDone / Config.HealthDamage
    local luck = math.random(100)
    if damageDone >= Config.ForceInjury or multi > Config.MaxInjuryChanceMulti then
        return true
    end
    return luck < (Config.HealthDamage * multi)
end

function DoLimbAlert()
    if MedState.isDead or MedState.inLastStand then return end 

    local injuredCount = #MedState.injured 
    if injuredCount == 0 then return end

    local limbDamageMsg = ""
    if injuredCount <= Config.AlertShowInfo then 
        local reportBuffer = {}
        for i = 1, injuredCount do
            local data = MedState.injured[i] 
            reportBuffer[#reportBuffer + 1] = Lang:t('info.pain_message', { 
                limb = data.label, 
                severity = Config.WoundStates[data.severity] 
            })
        end
        limbDamageMsg = table.concat(reportBuffer, " | ")
    else
        limbDamageMsg = Lang:t('info.many_places') 
    end

    TMGCore.Functions.Notify(limbDamageMsg, 'primary') 
end

function DoBleedAlert()
    if MedState.isDead or MedState.isBleeding <= 0 then return end
    local bleedData = Config.BleedingStates[MedState.isBleeding]
    if bleedData then
        TMGCore.Functions.Notify(Lang:t('info.bleed_alert', { bleedstate = bleedData.label }), 'error')
    end
end

function ApplyBleed(level)
    local newBleed = math.min(4, MedState.isBleeding + (tonumber(level) or 0))
    if newBleed ~= MedState.isBleeding then
        MedState.isBleeding = newBleed
        DoBleedAlert()
        TriggerServerEvent('hospital:server:SyncInjuries', {
            limbs = BodyParts,
            isBleeding = MedState.isBleeding 
        })
    end
end

function IsInjuryCausingLimp()
    return limpCount > 0
end

function ProcessRunStuff(ped)
    local needsLimp = IsInjuryCausingLimp()

    if needsLimp and not moveState.isLimping then
        moveState.isLimping = true
        CreateThread(function()
            if not HasAnimSetLoaded(moveState.animSet) then
                RequestAnimSet(moveState.animSet)
                while not HasAnimSetLoaded(moveState.animSet) do Wait(5) end 
            end
            SetPedMovementClipset(ped, moveState.animSet, 1.0)
            SetPlayerSprint(PlayerId(), false)
        end)
    elseif not needsLimp and moveState.isLimping then
        moveState.isLimping = false
        ResetPedMovementClipset(ped, 0.0)
        SetPlayerSprint(PlayerId(), true)
    end
end

function ResetPartial()
    for _, v in pairs(BodyParts) do
        if v.isDamaged and v.severity <= 2 then
            v.isDamaged = false
            v.severity = 0
            if v.limp and limpCount > 0 then limpCount = limpCount - 1 end
        end
    end

    for i = #MedState.injured, 1, -1 do
        if MedState.injured[i].severity <= 2 then
            table.remove(MedState.injured, i)
        end
    end

    if MedState.isBleeding <= 2 then
        MedState.isBleeding = 0
        MedState.bleedTick = 0
        MedState.advanceBleed = 0
        MedState.fadeOut = 0
        MedState.blackout = 0
    end

    TriggerServerEvent('hospital:server:SyncInjuries', {
        limbs = BodyParts,
        isBleeding = MedState.isBleeding 
    })

    local ped = PlayerPedId()
    ProcessRunStuff(ped)
    DoLimbAlert()
    DoBleedAlert()
end

function ResetAll()
    MedState.isBleeding = 0
    MedState.bleedTick = 0
    MedState.advanceBleed = 0
    MedState.fadeOut = 0
    MedState.blackout = 0
    MedState.onPainKillers = false
    
    MedState.injured = {}
    MedState.damageList = {}
    
    limpCount, legCount, armcount, headCount = 0, 0, 0, 0 

    for _, v in pairs(BodyParts) do
        v.isDamaged = false
        v.severity = 0
    end

    local ped = PlayerPedId()
    ClearPedBloodDamage(ped) 
    ResetPedMovementClipset(ped, 0.0) 

    TriggerServerEvent('hospital:server:SyncInjuries', { limbs = BodyParts, isBleeding = 0 })
    TriggerServerEvent('hospital:server:SetWeaponDamage', MedState.damageList)
    TriggerServerEvent('hospital:server:resetHungerThirst')

    ProcessRunStuff(ped)
    DoLimbAlert()
    DoBleedAlert()
end


function IsInDamageList(damage)
    if not MedState.damageList then return false end
    if MedState.damageList[damage] then return true end
    for i = 1, #MedState.damageList do
        if MedState.damageList[i] == damage then return true end
    end
    return false
end

function CheckWeaponDamage(ped)
    local hitDetected = false
    local newListEntry = false

    for i = 1, #CachedWeaponHashes do
        local weapon = CachedWeaponHashes[i]
        if HasPedBeenDamagedByWeapon(ped, weapon.hash, 0) then
            hitDetected = true
            if not IsInDamageList(weapon.name) then
                newListEntry = true
                TMGCore.Functions.Notify(Lang:t('info.status') .. ": " .. (weapon.reason or "Unknown Trauma"), 'error')
                MedState.damageList[#MedState.damageList + 1] = weapon.name
            end
        end
    end

    if hitDetected and newListEntry then
        TriggerServerEvent('hospital:server:SetWeaponDamage', MedState.damageList)
    end
    ClearEntityLastDamageEntity(ped)
end

function ApplyImmediateEffects(ped, bone, weapon, damageDone)
    local armor = GetPedArmour(ped)
    local boneArea = Config.Bones[bone]
    local isCritical = Config.CriticalAreas[boneArea]
    local staggerData = Config.StaggerAreas[boneArea]
    
    local isMinor = Config.MinorInjurWeapons[weapon] and damageDone < Config.DamageMinorToMajor
    local isMajor = Config.MajorInjurWeapons[weapon] or (Config.MinorInjurWeapons[weapon] and damageDone >= Config.DamageMinorToMajor)

    if isMinor then
        if isCritical and armor <= 0 then ApplyBleed(1) end
    elseif isMajor then
        local bleedChance = Config.MajorArmoredBleedChance
        local roll = math.random(100)

        if isCritical then
            if armor <= 0 or (isCritical.armored and roll <= bleedChance) then ApplyBleed(1) end
        else
            local threshold = (armor > 0) and bleedChance or (bleedChance * 2)
            if roll < threshold then ApplyBleed(1) end
        end
    end

    if staggerData and (staggerData.armored or armor <= 0) then
        local staggerChance = isMinor and staggerData.minor or staggerData.major
        if math.random(100) <= math.ceil(staggerChance) then
            SetPedToRagdoll(ped, 1500, 2000, 3, true, true, false) 
        end
    end
end

function ApplyBoneTrauma(boneId)
    local boneKey = Config.Bones[boneId]
    local part = BodyParts[boneKey]

    if not part or part.isDamaged then return end

    local severity = math.random(1, 4)
    part.isDamaged = true
    part.severity = severity

    MedState.injured[#MedState.injured + 1] = {
        part = boneKey,
        label = part.label,
        severity = severity
    }

    if part.limp then limpCount = limpCount + 1 end
end

function CheckDamage(ped, bone, weapon, damageDone)
    if not weapon or MedState.isDead or MedState.inLastStand then return end

    local boneArea = Config.Bones[bone]
    if not boneArea then return end

    ApplyImmediateEffects(ped, bone, weapon, damageDone)

    local partData = BodyParts[boneArea]
    if not partData.isDamaged then
        partData.isDamaged = true
        partData.severity = math.random(1, 3)
        
        MedState.injured[#MedState.injured + 1] = { part = boneArea, label = partData.label, severity = partData.severity }
        if partData.limp then limpCount = limpCount + 1 end
    else
        if partData.severity < 4 then
            partData.severity = partData.severity + 1
            for i = 1, #MedState.injured do
                if MedState.injured[i].part == boneArea then
                    MedState.injured[i].severity = partData.severity
                    break 
                end
            end
        end
    end

    TriggerServerEvent('hospital:server:SyncInjuries', { limbs = BodyParts, isBleeding = MedState.isBleeding })
    ProcessRunStuff(ped)
end

function ProcessDamage(ped)
    if MedState.isDead or MedState.inLastStand or MedState.onPainKillers then return end

    for i = 1, #MedState.injured do
        local v = MedState.injured[i]
        local category = PartCategories[v.part]
        local severity = v.severity

        if category == 1 and severity > (v.part:find("FOOT") and 2 or 1) then
            if legCount >= Config.LegInjuryTimer then
                if not IsPedRagdoll(ped) and IsPedOnFoot(ped) then
                    local chance = math.random(100)
                    local threshold = (IsPedRunning(ped) or IsPedSprinting(ped)) 
                                      and Config.LegInjuryChance.Running 
                                      or Config.LegInjuryChance.Walking
                    
                    if chance <= threshold then
                        ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', 0.08)
                        SetPedToRagdollWithFall(ped, 1500, 2000, 1, GetEntityForwardVector(ped), 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
                    end
                end
                legCount = 0
            else
                legCount = legCount + 1
            end

        elseif category == 2 and severity > (v.part:find("ARM") and 1 or 2) then
            if armcount >= Config.ArmInjuryTimer then
                if IsPedInAnyVehicle(ped, true) then
                    DisableControlAction(0, 63, true) 
                end
                if IsPlayerFreeAiming(PlayerId()) then
                    local action = (v.part:sub(1,1) == 'L') and 142 or 25
                    DisableControlAction(0, action, true)
                end
                armcount = 0
            else
                armcount = armcount + 1
            end

        elseif category == 3 and severity > 2 then
            if headCount >= Config.HeadInjuryTimer then
                if math.random(100) <= Config.HeadInjuryChance then
                    SetFlash(0, 0, 100, 10000, 100)
                    DoScreenFadeOut(100)
                    if not IsPedRagdoll(ped) and IsPedOnFoot(ped) and not IsPedSwimming(ped) then
                        ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', 0.08)
                        SetPedToRagdoll(ped, 5000, 1, 2)
                    end
                    SetTimeout(5000, function() DoScreenFadeIn(250) end)
                end
                headCount = 0
            else
                headCount = headCount + 1
            end
        end
    end
end


function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return end
    local timeout = 0
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(5) 
        timeout = timeout + 1
        if timeout > 1000 then 
            print("^1[TMG Error]^7 Failed to load animation dictionary: " .. tostring(dict))
            return false 
        end
    end
    return true
end

function SetBedCam()
    MedState.isInBed = true
    MedState.canLeaveBed = false
    local ped = PlayerPedId()

    DoScreenFadeOut(1000)
    while not IsScreenFadedOut() do Wait(10) end 

    if IsPedDeadOrDying(ped) then
        local pos = GetEntityCoords(ped, true)
        NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z, GetEntityHeading(ped), true, false)
    end

    MedState.bedObject = GetClosestObjectOfType(MedState.bedData.coords.x, MedState.bedData.coords.y, MedState.bedData.coords.z, 1.0, MedState.bedData.model, false, false, false)
    if DoesEntityExist(MedState.bedObject) then
        FreezeEntityPosition(MedState.bedObject, true)
    end

    SetEntityCoords(ped, MedState.bedData.coords.x, MedState.bedData.coords.y, MedState.bedData.coords.z + 0.02)
    SetEntityHeading(ped, MedState.bedData.coords.w)
    FreezeEntityPosition(ped, true)

    local dict = MedicalAnims.bedIdle.dict
    local anim = MedicalAnims.bedIdle.anim

    loadAnimDict(dict)
    TaskPlayAnim(ped, dict, anim, 8.0, 1.0, -1, 1, 0, false, false, false)

    MedState.cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', 1)
    SetCamActive(MedState.cam, true)
    RenderScriptCams(true, false, 1, true, true)
    
    AttachCamToPedBone(MedState.cam, ped, 31085, 0, 1.0, 1.0, true)
    SetCamFov(MedState.cam, 90.0)
    
    local camHeading = (GetEntityHeading(ped) + 180.0) % 360.0
    SetCamRot(MedState.cam, -45.0, 0.0, camHeading, 2)

    DoScreenFadeIn(1000)
end

function LeaveBed()
    local ped = PlayerPedId()
    local dict = MedicalAnims.bedExit.dict
    local anim = MedicalAnims.bedExit.anim

    if not HasAnimDictLoaded(dict) then
        RequestAnimDict(dict)
        while not HasAnimDictLoaded(dict) do Wait(0) end
    end

    FreezeEntityPosition(ped, false)
    SetEntityInvincible(ped, false)
    SetEntityHeading(ped, MedState.bedData.coords.w + 90)
    
    TriggerServerEvent('hospital:server:LeaveBed', MedState.bedOccupying, MedState.hospitalLocation)
    
    RenderScriptCams(0, true, 500, true, true) 
    if MedState.cam then
        DestroyCam(MedState.cam, false)
        MedState.cam = nil
    end

    TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 48, 0, false, false, false)
    
    MedState.isInBed = false
    MedState.bedOccupying = nil
    MedState.bedObject = nil
    MedState.bedData = nil

    local PlayerData = TMGCore.Functions.GetPlayerData() 
    if PlayerData.metadata['injail'] > 0 then
        TriggerEvent('prison:client:Enter', PlayerData.metadata['injail'])
    end

    SetTimeout(4000, function() ClearPedTasks(ped) end)
end


function StopInteractionListener()
    isListening = false
end

function CheckInControls(mode, hospitalIndex, bedId)
    if isListening then return end 

    CreateThread(function()
        isListening = true
        while isListening do
            if IsControlJustReleased(0, 38) then -- [E]
                exports['tmg-core']:KeyPressed(38)
                
                if mode == 'checkin' then
                    TriggerEvent('tmg-ambulancejob:checkin', hospitalIndex)
                elseif mode == 'beds' then
                    TriggerEvent('tmg-ambulancejob:beds', hospitalIndex, bedId)
                end
                
                isListening = false 
            end
            Wait(0) 
        end
    end)
end

local function RegisterMedicalInteractions()
    if Config.UseTarget then
        for i = 1, #Config.Locations['checking'] do
            local v = Config.Locations['checking'][i]
            exports['tmg-target']:AddBoxZone('checking' .. i, vector3(v.x, v.y, v.z), 3.5, 2, {
                name = 'checking' .. i, heading = -72, debugPoly = false, minZ = v.z - 2, maxZ = v.z + 2,
            }, {
                options = {
                    { type = 'client', icon = 'fa fa-clipboard', action = function() TriggerEvent('tmg-ambulancejob:checkin', i) end, label = 'Check In' }
                },
                distance = 1.5
            })
        end

        for hKey, hospital in ipairs(Config.Locations['hospital']) do
            for bKey, bed in ipairs(hospital['beds']) do
                exports['tmg-target']:AddBoxZone('beds_' .. hKey .. '_' .. bKey, bed.coords, 2.5, 2.3, {
                    name = 'beds_' .. hKey .. '_' .. bKey, heading = -20, debugPoly = false, minZ = bed.coords.z - 1, maxZ = bed.coords.z + 1,
                }, {
                    options = {
                        { type = 'client', action = function() TriggerEvent('tmg-ambulancejob:beds', hKey, bKey) end, icon = 'fas fa-bed', label = 'Lay in Bed' }
                    },
                    distance = 1.5
                })
            end
        end
    else
        local checkingPoly = {}
        for i = 1, #Config.Locations['checking'] do
            local v = Config.Locations['checking'][i]
            checkingPoly[#checkingPoly + 1] = BoxZone:Create(vector3(v.x, v.y, v.z), 3.5, 2, {
                heading = -72, name = 'checkin' .. i, debugPoly = false, minZ = v.z - 2, maxZ = v.z + 2, data = { id = i }
            })
        end

        local checkingCombo = ComboZone:Create(checkingPoly, { name = 'checkingCombo', debugPoly = false })
        checkingCombo:onPlayerInOut(function(isPointInside, _, zone)
            if isPointInside then
                local label = (MedState.doctorCount >= Config.MinimalDoctors) and Lang:t('text.call_doc') or Lang:t('text.check_in')
                exports['tmg-core']:DrawText(label, 'left')
                CheckInControls('checkin', zone.data.id)
            else
                StopInteractionListener()
                exports['tmg-core']:HideText()
            end
        end)

        local bedPoly = {}
        for hKey, hospital in ipairs(Config.Locations['hospital']) do
            for bKey, bed in ipairs(hospital['beds']) do
                bedPoly[#bedPoly + 1] = BoxZone:Create(bed.coords, 2.5, 2.3, {
                    name = 'beds_' .. hKey .. '_' .. bKey, heading = -20, debugPoly = false, minZ = bed.coords.z - 1, maxZ = bed.coords.z + 1, data = { bedId = bKey, hIndex = hKey },
                })
            end
        end

        local bedCombo = ComboZone:Create(bedPoly, { name = 'bedCombo', debugPoly = false })
        bedCombo:onPlayerInOut(function(isPointInside, _, zone)
            if isPointInside and not MedState.isInBed then
                exports['tmg-core']:DrawText(Lang:t('text.lie_bed'), 'left')
                CheckInControls('beds', zone.data.hIndex, zone.data.bedId)
            else
                StopInteractionListener()
                exports['tmg-core']:HideText()
            end
        end)
    end
end

CreateThread(RegisterMedicalInteractions)


RegisterNetEvent('hospital:client:ambulanceAlert', function(coords, text)
    local street1, street2 = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local locationText = GetStreetNameFromHashKey(street1)
    if street2 ~= 0 then locationText = locationText .. ' | ' .. GetStreetNameFromHashKey(street2) end

    TMGCore.Functions.Notify({ text = text, caption = locationText }, 'ambulance')
    PlaySoundFrontend(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', true)

    local blip = AddBlipForCoord(coords.x, coords.y, coords.z)
    local radiusBlip = AddBlipForRadius(coords.x, coords.y, coords.z, 100.0) 
    local blipText = Lang:t('info.ems_alert', { text = text })

    SetBlipSprite(blip, 153)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 0.8)
    SetBlipAsShortRange(blip, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(blipText)
    EndTextCommandSetBlipName(blip)
    SetBlipColour(radiusBlip, 1)
    SetBlipAlpha(radiusBlip, 128)
    
    CreateThread(function()
        local alpha = 250
        while alpha > 0 do
            Wait(1000) 
            alpha = alpha - 2 
            SetBlipAlpha(blip, alpha)
            SetBlipAlpha(radiusBlip, math.min(alpha, 128))
            if alpha <= 0 then break end
        end
        if DoesBlipExist(blip) then RemoveBlip(blip) end
        if DoesBlipExist(radiusBlip) then RemoveBlip(radiusBlip) end
    end)
end)

RegisterNetEvent('hospital:client:Revive', function()
    local ped = PlayerPedId()
    local lp = PlayerId()

    if MedState.isDead or MedState.inLastStand then
        local pos = GetEntityCoords(ped, true)
        NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z, GetEntityHeading(ped), true, false)
        MedState.isDead = false
        MedState.inLastStand = false
        SetLaststand(false)
    end

    ResetAll() 
    ClearPedBloodDamage(ped)
    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, 200)
    SetEntityInvincible(ped, false)
    SetPlayerSprint(lp, true)
    ResetPedMovementClipset(ped, 0.0)

    if MedState.isInBed then
        local dict = MedicalAnims.bedIdle.dict
        local anim = MedicalAnims.bedIdle.anim
        if not IsEntityPlayingAnim(ped, dict, anim, 3) then
            loadAnimDict(dict)
            TaskPlayAnim(ped, dict, anim, 8.0, 1.0, -1, 1, 0, false, false, false)
        end
        SetEntityInvincible(ped, true)
        MedState.canLeaveBed = true
    end

    TriggerServerEvent('hospital:server:RestoreWeaponDamage')
    TriggerServerEvent('hud:server:RelieveStress', 100)
    TriggerServerEvent('hospital:server:SetDeathStatus', false)
    TriggerServerEvent('hospital:server:SetLaststandStatus', false)

    TMGCore.Functions.Notify(Lang:t('info.healthy'), 'success')
end)

RegisterNetEvent('hospital:client:SetPain', function()
    ApplyBleed(math.random(1, 4))
    ApplyBoneTrauma(24816)
    ApplyBoneTrauma(40269)
    TriggerServerEvent('hospital:server:SyncInjuries', { limbs = BodyParts, isBleeding = MedState.isBleeding })
end)

RegisterNetEvent('hospital:client:KillPlayer', function()
    SetEntityHealth(PlayerPedId(), 0)
end)

RegisterNetEvent('hospital:client:HealInjuries', function(healType)
    if healType == 'full' then
        ResetAll()
    else
        ResetPartial()
    end
    SetTimeout(100, function() TriggerServerEvent('hospital:server:RestoreWeaponDamage') end)
    TMGCore.Functions.Notify(Lang:t('success.wounds_healed'), 'success')
end)

RegisterNetEvent('hospital:client:SendToBed', function(id, data, isRevive)
    MedState.bedOccupying = id
    MedState.bedData = data
    SetBedCam()

    if isRevive then
        TMGCore.Functions.Notify(Lang:t('success.being_helped'), 'success')
        MedState.isInBed = true
        MedState.canLeaveBed = false 

        CreateThread(function()
            Wait(Config.AIHealTimer * 1000)
            TriggerEvent('hospital:client:Revive')
            MedState.canLeaveBed = true
        end)
    else
        MedState.isInBed = true
        MedState.canLeaveBed = true
    end
end)

RegisterNetEvent('hospital:client:SetBed', function(id, isTaken, hospitalIndex)
    if not Config.Locations['hospital'][hospitalIndex] or not Config.Locations['hospital'][hospitalIndex]['beds'][id] then return end
    Config.Locations['hospital'][hospitalIndex]['beds'][id].taken = isTaken
    if isTaken and MedState.bedOccupying == id then
        MedState.hospitalLocation = hospitalIndex
    end
end)

RegisterNetEvent('hospital:client:SetBed2', function(id, isTaken)
    if not Config.Locations['jailbeds'] or not Config.Locations['jailbeds'][id] then return end
    Config.Locations['jailbeds'][id].taken = isTaken
end)

RegisterNetEvent('hospital:client:RespawnAtHospital', function()
    local hospitalIndex = 1 
    local hospitals = Config.Locations["hospital"]

    if Config.RespawnAtNearestHospital and #hospitals > 0 then
        local ped = PlayerPedId()
        local coords = GetEntityCoords(ped)
        local closestDist = #(hospitals[1]["location"] - coords)
        
        for i = 2, #hospitals do
            local dist = #(hospitals[i]["location"] - coords)
            if dist < closestDist then
                closestDist = dist
                hospitalIndex = i
            end
        end
    end

    TriggerServerEvent('hospital:server:RespawnAtHospital', hospitalIndex)
    if exports['tmg-policejob']:IsHandcuffed() then TriggerEvent('police:client:GetCuffed', -1) end
    TriggerEvent('police:client:DeEscort')
    exports['tmg-core']:HideText()
end)

RegisterNetEvent('hospital:client:SendBillEmail', function(amount, hospitalName)
    SetTimeout(math.random(2500, 4000), function()
        local PlayerData = TMGCore.Functions.GetPlayerData()
        if not PlayerData or not PlayerData.charinfo then return end
        
        local charinfo = PlayerData.charinfo
        local genderLabel = (charinfo.gender == 1) and Lang:t('info.mrs') or Lang:t('info.mr')

        TriggerServerEvent('tmg-phone:server:sendNewMail', {
            sender = hospitalName, subject = Lang:t('mail.subject'),
            message = Lang:t('mail.message', { gender = genderLabel, lastname = charinfo.lastname, costs = amount }),
            button = {}
        })
    end)
end)

RegisterNetEvent('hospital:client:SetDoctorCount', function(amount)
    local newCount = tonumber(amount) or 0
    if newCount ~= MedState.doctorCount then
        MedState.doctorCount = newCount
        if not MedState.isInBed then TriggerEvent('hospital:client:RefreshCheckInState') end
    end
end)

RegisterNetEvent('hospital:client:adminHeal', function()
    local ped = PlayerPedId()
    ResetAll() 
    SetEntityHealth(ped, 200)
    ClearPedBloodDamage(ped)
    SetPlayerSprint(PlayerId(), true)
    TriggerServerEvent('hospital:server:resetHungerThirst')
    TMGCore.Functions.Notify(Lang:t('info.admin_healed'), 'success')
end)

RegisterNetEvent('TMGCore:Client:OnPlayerUnload', function()
    local ped = PlayerPedId()
    if MedState.bedOccupying then
        TriggerServerEvent('hospital:server:LeaveBed', MedState.bedOccupying, MedState.hospitalLocation)
        if MedState.cam then
            RenderScriptCams(false, false, 0, true, true)
            DestroyCam(MedState.cam, false)
            MedState.cam = nil
        end
        MedState.bedOccupying = nil
    end

    TriggerServerEvent('hospital:server:FinalStateSync', { death = false, laststand = false, armor = GetPedArmour(ped) })

    MedState.isDead = false
    SetEntityInvincible(ped, false)
    SetPedArmour(ped, 0)
    ResetAll()
end)

RegisterNetEvent('tmg-ambulancejob:checkin', function(providedIndex)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local hIndex = providedIndex
    
    if not hIndex then
        for i = 1, #Config.Locations['hospital'] do
            if #(coords - Config.Locations['hospital'][i]['location']) < 3 then
                hIndex = i break
            end
        end
    end

    if not hIndex then return end
    local hospital = Config.Locations['hospital'][hIndex]

    if MedState.doctorCount >= Config.MinimalDoctors then
        TriggerServerEvent('hospital:server:SendDoctorAlert', hospital['name'])
        TMGCore.Functions.Notify('Called a Doctor', 'primary')
    else
        TMGCore.Functions.Progressbar('hospital_checkin', Lang:t('progress.checking_in'), 2000, false, true, {
            disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true,
        }, { animDict = 'missheistdockssetup1clipboard@base', anim = 'base', flags = 33,
        }, { model = 'prop_notepad_01', bone = 18905, coords = { x = 0.1, y = 0.02, z = 0.05 }, rotation = { x = 10.0, y = 0.0, z = 0.0 },
        }, { model = 'prop_pencil_01', bone = 58866, coords = { x = 0.11, y = -0.02, z = 0.001 }, rotation = { x = -120.0, y = 0.0, z = 0.0 },
        }, function() 
            TriggerEvent('animations:client:EmoteCommandStart', { 'c' })
            local bedId = getClosestAvailableBed(hIndex)
            if bedId then
                MedState.hospitalLocation = hIndex
                TriggerServerEvent('hospital:server:SendToBed', bedId, true, hIndex)
            else
                TMGCore.Functions.Notify(Lang:t('error.beds_taken'), 'error')
            end
        end)
    end
end)

RegisterNetEvent('tmg-ambulancejob:beds', function(hospitalIndex, bedId)
    if not hospitalIndex or not bedId then return TMGCore.Functions.Notify(Lang:t('error.beds_taken'), 'error') end
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local targetBed = Config.Locations['hospital'][hospitalIndex]['beds'][bedId]
    
    if targetBed and #(coords - targetBed.coords) < 3.0 then
        TriggerServerEvent('hospital:server:SendToBed', bedId, false, hospitalIndex)
        MedState.hospitalLocation = hospitalIndex
    else
        TMGCore.Functions.Notify(Lang:t('error.too_far'), 'error')
    end
end)