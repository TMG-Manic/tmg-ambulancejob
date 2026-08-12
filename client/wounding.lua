local TMGCore = exports['tmg-core']:GetCoreObject()
local prevPos = vector3(0, 0, 0)

-- Reduces the bleed level by `level` (floored at 0), refreshes the bleed
-- alert, and syncs the new bleed/injury state to the server.
function RemoveBleed(level)
    -- TMG Nil-Guard: Ensure MedState exists before indexing
    if not MedState or not MedState.isBleeding then return end
    if MedState.isBleeding > 0 then
        MedState.isBleeding = math.max(0, MedState.isBleeding - level)
        if DoBleedAlert then DoBleedAlert() end
        TriggerServerEvent('hospital:server:SyncInjuries', { limbs = BodyParts, isBleeding = MedState.isBleeding })
    end
end

-- Export used by other resources (e.g. items) to put the player onto the
-- painkiller effect, optionally setting a specific dose count.
exports('PainKillerLoop', function(pkAmount)
    if not MedState then return end
    if pkAmount then MedState.painkillerAmount = pkAmount end
    MedState.onPainKillers = true
end)


-- Uses an IFAK item: plays a pill animation/progressbar, then consumes the
-- item, relieves stress, heals a small amount of health, stacks a
-- painkiller dose, and has a 50% chance to reduce bleeding by 1.
RegisterNetEvent('hospital:client:UseIfaks', function()
    local ped = PlayerPedId()
    TMGCore.Functions.Progressbar('use_ifak', Lang:t('progress.ifaks'), 3000, false, true, {
        disableMovement = true, -- TMG Security: Prevents running while healing
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true,
    }, { animDict = 'mp_suicide', anim = 'pill', flags = 49,
    }, {}, {}, function() -- Done
        StopAnimTask(ped, 'mp_suicide', 'pill', 1.0)
        TriggerServerEvent('hospital:server:removeIfaks')
        TriggerEvent('tmg-inventory:client:ItemBox', TMGCore.Shared.Items['ifaks'], 'remove')
        TriggerServerEvent('hud:server:RelieveStress', math.random(12, 24))
        SetEntityHealth(ped, GetEntityHealth(ped) + 10)

        MedState.painkillerAmount = math.min(3, (MedState.painkillerAmount or 0) + 1)
        MedState.onPainKillers = true

        if math.random(1, 100) < 50 then RemoveBleed(1) end
    end, function() -- Cancel
        StopAnimTask(ped, 'mp_suicide', 'pill', 1.0)
        TMGCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

-- Uses a bandage item: plays an inspecting animation/progressbar, then
-- consumes the item, heals a small amount of health, has a 50% chance to
-- reduce bleeding by 1, and a small chance to also clear minor injuries.
RegisterNetEvent('hospital:client:UseBandage', function()
    local ped = PlayerPedId()
    TMGCore.Functions.Progressbar('use_bandage', Lang:t('progress.bandage'), 4000, false, true, {
        disableMovement = true,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true,
    }, { animDict = 'anim@amb@business@weed@weed_inspecting_high_dry@', anim = 'weed_inspecting_high_base_inspector', flags = 49,
    }, {}, {}, function() -- Done
        StopAnimTask(ped, 'anim@amb@business@weed@weed_inspecting_high_dry@', 'weed_inspecting_high_base_inspector', 1.0)
        TriggerServerEvent('hospital:server:removeBandage')
        TriggerEvent('tmg-inventory:client:ItemBox', TMGCore.Shared.Items['bandage'], 'remove')
        SetEntityHealth(ped, GetEntityHealth(ped) + 10)

        if math.random(1, 100) < 50 then RemoveBleed(1) end
        if math.random(1, 100) < 7 and ResetPartial then ResetPartial() end
    end, function() -- Cancel
        StopAnimTask(ped, 'anim@amb@business@weed@weed_inspecting_high_dry@', 'weed_inspecting_high_base_inspector', 1.0)
        TMGCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

-- Uses a painkillers item: plays a pill animation/progressbar, then
-- consumes the item and stacks a painkiller dose (suppresses injury
-- penalties while active, see wounding pulse thread below).
RegisterNetEvent('hospital:client:UsePainkillers', function()
    local ped = PlayerPedId()
    TMGCore.Functions.Progressbar('use_painkillers', Lang:t('progress.painkillers'), 3000, false, true, {
        disableMovement = true,
        disableCarMovement = false,
        disableMouse = false,
        disableCombat = true,
    }, { animDict = 'mp_suicide', anim = 'pill', flags = 49,
    }, {}, {}, function() -- Done
        StopAnimTask(ped, 'mp_suicide', 'pill', 1.0)
        TriggerServerEvent('hospital:server:removePainkillers')
        TriggerEvent('tmg-inventory:client:ItemBox', TMGCore.Shared.Items['painkillers'], 'remove')

        MedState.painkillerAmount = math.min(3, (MedState.painkillerAmount or 0) + 1)
        MedState.onPainKillers = true
    end, function() -- Cancel
        StopAnimTask(ped, 'mp_suicide', 'pill', 1.0)
        TMGCore.Functions.Notify(Lang:t('error.canceled'), 'error')
    end)
end)

-- Continuously applies MedState.movementRate (set by the injury pulse
-- below) as a ped move-rate override while it's below normal speed.
CreateThread(function()
    while true do
        -- TMG Nil-Guard: Prevents crash if MedState loads slow
        if MedState and MedState.movementRate and MedState.movementRate < 1.0 then
            SetPedMoveRateOverride(PlayerPedId(), MedState.movementRate)
            Wait(0)
        else
            Wait(1000)
        end
    end
end)

-- [[ 4. FORENSIC & TRAUMA PULSE (1Hz) ]]
-- Once-per-second injury/bleed simulation tick: derives movement speed
-- penalty from the worst current injury, counts down active painkiller
-- doses, and while actively bleeding (and not in bed/dead/last-stand)
-- periodically dims/flashes the screen, may ragdoll the player, and
-- accelerates bleed severity based on movement and elapsed time.
CreateThread(function()
    Wait(2500)
    prevPos = GetEntityCoords(PlayerPedId(), true)
    local pkTick = 0

    while true do
        Wait(1000)

        -- FINAL STABILITY GUARD: Exit loop iteration if Core Matrix is missing
        if not MedState or not BodyParts then goto continue end

        local ped = PlayerPedId()

        -- A. Dynamic Movement Calculation
        local injuredCount = MedState.injured and #MedState.injured or 0
        if injuredCount > 0 then
            local maxLevel = 0
            for i = 1, injuredCount do
                if MedState.injured[i].severity > maxLevel then maxLevel = MedState.injured[i].severity end
            end
            MedState.movementRate = Config.MovementRate[maxLevel] or 1.0
        else
            MedState.movementRate = 1.0
        end

        -- B. Painkiller Synthesis
        if MedState.onPainKillers then
            pkTick = pkTick + 1
            if pkTick >= (Config.PainkillerInterval or 60) then
                MedState.painkillerAmount = (MedState.painkillerAmount or 0) - 1
                pkTick = 0
                if MedState.painkillerAmount <= 0 then
                    MedState.onPainKillers = false
                    MedState.painkillerAmount = 0
                end
            end
        end

        -- C. Trauma Bleed & Blackout Matrices (Line 130 Fix)
        if (MedState.isBleeding or 0) > 0 and not MedState.onPainKillers and not MedState.isInBed and not MedState.isDead and not MedState.inLastStand then

            -- Ensure trackers are initialized before math operations
            MedState.fadeOut = MedState.fadeOut or 0
            MedState.blackout = MedState.blackout or 0
            MedState.advanceBleed = MedState.advanceBleed or 0

            MedState.fadeOut = MedState.fadeOut + 1

            -- Vision Fade Logic (Safety Compare)
            if MedState.fadeOut >= (Config.FadeOutTimer or 10) then
                MedState.fadeOut = 0
                MedState.blackout = MedState.blackout + (MedState.isBleeding > 3 and 2 or 1)

                if MedState.blackout >= (Config.BlackoutTimer or 5) then
                    MedState.blackout = 0
                    SetFlash(0, 0, 100, 7000, 100)
                    DoScreenFadeOut(500)
                    while not IsScreenFadedOut() do Wait(0) end

                    if not IsPedRagdoll(ped) and IsPedOnFoot(ped) and not IsPedSwimming(ped) then
                        ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', 0.08)
                        SetPedToRagdollWithFall(ped, 7500, 9000, 1, GetEntityForwardVector(ped), 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
                    end
                    Wait(1500)
                    DoScreenFadeIn(1000)
                else
                    DoScreenFadeOut(500)
                    while not IsScreenFadedOut() do Wait(0) end
                    DoScreenFadeIn(500)
                end
            end

            -- Kinetic Bleed Acceleration
            local currPos = GetEntityCoords(ped)
            if #(currPos - prevPos) > 1.0 and not IsPedInAnyVehicle(ped) and MedState.isBleeding > 2 then
                MedState.advanceBleed = MedState.advanceBleed + (Config.BleedMovementAdvance or 1)
            end
            prevPos = currPos

            if MedState.advanceBleed >= (Config.AdvanceBleedTimer or 20) then
                MedState.advanceBleed = 0
                if ApplyBleed then ApplyBleed(1) end
            else
                MedState.advanceBleed = MedState.advanceBleed + 1
            end
        end

        ::continue::
    end
end)
