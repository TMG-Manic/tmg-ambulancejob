# tmg-ambulancejob

> EMS job plus the server-wide death, last-stand, bleeding, and limb-injury system that every player is subject to.

## Overview

This resource owns two things that are only loosely related: the **ambulance job** (duty toggle,
vehicle garage, personal stash, `/911e` alerts, treatment and revive tools) and the **medical
state machine** that governs what happens to any player who takes damage or dies. The second half
runs on every client regardless of job, so the resource is effectively a hard requirement for the
server rather than an optional job script.

Damage handling starts with a 100 ms client loop that watches health and armour. On a drop it
resolves the damaging bone (`Config.Bones`) and weapon (`Config.Weapons` → a weapon *class*), then
decides whether the hit counts as an injury event (`IsDamagingEvent`). Injury events mark a body
part as damaged with a severity of 1-3, escalating existing damage by +1 up to a cap of 4, and may
also apply an immediate bleed level and a ragdoll stagger depending on the weapon class, the hit
area, and whether armour absorbed it. A separate 1 Hz "trauma pulse" then applies the ongoing
consequences: a movement-rate penalty scaled to the worst injury, limp clipsets, periodic ragdolls
from leg injuries, disabled aim/vehicle controls from arm injuries, screen flashes from head
injuries, and — while bleeding — progressive vision fade, blackouts, and bleed escalation.

Death is two-staged. The first fatal damage event puts the player into **last stand**: they are
resurrected in place at 150 health, locked into a writhe animation, and given
`Config.ReviveInterval` (360) seconds on a countdown. A second fatal hit while downed, or the
countdown reaching zero, transitions them to **dead**: resurrected in place again, invincible, at
full health, in a dead pose, with a `Config.DeathTime` (300) second respawn countdown. Both states
are mirrored into player metadata (`inlaststand`, `isdead`) so they survive a relog — `tmg-hud`
reads those same fields to decide whether to hide the HUD.

Recovery has four routes: an EMS medic with a `firstaid` item (`/revivep`), any player with a
`firstaid` item performing a 30-60 second CPR sequence on a downed player, an admin command, or
self-service hospital check-in. Check-in only works when fewer than `Config.MinimalDoctors` (2)
medics are on duty — otherwise the terminal pages a doctor instead. Respawning at a hospital puts
the player in a bed, optionally wipes their inventory, charges `Config.BillCost` (2000) to their
bank, credits the `ambulance` society account, and emails them a bill.

## Dependencies

| Resource | Required | Used for |
| :--- | :--- | :--- |
| `tmg-core` | Yes | Player object, callbacks, commands, `Progressbar`, `Notify`, `DrawText`/`HideText`/`KeyPressed`, `GetClosestPlayer`, `HasItem`, `Shared.Items`, `Shared.Weapons`, `GetIdentifier` |
| `tmgnosql` | Yes | Inventory wipe on respawn (`SaveToCollection`) |
| `PolyZone` | Yes | `BoxZone` / `ComboZone` fallbacks when `UseTarget` is off (loaded via `@PolyZone`) |
| `tmg-target` | Conditional | Interaction zones when the `UseTarget` convar is `true` |
| `tmg-inventory` | Yes | `RemoveItem` for `bandage` / `ifaks` / `painkillers` / `firstaid`, `OpenInventory` for the job stash, `ItemBox` notifications |
| `tmg-banking` | Yes | `AddMoney('ambulance', ...)` for treatment bills |
| `tmg-menu` | Yes | Vehicle garage menu and the patient status menu |
| `tmg-policejob` | Yes | `IsHandcuffed()` export and the `police:client:GetCuffed` / `DeEscort` / `police:server:UpdateBlips` events |
| `tmg-hud` | Yes | `hud:server:RelieveStress`, `hud:client:UpdateNeeds`; also reads `isdead`/`inlaststand` metadata |
| `tmg-phone` | Yes | `tmg-phone:server:sendNewMail` for the bill receipt |
| `tmg-log` | Yes | Death logs |
| `tmg-prison` | Yes | `prison:client:Enter` when leaving a bed while jailed |
| `LegacyFuel` | Yes | `SetFuel` on spawned job vehicles |
| `spawnmanager` | Yes | `setAutoSpawn(false)` on player load |
| `interact-sound` | Yes | `InteractSound_SV:PlayOnSource` |
| `monitor` (txAdmin) | Optional | `txAdmin:events:healedPlayer` handler |
| `dpemotes` / emote system | Yes | `animations:client:EmoteCommandStart` after check-in |

There are no `GetResourceState`-guarded soft dependencies; every integration above is called
directly.

## Configuration

### Core toggles

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `Config.UseTarget` | `boolean` | from convar `UseTarget` | Read as `GetConvar('UseTarget', 'false') == 'true'`. Set `setr UseTarget true` in `server.cfg` rather than editing this line. |
| `Config.MinimalDoctors` | `number` | `2` | At or above this many on-duty medics, the hospital check-in terminal pages a doctor instead of admitting the player. |
| `Config.DocCooldown` | `number` | `1` | Minutes between doctor pages, enforced server-side with a single global flag. |
| `Config.WipeInventoryOnRespawn` | `boolean` | `true` | Clears the player's inventory (in memory and in the `players` document) when respawning at a hospital. |
| `Config.RespawnAtNearestHospital` | `boolean` | `true` | Picks the closest `Config.Locations.hospital` entry; otherwise always index 1. |
| `Config.Helicopter` | `string` | `'polmav'` | Model spawned at the helipad. |
| `Config.BillCost` | `number` | `2000` | Charged to **bank** on every check-in and hospital respawn. |
| `Config.AIHealTimer` | `number` | `20` | Seconds in a bed before the automatic revive fires. |
| `Config.AlertShowInfo` | `number` | `2` | Above this many simultaneous injuries the limb alert collapses to a generic "many places" message. |
| `Config.MessageTimer` | `number` | `12` | Seconds between limb alerts. |

### Death and last stand

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `Config.DeathTime` | `number` | `300` | Seconds on the respawn countdown after dying from a second fatal hit. |
| `Config.ReviveInterval` | `number` | `360` | Seconds a player survives in last stand. Also reused as the death countdown when resuming a dead character on login. |
| `Config.MinimumRevive` | `number` | `300` | Threshold that switches the on-screen last-stand text from "bleeding out" to "bleeding out / request help". |

### Injury rolls

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `Config.HealthDamage` | `number` | `5` | Minimum health loss before an injury roll happens; also the denominator of the injury-chance multiplier. |
| `Config.ArmorDamage` | `number` | `5` | Minimum armour loss before the damage watcher reacts. |
| `Config.ForceInjury` | `number` | `35` | Damage at or above this always produces an injury. |
| `Config.MaxInjuryChanceMulti` | `number` | `3` | If `damage / HealthDamage` exceeds this, the injury is forced. |
| `Config.DamageMinorToMajor` | `number` | `35` | Damage at or above this promotes a minor-class weapon to major for effect purposes. Set to `100` to disable. |
| `Config.AlwaysBleedChance` | `number` | `70` | Percent chance of bleeding from a sub-threshold hit by an `AlwaysBleedChanceWeapons` class. |
| `Config.MajorArmoredBleedChance` | `number` | `45` | Percent bleed chance for major hits; doubled for non-critical areas when unarmoured. |

### Bleeding and blackout

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `Config.FadeOutTimer` | `number` | `2` | 1 Hz pulses of bleeding before a screen fade. |
| `Config.BlackoutTimer` | `number` | `10` | Fade events before a full blackout + ragdoll. Bleed level 4 counts double. |
| `Config.AdvanceBleedTimer` | `number` | `10` | Accumulated bleed ticks before the bleed level increases by 1. |
| `Config.BleedMovementAdvance` | `number` | `3` | Extra bleed ticks added per second while moving more than 1 unit, on foot, at bleed level > 2. |
| `Config.BleedTickRate` | `number` | `30` | **Unused.** The health-drain tick is hardcoded to 5000 ms. |
| `Config.BleedMovementTick` | `number` | `10` | **Unused.** |
| `Config.BleedTickDamage` | `number` | `8` | **Unused.** Drain per tick is the bleed level itself (1-4 HP). |

### Injury side-effects

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `Config.HeadInjuryTimer` | `number` | `30` | Pulses between head-injury effect rolls. |
| `Config.ArmInjuryTimer` | `number` | `30` | Pulses between arm-injury effect applications. |
| `Config.LegInjuryTimer` | `number` | `15` | Pulses between leg-injury effect rolls. |
| `Config.HeadInjuryChance` | `number` | `25` | Percent chance a head-injury roll produces the flash + ragdoll. |
| `Config.LegInjuryChance` | `table` | `{ Running = 50, Walking = 15 }` | Percent ragdoll chance while running vs walking. |
| `Config.PainkillerInterval` | `number` | `60` | Seconds one painkiller dose lasts. Doses stack to a maximum of 3. |
| `Config.MovementRate` | `array` | `{0.98, 0.96, 0.94, 0.92}` | Ped move-rate override indexed by the worst injury severity. |

### Classification tables

- `Config.WeaponClasses` — the 13 numeric class ids (`SMALL_CALIBER` … `NOTHING`).
- `Config.Weapons` — weapon hash → class id. Covers pistols, SMGs, rifles, shotguns, melee,
  explosives, fire, drowning/exhaustion, falls, vehicle impacts, and wildlife. Both stun-gun
  hashes map to `NOTHING`, which the damage watcher skips outright.
- `Config.MinorInjurWeapons` — small/medium caliber, cutting, wildlife, other, light impact.
- `Config.MajorInjurWeapons` — high caliber, heavy impact, shotgun, explosive.
- `Config.AlwaysBleedChanceWeapons` — small/medium caliber and cutting (`WILDLIFE` is explicitly `false`).
- `Config.ForceInjuryWeapons` — high caliber, heavy impact, explosive.
- `Config.CriticalAreas` — `UPPER_BODY` (`armored = false`), `LOWER_BODY` and `SPINE` (`armored = true`).
  `armored = true` means a bleed roll still applies when the victim is wearing armour.
- `Config.StaggerAreas` — per-area ragdoll chances with separate `major` / `minor` percentages
  (`SPINE` and `UPPER_BODY` 60/30, legs 100/85, feet 100/100).
- `Config.Bones` / `Config.BoneIndexes` — bone hash ↔ area label, in both directions.
- `Config.WoundStates` / `Config.BleedingStates` — localised severity labels used in alerts.

### Locations

`Config.Locations` holds `checking`, `duty`, `vehicle`, `helicopter`, `roof`, `main`, `stash`,
`beds`, `jailbeds`, `hospital`, and `stations`. Two hospitals are configured (Pillbox and Paleto),
each with its own `name`, `location`, and `beds` array of `{ coords = vector4, taken = false, model = <hash> }`.
`Config.Locations['beds']` is a **duplicate, unused** list — the bed code reads
`Config.Locations['hospital'][i]['beds']` and `Config.Locations['jailbeds']` only.

`Config.AuthorizedVehicles` maps job grade → `{ model = label }`; grade 0 currently gets only
`ambulance`. `Config.VehicleSettings` defines extras toggles for `car1` / `car2`, neither of which
matches the configured vehicle model, so no extras are currently applied.

## The death / injury state machine

### States

`MedState` (in `client/main.lua`) is the single source of client truth. The relevant flags are
`isDead`, `inLastStand`, `isBleeding` (0-4), `isInBed`, `canLeaveBed`, `deathTime`, `timer`,
`isEscorted`, `onPainKillers`, `injured` (array), and the counters `bleedTick`, `advanceBleed`,
`fadeOut`, `blackout`.

`laststand.lua` also maintains two globals for other resources: `InLaststand` and `LaststandTime`.

### Transitions

| From | Trigger | To | Effects |
| :--- | :--- | :--- | :--- |
| Alive | `CEventNetworkEntityDamage` with `victimDied`, ped is the local player, not already in last stand | Last stand | `SetLaststand(true)`: `MedState.timer = Config.ReviveInterval`, ragdoll settle wait, `NetworkResurrectLocalPlayer`, writhe (or seated) animation, health set to 150, `hospital:server:ambulanceAlert('civ_down')`, `hospital:server:SetLaststandStatus(true)` |
| Last stand | Another `victimDied` event while `inLastStand` and not `isDead` | Dead | `SetLaststand(false)`, death log written with killer + weapon, `MedState.deathTime = Config.DeathTime`, `OnDeath()`, `DeathTimer()` |
| Last stand | `MedState.timer` reaches 0 in the 1 Hz heartbeat | Dead | `error.bled_out` notification, `SetLaststand(false)`, death log, **`MedState.deathTime = 0`**, `OnDeath()`, `DeathTimer()` |
| Dead | `deathTime <= 0` and `[E]` held for 5 consecutive seconds, not in a bed | Respawning | `hospital:client:RespawnAtHospital` |
| Dead / Last stand | `hospital:client:Revive` | Alive | Resurrect in place, `ResetAll()`, max health 200, `SetDeathStatus(false)`, `SetLaststandStatus(false)`, `hud:server:RelieveStress(100)` |
| Any | Login with `isdead` and not `inlaststand` metadata | Dead | `MedState.deathTime = Config.ReviveInterval` (not `DeathTime`), `OnDeath()`, `DeathTimer()` |
| Any | Login with `inlaststand` and not `isdead` metadata | Last stand | `SetLaststand(true)` |
| Any | Login with neither | Alive | Both metadata flags explicitly cleared |

While `isDead` or `inLastStand`, `dead.lua` disables all control actions except look (1, 2), chat
(245), voice (249), and the pause menu (322), keeps the pose animation reapplied, forces the ped
unarmed while dead, and draws the countdown / help-request HUD text. Escorted players
(`hospital:client:isEscorted`) have their pose animation suppressed so the escort animation can
take over.

### Bleeding

`MedState.isBleeding` runs 0-4 and is capped by `ApplyBleed`. Two loops act on it:

1. **Health drain** (`client/main.lua`): while `isBleeding > 0`, every 5000 ms the ped loses
   `isBleeding` HP. This tick interval and damage are hardcoded, not read from config.
2. **Trauma pulse** (`client/wounding.lua`, 1 Hz): skipped while on painkillers, in a bed, dead, or
   in last stand. Increments `fadeOut`; at `Config.FadeOutTimer` it resets and increments
   `blackout` by 1 (or 2 when `isBleeding > 3`), then either does a brief fade-out/fade-in or, at
   `Config.BlackoutTimer`, a screen flash plus a 7.5-9 second ragdoll fall. Separately, moving more
   than 1 unit per second on foot at bleed level > 2 adds `Config.BleedMovementAdvance` to
   `advanceBleed`; when `advanceBleed` reaches `Config.AdvanceBleedTimer` the bleed level goes up by 1.

Bleed is applied by `ApplyImmediateEffects` on a hit:

- **Minor** class weapon below `DamageMinorToMajor`: bleeds only if the hit area is in
  `Config.CriticalAreas` **and** armour is at 0.
- **Major** class weapon (or a minor one at/above `DamageMinorToMajor`): if the area is critical,
  bleeds when armour is 0 or when the area is flagged `armored` and a d100 roll is ≤
  `MajorArmoredBleedChance`. If the area is not critical, the threshold is `MajorArmoredBleedChance`
  while armoured and double that while unarmoured.
- Sub-threshold hits (below `Config.HealthDamage`) from an `AlwaysBleedChanceWeapons` class roll
  against `Config.AlwaysBleedChance`.

### Injuries

`BodyParts` tracks 15 areas, six of which are flagged `limp = true` (`SPINE`, `LOWER_BODY`,
`LLEG`, `LFOOT`, `RLEG`, `RFOOT`). A fresh injury gets severity `math.random(1, 3)`; further hits
to the same area escalate by +1 to a maximum of 4. Any limp-flagged injury applies the
`move_m@injured` clipset and disables sprint.

`ProcessDamage` applies the ongoing penalties, each gated by its own tick counter and skipped
entirely while on painkillers:

| Category | Areas | Condition | Effect |
| :--- | :--- | :--- | :--- |
| 1 | `LLEG`, `RLEG`, `LFOOT`, `RFOOT` | severity > 1 (legs) or > 2 (feet) | Camera shake + `SetPedToRagdollWithFall`, chance from `Config.LegInjuryChance` |
| 2 | `LARM`, `RARM`, `LHAND`, `RHAND`, `LFINGER`, `RFINGER` | severity > 1 (arms) or > 2 (hands/fingers) | Disables vehicle control 63 and the aim control for the matching side while free-aiming |
| 3 | `HEAD` | severity > 2 | `Config.HeadInjuryChance` roll → screen flash, fade-out, ragdoll, fade-in after 5 s |

`CheckWeaponDamage` separately records which weapons have hit the player. Each newly seen weapon
produces a notification using the core's `damagereason` label and is appended to
`MedState.damageList`, which is synced to the server as the player's weapon-wound list for EMS
status checks.

### Healing

| Path | Effect |
| :--- | :--- |
| `ResetPartial()` | Clears injuries of severity ≤ 2 and bleeding ≤ 2 |
| `ResetAll()` | Clears everything: all injuries, bleed, painkillers, blood decals, movement clipset, weapon damage list, and resets hunger/thirst server-side |
| `bandage` item | +10 HP, 50% chance of −1 bleed, 7% chance of `ResetPartial()` |
| `ifaks` item | +10 HP, 12-24 stress relief, +1 painkiller dose, 50% chance of −1 bleed |
| `painkillers` item | +1 painkiller dose (max 3), each lasting `Config.PainkillerInterval` seconds |
| EMS `/heal` | Consumes the **medic's** bandage, sends `hospital:client:HealInjuries(patient, 'full')` → `ResetAll()` |
| Bed check-in | `hospital:client:Revive` after `Config.AIHealTimer` seconds |

## Exports

### Server

```lua
exports['tmg-ambulancejob']:GetDoctorCount()
```
**Returns:** `number` — the current on-duty ambulance count, maintained by the
`AddDoctor` / `RemoveDoctor` events and decremented on `playerDropped`. No other resource in the
repository currently calls this.

### Client

```lua
exports['tmg-ambulancejob']:PainKillerLoop(pkAmount)
```
| Param | Type | Description |
| :--- | :--- | :--- |
| `pkAmount` | `number?` | Optional dose count to set; omitted leaves the current count |

Sets `MedState.onPainKillers = true`, suppressing injury side-effects and the bleed pulse until
the doses expire. **Returns:** nothing.

## Events

### Server events (client → server)

#### `hospital:server:SendToBed`
Assigns a bed, claims it in the server-side occupancy table, broadcasts it as taken, charges
`Config.BillCost` and emails the bill.
**Params:** `(bedId, isRevive, hospitalIndex)`. **Validation:** the caller must be a loaded player and
`Config.Locations['hospital'][hospitalIndex]['beds'][bedId]` must exist, otherwise the handler
returns silently. If the requested bed is already occupied the handler substitutes the first free bed
in that hospital, and refuses with `error.beds_taken` only when every bed is taken. The handler still
does not check that the caller is dead or nearby, and charges unconditionally once a bed is assigned.

#### `hospital:server:RespawnAtHospital`
Places the player in the first free jail bed (if `metadata.injail > 0`) or hospital bed — resolved
from the server-side occupancy table, falling back to bed `1` when everything is taken, since the
player has to respawn somewhere — claims that bed for them, optionally wipes their inventory, charges
the bill once, and emails the receipt.
**Params:** `(hospitalIndex)`. **Validation:** none — the index is trusted, and the handler does not
check that the caller is actually dead.

#### `hospital:server:ambulanceAlert`
Broadcasts the caller's coordinates and a message to every on-duty medic.
**Params:** `(text)`. **Validation:** none; the message text is relayed as-is.

#### `hospital:server:LeaveBed`
Releases whatever bed the caller was recorded as occupying server-side, then marks that same bed
free for all clients. **Params:** none — the client still sends its own `bedId`/`hospitalIndex`,
but the handler takes no arguments and reads both from its own `PlayerBeds[src]` record instead, so
a client cannot free a bed it does not hold. A caller with no recorded bed is ignored. The
broadcast is always `hospital:client:SetBed`, whose handler bails on a `nil` hospital index, so
releasing a **jail** bed does not clear that bed's local `taken` flag on clients — harmless, since
assignment reads the server's occupancy table rather than the config flags.

#### `hospital:server:SyncInjuries`
Stores the caller's injury/bleed table for later status queries.
**Params:** `(data)` = `{ limbs = <BodyParts>, isBleeding = <0-4> }`. **Validation:** none; whatever
the client sends becomes the authoritative record medics see.

#### `hospital:server:SetWeaponDamage`
Stores the caller's weapon-wound list. **Params:** `(data)`. **Validation:** the caller must resolve
to a `Player`; contents are not checked.

#### `hospital:server:RestoreWeaponDamage`
Clears the caller's weapon wounds in memory and sets `metadata.injuries` to `{}`. **Params:** none.

#### `hospital:server:SetDeathStatus`
Writes `metadata.isdead`. **Params:** `(isDead)`. **Validation:** none — the value is taken directly
from the client.

#### `hospital:server:SetLaststandStatus`
Writes `metadata.inlaststand`. **Params:** `(bool)`. **Validation:** none.

#### `hospital:server:SetArmor`
Writes `metadata.armor`. **Params:** `(amount)`. **Validation:** none; the amount is trusted and is
re-applied to the ped on next login.

#### `hospital:server:TreatWounds`
Consumes one `bandage` from the caller and fully heals the target.
**Params:** `(playerId)`. **Validation:** the target must resolve and the **caller's job must be
`ambulance`**. Duty state is not checked, and there is no proximity check server-side (the client
enforces 5 m before firing).

#### `hospital:server:RevivePlayer`
Revives a target. **Params:** `(playerId, isOldMan)`. **Validation:** the caller must either have the
`ambulance` job **or** hold a `firstaid` item. If neither is true the revive is refused and the
caller gets an `error.no_firstaid` notification; nothing else happens. When `isOldMan` is truthy the
caller is additionally charged $5000 cash — nothing in this resource ever passes that flag, but it is
a client-supplied argument.

#### `hospital:server:SendDoctorAlert`
Notifies every on-duty medic that a patient is waiting. **Params:** `(hospitalName)`.
**Validation:** none beyond a single global `doctorCalled` flag cleared after `Config.DocCooldown`
minutes; the hospital name is relayed verbatim.

#### `hospital:server:UseFirstAid`
Asks the target client whether it can be helped. **Params:** `(targetId)`. **Validation:** the target
must resolve.

#### `hospital:server:CanHelp`
Relays the target's answer back to the helper. **Params:** `(helperId, canHelp)`.
**Validation:** none — `canHelp` is decided entirely on the downed player's client.

#### `hospital:server:removeBandage` / `removeIfaks` / `removePainkillers`
Consume one of the matching item from the caller. **Params:** none. **Validation:** only that the
caller resolves to a `Player`; the inventory export handles the missing-item case.

#### `hospital:server:resetHungerThirst`
Sets the caller's `hunger` and `thirst` metadata to 100 and pushes the values to their HUD.
**Params:** none. **Validation:** none — any client can refill its own needs at will.

#### `tmg-ambulancejob:server:stash`
Opens the caller's personal stash `ambulancestash_<citizenid>`. **Params:** none.
**Validation:** the stash id is derived server-side from the caller's citizenid, so it cannot be
redirected. No job check.

### Client events (server → client)

| Event | Params | Purpose |
| :--- | :--- | :--- |
| `hospital:client:ambulanceAlert` | `(coords, text)` | Notification, sound, and a fading blip + 100 m radius blip (removed after ~125 s) |
| `hospital:client:Revive` | — | Full revive: resurrect, `ResetAll()`, 200 HP, clear death/last-stand metadata |
| `hospital:client:HealInjuries` | `(healType)` | `'full'` → `ResetAll()`, anything else → `ResetPartial()` |
| `hospital:client:SendToBed` | `(id, data, isRevive)` | Enters the bed camera state; `isRevive` schedules an auto-revive after `Config.AIHealTimer` |
| `hospital:client:SetBed` | `(id, isTaken, hospitalIndex)` | Mirrors a hospital bed's occupancy locally |
| `hospital:client:SetBed2` | `(id, isTaken)` | Mirrors a jail bed's occupancy locally |
| `hospital:client:RespawnAtHospital` | — | Picks the nearest hospital, requests respawn, clears cuff/escort state |
| `hospital:client:SendBillEmail` | `(amount, hospitalName)` | Sends a phone mail after a 2.5-4 s delay |
| `hospital:client:SetDoctorCount` | `(amount)` | Updates the cached on-duty medic count; when the count actually changed and the player is not in a bed, fires `hospital:client:RefreshCheckInState` |
| `hospital:client:RefreshCheckInState` | — | Redraws the check-in prompt with the label matching the current doctor count (`text.call_doc` vs `text.check_in`); a no-op unless the player is standing in a check-in zone |
| `hospital:client:CheckStatus` | — | EMS: reads the nearest player's injuries and opens the status menu |
| `hospital:client:TreatWounds` | — | EMS: bandage treatment sequence on the nearest player |
| `hospital:client:RevivePlayer` | — | EMS: first-aid revive sequence on the nearest player |
| `hospital:client:UseIfaks` / `UseBandage` / `UsePainkillers` / `UseFirstAid` | — | Item-use flows |
| `hospital:client:CanHelp` | `(helperId)` | Answers whether the local downed player can be CPR'd |
| `hospital:client:HelpPerson` | `(targetId)` | Runs the 30-60 s CPR progressbar |
| `hospital:client:isEscorted` | `(bool)` | Suppresses the downed pose animation while being carried |
| `hospital:client:SetPain` | — | Admin/debug: random bleed plus forced trauma on bones `24816` and `40269` |
| `hospital:client:KillPlayer` | — | Admin: sets health to 0 |
| `hospital:client:adminHeal` | — | Admin: `ResetAll()`, 200 HP, reset hunger/thirst |
| `tmg-ambulancejob:checkin` | `(hospitalIndex)` | Hospital check-in flow |
| `tmg-ambulancejob:beds` | `(hospitalIndex, bedId)` | Lie-in-bed flow, validated to within 3 m client-side |
| `tmg-ambulancejob:elevator_roof` / `elevator_main` | `(index)` | Teleports between the ground floor and the roof |
| `ambulance:client:TakeOutVehicle` | `({ vehicle })` | Menu wrapper for `TakeOutVehicle` |
| `EMSToggle:Duty` | — | Toggles duty and refreshes police blips |

### Server → server / framework events consumed

`txAdmin:events:healedPlayer` — guarded by `GetInvokingResource() ~= 'monitor'` and a type check on
`eventData.id`, then fires a revive and a full heal.
`playerDropped` — releases any bed the leaver was occupying, and decrements the doctor count if the
leaver was registered.
`TMGCore:Client:OnPlayerLoaded`, `TMGCore:Client:OnPlayerUnload`, `TMGCore:Client:OnJobUpdate`,
`TMGCore:Client:SetDuty` — client-side job/state sync.

## Callbacks

### `hospital:GetDoctors`
`TriggerCallback('hospital:GetDoctors', cb)` → `number`. Recounts on-duty medics by scanning all
players (independent of the cached `doctorCount`).

### `hospital:GetPlayerStatus`
`TriggerCallback('hospital:GetPlayerStatus', cb, playerId)` → a table containing `BLEED` (only when
above 0), one entry per damaged limb keyed by area name, and `WEAPONWOUNDS` (always present, may be
empty). Takes any player id — there is no check that the caller is a medic.

### `hospital:GetPlayerBleeding`
`TriggerCallback('hospital:GetPlayerBleeding', cb)` → the **caller's** bleed level, or `nil`.

## Commands

| Command | Args | Permission | Description |
| :--- | :--- | :--- | :--- |
| `/911e` | `[message]` | none | Sends an EMS report with your location to all on-duty medics; falls back to a default civilian-call message |
| `/status` | — | `ambulance` job | Reads the nearest player's injuries and opens the status menu |
| `/heal` | — | `ambulance` job | Bandage treatment on the nearest player |
| `/revivep` | — | `ambulance` job | First-aid revive on the nearest player |
| `/revive` | `[id]` | `admin` | Fully revives a player, or yourself with no id |
| `/setpain` | `[id]` | `admin` | Forces bleeding and bone trauma on a player, or yourself |
| `/kill` | `[id]` | `admin` | Sets a player's health to 0, or your own |
| `/aheal` | `[id]` | `admin` | Fully heals a player, or yourself |

The three job commands check `Player.PlayerData.job.name == 'ambulance'` but **not** duty state.

## Items

| Item | Registered | Consumed by | Effect |
| :--- | :--- | :--- | :--- |
| `bandage` | `CreateUseableItem` | `hospital:server:removeBandage`, `hospital:server:TreatWounds` | Self: +10 HP, 50% −1 bleed, 7% partial reset. EMS `/heal`: consumes the medic's bandage and fully heals the patient |
| `ifaks` | `CreateUseableItem` | `hospital:server:removeIfaks` | +10 HP, 12-24 stress relief, +1 painkiller dose, 50% −1 bleed |
| `painkillers` | `CreateUseableItem` | `hospital:server:removePainkillers` | +1 painkiller dose, max 3, `Config.PainkillerInterval` seconds each |
| `firstaid` | `CreateUseableItem` | `hospital:server:RevivePlayer` | Starts the CPR flow on the nearest downed player within 1.5 m; consumed on a successful revive |

Each useable-item handler re-checks the item is still in the player's inventory before firing the
client flow.

## Data model

This resource has no collection of its own. It touches:

### `players`
Written on hospital respawn when `Config.WipeInventoryOnRespawn` is set:

```jsonc
{ "citizenid": "ABC12345", "inventory": [] }
```

Player metadata written through the framework (`SetMetaData`, which persists via `tmg-core`):

| Field | Type | Set by |
| :--- | :--- | :--- |
| `isdead` | `boolean` | `hospital:server:SetDeathStatus` |
| `inlaststand` | `boolean` | `hospital:server:SetLaststandStatus` |
| `armor` | `number` | `hospital:server:SetArmor`; re-applied to the ped on login |
| `injuries` | `table` | Cleared to `{}` by `hospital:server:RestoreWeaponDamage` |
| `hunger` / `thirst` | `number` | Reset to 100 by `hospital:server:resetHungerThirst` |

`metadata.injail` is read (never written) to route respawns to jail beds and to re-enter the prison
state after leaving a bed.

No other collection is read or written by this resource, and no `EnsureIndex` calls are made.

## Security & reliability notes

**Validated server-side.** `TreatWounds` requires the `ambulance` job. `RevivePlayer` requires
either the `ambulance` job or a `firstaid` item, and refuses with an `error.no_firstaid`
notification when the caller has neither. The txAdmin heal handler verifies the invoking resource is
`monitor`. The job stash
name is derived from the caller's own citizenid. `/revive`, `/setpain`, `/kill`, and `/aheal` are
registered with the `admin` permission group.

**Trusted from the client.** Almost all of the medical state is client-authoritative by design,
and the server stores it without checking:

- `SetDeathStatus`, `SetLaststandStatus`, `SetArmor` — a client can declare itself alive, or set an
  arbitrary armour value that will be restored on its next login.
- `SyncInjuries`, `SetWeaponDamage` — the injury report EMS sees is whatever the patient's client
  sent.
- `resetHungerThirst` — callable at any time with no cost or cooldown.
- `SendToBed` and `RespawnAtHospital` — the hospital index is unchecked and neither handler verifies
  the caller is dead or nearby. Both charge `Config.BillCost` regardless. The bed id is now
  server-resolved, so it can no longer be used to claim an occupied bed.
- `CanHelp` — the "can this player be revived" decision is made on the downed player's client and
  relayed through the server unverified.
- `RevivePlayer`'s `isOldMan` flag is a client argument that changes the cost path.

**Rate limiting.** The only throttle in the resource is `doctorCalled` on `SendDoctorAlert`, and it
is a single global flag — one page suppresses everyone else's for `Config.DocCooldown` minutes.
`/911e` and `ambulanceAlert` are unthrottled.

**Bed occupancy is tracked twice.** The server keeps the authoritative record in memory —
`OccupiedBeds[hospitalIndex][bedId]`, `OccupiedJailBeds[bedId]` and a `PlayerBeds[src]` reverse
index — and that is what every assignment scan reads. `hospital:client:SetBed` / `SetBed2` still
broadcast to clients and mutate each client's own copy of `Config.Locations`, which is what drives
the visuals. The server copy of `Config.Locations` is never written, so the config's `taken` flags
remain purely decorative there. Both records are in memory only and reset on restart.

## Known limitations

- **Nothing persists the final armour value on character unload.** `TMGCore:Client:OnPlayerUnload`
  clears local state and releases the bed, but the metadata keeps whatever the last individual
  `SetDeathStatus` / `SetLaststandStatus` / `SetArmor` event wrote. Armour changed since the last of
  those is lost.
- **When every bed is full the player is still put in bed 1.** `RespawnAtHospital` has to place the
  player somewhere, so it falls back to bed `1` and claims it, stacking that respawn on top of
  whoever already holds it.
- **`Config.BleedTickRate`, `Config.BleedTickDamage`, and `Config.BleedMovementTick` are dead.** The
  drain interval is hardcoded to 5000 ms and the damage per tick is the bleed level (1-4 HP), so
  tuning bleed lethality requires editing `client/main.lua`.
- **`Config.Locations['beds']` is dead configuration** — a duplicate of the Pillbox and Paleto bed
  lists that no code reads.
- **`Config.MinimumRevive` is only used for the HUD text.** The actual "can this player be helped"
  gate in `hospital:client:CanHelp` uses a hardcoded `MedState.timer <= 300`, so with the default
  `ReviveInterval` of 360 a downed player cannot be CPR'd during their first 60 seconds.
- **Login resumes a death with the wrong timer.** `client/job.lua` sets
  `MedState.deathTime = Config.ReviveInterval` (360) rather than `Config.DeathTime` (300) when
  restoring a dead character, so a relog lengthens the respawn wait.
- **Bleeding out of last stand skips the respawn timer.** That path sets `MedState.deathTime = 0`,
  making the hold-`[E]`-to-respawn prompt available immediately, whereas dying from a second fatal
  hit imposes the full `Config.DeathTime`.
- **`Config.VehicleSettings` never applies.** It is keyed `car1` / `car2`, but `TakeOutVehicle`
  looks the table up by the spawned model name (`ambulance`), so no extras are ever set.
- **The helicopter has no target-mode zone.** `RegisterJobZones` registers a `tmg-target` zone for
  the helipad only in the PolyZone branch; with `UseTarget` enabled there is no way to spawn the
  helicopter.
- **`Config.Locations['roof']` has one entry but `Config.Locations['helicopter']` has two**, so the
  Paleto helipad's elevator index has no matching roof destination.
- **`GetDoctorCount` and `hospital:GetDoctors` can disagree.** The former is an incrementing counter
  that can drift (duty events fire from several places); the latter recounts live.
- **No proximity checks on the EMS actions server-side.** `/heal`, `/revivep`, and `/status` enforce
  a 5 m radius entirely on the medic's client.
- **`MedState.statusChecks` entries build a `bone` field from `Config.BoneIndexes`** but nothing
  consumes it — the status menu only shows labels, and every entry routes to
  `hospital:client:TreatWounds` regardless of which injury was clicked.
