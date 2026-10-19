# Mission script analysis for the node editor (FAF Studio, M6)

Date: 2026-10-17. Read-only research for [MAP_EDITOR.md](../MAP_EDITOR.md) / [MAP_EDITOR_DESIGN.md](../MAP_EDITOR_DESIGN.md)
(M6 "Mission suite"). Goal: derive the taxonomy of a Blender-style node editor that generates `_script.lua`
(+ AI modules, `_strings.lua`) and the mission entries of `_scenario.lua` / `_save.lua`.

Evidence tags: **[verified]** read in the source cited; **[measured]** counted by script over the corpus;
**[inferred]** reasoned, not run in game; **[open]** not checked.

## 0. Corpus and method

Path shorthands used below:

| Tag | Path |
|---|---|
| `SF` | `faf_repo/fa/lua/ScenarioFramework.lua` (2378 lines) |
| `SO` | `faf_repo/fa/lua/SimObjectives.lua` (2167) |
| `ST` | `faf_repo/fa/lua/scenariotriggers.lua` (601) |
| `TRG` | `faf_repo/fa/lua/TriggerManager.lua` (1365) |
| `SU` | `faf_repo/fa/lua/sim/ScenarioUtilities.lua` (2021) |
| `BM` / `BO` | `faf_repo/fa/lua/ai/OpAI/BaseManager.lua` (2127) / `BaseOpAI.lua` (965) |
| `SPAI` | `faf_repo/fa/lua/ScenarioPlatoonAI.lua` (2471) |
| `CIN` / `TMG` | `faf_repo/fa/lua/cinematics.lua` / `TauntManager.lua` |
| `SI` | `faf_repo/fa/lua/simInit.lua` |
| `COOP` | `C:/ProgramData/FAForever/gamedata/lobby_coop.cop` (a zip; extracted by script to the scratchpad), member `mods/coop/hook/lua/ScenarioFramework.lua` (366 lines) and `.../simInit.lua` (46) |
| `MG` | `C:/Users/Marlo/Documents/My Games/Gas Powered Games/Supreme Commander Forged Alliance/maps/` |
| `FC` | `my_maps/faf_coop_fort_clarke_assault_M/faf_coop_fort_clarke_assault_M_script.lua` (1667); AI modules `..._m1uefai.lua` etc. in the same folder |
| `X1` | `fa_base/Supreme Commander Forged Alliance/maps/X1CA_001/X1CA_001_script.lua` (2955, retail, `#` comments) |

Important finding on sources: `SCCA_Coop_*` / `X1CA_Coop_*` are not inside any `maps.scd`; they are plain-text map folders under
`MG` (the FAF vault) and `fa_base/.../maps/` holds the retail campaign as loose text files. No archive extraction was
needed for the missions. The FAF coop support API (`GetLeaderAndLocalFactions`, `SetSharedUnitCap`, `PlayerDeath`,
`RemoveRestrictionForAllHumans`, `SimAnnouncement`, ...) is **not** in `faf_repo/fa/lua`; it is a hook mod inside
`lobby_coop.cop` [verified: `grep` of `faf_repo/fa/lua` finds none; zip member list]. Generated missions therefore
depend on that mod (map `type = 'campaign_coop'`, `FC_scenario.lua:4`).

Missions read in full or by structure (script lines in parentheses; scan covered 19 map folders incl. their AI modules):

| Mission | Why chosen |
|---|---|
| `MG/scca_coop_a01.v0017` SCCA_Coop_A01 (1682) | early GPG tutorial-style mission: linear `M1..M7_StartDelay -> _Start` chain, objective groups, unlock chain, `PBM` plan files |
| `MG/SCCA_Coop_E01.v0024` (1060), `scca_coop_a02` (1342) | early missions, plan lists, `EditorFunctions` |
| `X1` + `MG/X1CA_Coop_001.v0030` (3061) | retail 4-stage mission and its coop port; taunts, Protect/CategoriesInArea objectives, faction pick |
| `MG/X1CA_Coop_006.v0024` (2598), `x1ca_coop_003` (1884) | naval AI, ping groups, reactive AI |
| `FC` Fort Clarke Assault modded (1667 + 6 AI modules, `_save.lua` 57521 lines) | **big mission, 10 armies, ~20 bases**, coop, 4 stages, NIS, nukes |
| `MG/faf_coop_prothyon_16.v0020` (2395), `FAF_Coop_Operation_Rebels_Rest` (1536), `..._Red_Revenge` (1698) | community missions: `CustomFunctions`, Timer objectives, random events |
| `MG/Operation (Aeon Ransom)` (241), `my_maps/Operation_Citadel.v0001` (755) | tiny/unfinished community missions (real bugs, see section 5) |
| `X1CA_TUT` (1563) | Camera and ControlGroup objectives |

Method: read the framework API, read 6 missions closely, then counted calls over all 19 folders with
`scratchpad/tools/scan.py` / `opai.py` (regex, comments stripped; counts are lower bounds). **[measured]**: 7,333 calls
into the framework namespaces, 130 distinct targets; the top 10 targets are 59 %, top 30 are 86 %, top 60 are 95 %.
Function names defined in 11 coop/community scripts: `OnPopulate`/`OnStart` 11, `PlayerWin` 10, `KillGame` 9,
`IntroMissionN`/`StartMissionN` 8 each, `MxPxReminderN` 7, `PlayerLose` 6, `PlayerDeath` 6, `IntroMissionNNIS` 6.
A generator therefore removes most of the boilerplate and a small node set covers most content.

---

## 1. Common structure of a mission script

### 1.1 Files of one mission

| File | Role | Evidence |
|---|---|---|
| `<n>.scmap` | terrain | binary, not read |
| `<n>_scenario.lua` | `ScenarioInfo` table: `name, description, type='campaign_coop'\|'campaign', size, map, save, script, norushoffset*_<Army>, Configurations.standard.teams[].armies` | `FC_scenario.lua:1-41` |
| `<n>_save.lua` | `Scenario = { Props, Areas, MasterChain (markers), Chains, Orders, Platoons, Armies }`; armies hold `Units` GROUP trees, `Alliances`, `PlatoonBuilders` | `FC_save.lua:8-6075` |
| `<n>_script.lua` | mission flow (`OnPopulate`, `OnStart`, stage functions) | this document |
| `<n>_<army><stage>ai.lua` | AI modules: BaseManager + OpAI per army per stage | `FC_m1uefai.lua` |
| `<n>_strings.lua` | dialogue tables `{text, vid, bank, cue, faction}` and story comments | `FC_strings.lua:57-126` |
| `<n>_CustomFunctions.lua` | project-local platoon AI / build conditions | `FC_CustomFunctions.lua` |
| `<n>_operation.lua` | 5 lines: `operationData = {key, feedbackURL}` (retail: briefing movies via `operationvars.lua`) | `FC_operation.lua`, `X1CA_001_operation.lua` |

**Army index = position in `Configurations.standard.teams[1].armies`** [verified]: `FC_scenario.lua:36` lists
`Player1, Seraphim, Order, UEF, Aeon, Cybran, Civilians, Player2, Player3, Player4` and `FC:27-36` hard-codes
`ScenarioInfo.Player1 = 1 ... Player4 = 10` by hand. The generator must emit these constants from the army list (no
hand-kept numbers) and re-emit when armies are reordered.

### 1.2 Engine lifecycle (what runs when)

1. `SI:212` `doscript(ScenarioInfo.save, ScenarioInfo.Env)`, `SI:232` `doscript(ScenarioInfo.script, ScenarioInfo.Env)`:
   save and script are executed into the `scenarioEnvironment.lua` module; the script defines **global functions**
   `OnPopulate`, `OnStart` (defaults in `scenarioEnvironment.lua:13-20`).
2. `SI:420-428` `BeginSessionMapSetup`: `pcall(OnPopulate)` then `pcall(OnStart)`. Errors are only `WARN`ed, so a
   crash in `OnPopulate` still runs `OnStart`: **run-from-editor must read the log for WARN lines** [verified].
3. `OnPopulate` cannot wait (no thread); everything timed goes through `ForkThread`.
4. `ScenarioInfo.VarTable` is `{}` from `SI:127`; `ScenarioInfo.UnitNames[army][unitName]`, `.UnitGroups`,
   `.PlatoonHandles` hold script-visible handles (`SI:118-127`). `ScenarioInfo.Options.Difficulty` is 1..3 (lobby
   option key `Difficulty`, values 1/2/3; `Expansion` 'true'/'false'; `CommonArmy` 'true'/'false', `COOP lobbyOptions.lua`).
5. `ScenarioInfo.HumanPlayers` (name -> army index, names starting with `Player`) exists only because of the coop
   mod (`COOP simInit.lua`: `SetupSession`, `OnCreateArmyBrain`); `cinematics.lua:49`, `SO:1018` rely on it.

### 1.3 The skeleton (Fort Clarke, the cleanest modern example)

```
header: imports (FC:9-22), army constants (FC:27-50), AssignedObjectives = {}, Difficulty (FC:52-54), debug flags (FC:66-70)
OnPopulate  (FC:75-159)  world setup, no waiting:
    ScenarioUtils.InitializeScenarioArmies(); colours; SetSharedUnitCap; resource sharing;
    spawn stage-1 bases (AI modules), static groups, initial patrol platoons; SetPlayableArea
OnStart     (FC:161-178)  restrictions, camera to start marker, ForkThread(IntroMission1NIS)
IntroMission1NIS (FC:183-323)  cutscene: EnterNISMode; vision markers; forked reinforcement threads; camera keys; ExitNISMode
IntroMission1 -> StartMission1 (FC:469-591)  objectives + triggers
  objective result callbacks advance the stage:  M1P1:AddResultCallback(IntroMission2)  (FC:515-526)
IntroMission2 (FC:688-800) guard, stage number, new bases/units/ACUs/economy, SetPlayableArea; IntroMission2NIS; StartMission2
IntroMission3, IntroMission4 ... same pattern (FC:1066, 1372)
End: PlayerWin (1606) -> Dialogue(..., KillGame) ; PlayerDeath (1613) ; KillGame (1617) -> ScenarioFramework.EndOperation
Debug hooks OnCtrlF3/F4 ... (FC:1632-1667)  skip-stage helpers
```

Annotated excerpts (all [verified]):

| Pattern | Location | What it shows |
|---|---|---|
| Idempotent stage entry | `FC:688-692` `if ScenarioInfo.MissionNumber == 2 or == 3 then return end; ScenarioInfo.MissionNumber = 2` | A stage can be entered from two sources (objective complete **and** failsafe timer). Every stage function needs this guard. |
| Stage-scoped callbacks | `FC:623-648` (`M1SendPercies`) tests `ScenarioInfo.MissionNumber == 1` before acting and again after the wait | Triggers created in stage N must stop acting when N ends. |
| Failsafe timer | `FC:530-534`, `869-871` `CreateTimerTrigger(IntroMission2, M1MapExpandDelay[Difficulty])` (lobby `Expansion`) ; `FC:1059` `M2P1:ManualResult(true)` | "Advance when objective done **or** after T seconds". Occurs in X1CA_Coop_001 too (`:217`). A compound node. |
| Objective chain by group | `A01:340` `Objectives.CreateGroup('Mission1', M2_StartDelay)`, `A01:361-362` `group:AddObjective(obj)` | Stage ends when all its objectives are done (`SO:200-244`). The best default for "stage complete". |
| Linear drip-feed | `A01:462-520` `M2_StartDelay` -> `CreateTimerTrigger(M2_Start, MissionStartDelay)` -> `Dialogue(..., M2_BuildFactoryObj)` | StartDelay -> Start -> Dialogue -> Objective: a sequence of 4 nodes per stage. |
| Unlock chain | `A01:1555-1665` `BuildCategories1..7` : `AddRestriction(player, categories.ALLUNITS)` then `RemoveRestrictionForAllHumans(...)` per stage | Tech tree as stage-by-stage restriction lists; plus `RestrictEnhancements({...})` (`SF:804`). |
| Intel-triggered objective | `FC:1484-1486` `CreateArmyIntelTrigger(M4AssignSecondPrimary, ArmyBrains[Player1], 'LOSNow', false, true, categories.uel0001, true, ArmyBrains[UEF])` | "When player sees enemy ACU, assign objective". |
| Respawn wave on death | `FC:140-146, 593-606` `CreatePlatoonDeathTrigger(M1SendTitans1, platoon)` whose callback waits `Delay[Difficulty]` and spawns again | Recurring wave; compound node. |
| Proximity ambush with cooldown | `FC:583-586, 623-648` `CreateUnitToMarkerDistanceTrigger(M1SendPercies1, ACU, 'M1_South_Base_Marker', 40)` with a lock flag | Compound node "Ambush on approach". |
| Eco cheat loop | `FC:1024-1030` `while MissionNumber == 2 do GiveResource(...); WaitSeconds(1) end` | Thread loop bound to a stage. |
| Win / lose | `FC:1606-1620` ; `X1:222-279`; coop `PlayerDeath(deadCommander, failureDialogue, currentObjectives)` `COOP SF:136` | Fixed end-game boilerplate. |
| Faction pick (retail) | `X1:403` `RequestPlayerFaction(FactionChosen)`, `SF:101` ; `SF:110` | One-off; coop uses `GetLeaderAndLocalFactions()` (`COOP SF:13`). |
| Reminders | `A01:61-200` `REMINDERS = {M1P1 = {CompletionFlag, Delay, Reminders = {{Delay, Dialogue}}}}`, `COOP SF:217-248` `StartReminders` | Declarative nag-dialogue per objective. |

Three archetypes to support: (a) linear StartDelay chain (A01), (b) Intro/Start pair per stage with `MissionNumber`
guards (Fort Clarke, X1CA_*), (c) event-driven free graph (Aeon Ransom, `AR:152-241`, only objectives -> `IntroP2`).
Archetype (b) is the default generation target; (a) is the special case "stage with one objective".

---

## 2. Catalogue of building blocks (candidate nodes)

Signatures are copied from the source; "n/m" = call count / missions using it **[measured]** over 19 folders.

### 2.1 Event / trigger nodes (flow source, armed when the stage is active)

| Node | Call (signature) | Source | n/m |
|---|---|---|---|
| Timer | `CreateTimerTrigger(callback, seconds, name, doOnTickSecond, onTickSecond)` | `SF:139`, `ST:201` | 516/18 |
| Area (count in rect) | `CreateAreaTrigger(callback, area, category, onceOnly, lessThan, aiBrain, unitCount, requireBuilt, name)`; multi: `CreateMultipleAreaTrigger(callback, areas, ...)` | `ST:72,89` | 35/9 |
| Unit death | `CreateUnitDeathTrigger(callback, unit)` ; killed/reclaimed/captured: `CreateUnitDestroyedTrigger(callback, unit)` | `ST:466`, `SF:306` | 53/13 + 12/8 |
| Group death (all dead) | `CreateGroupDeathTrigger(callback, units, name)` ; N dead: `CreateSubGroupDeathTrigger(callback, units, deadCount, name)` | `ST:232,263` | 2/2 |
| Platoon death | `CreatePlatoonDeathTrigger(callback, platoon)` | `SF:330` | 5/2 |
| Unit near marker | `CreateUnitToMarkerDistanceTrigger(callback, unit, marker, distance, name)` (alias of `CreateUnitToPositionDistanceTrigger`, `SF:432`) | `ST:376` | 26/9 |
| Unit near unit type | `CreateUnitNearTypeTrigger(callback, unit, brain, category, distance, name)` | `ST:413` | 5/2 |
| Unit damaged | `CreateUnitDamagedTrigger(callback, unit, amount, repeatNum)` (amount is a fraction, e.g. .5) | `ST:459` | 24/9 |
| Army stat | `CreateArmyStatTrigger(callback, aiBrain, name, {{StatType=, CompareType=, Value=, Category=}})` stat names `Units_Active`, `Units_Killed`, `Enemies_Killed`, `Economy_Stored_Mass`, ... | `ST:292`, enum `ST:23-47` | 21/9 |
| Army intel | `CreateArmyIntelTrigger(callback, aiBrain, reconType, blip, value, category, onceOnly, targetAIBrain)` | `ST:324` | 11/7 |
| Veterancy | `CreateUnitVeterancyTrigger`, `CreateArmyUnitCategoryVeterancyTrigger(callback, aiBrain, category, level)` | `ST:342,482` | 0 |
| Built / start build / percent built | `CreateUnitBuiltTrigger(callback, unit, category)`, `CreateStartBuildTrigger`, `CreateUnitPercentageBuiltTrigger(callback, aiBrain, category, percent)` | `ST:438-476` | 0-1 |
| Capture / reclaim lifecycle | `CreateUnitCapturedTrigger(cbOld, cbNew, unit)`, `CreateUnitReclaimedTrigger`, start/stop/failed variants | `ST:493-557` | 6/3 |
| Given / stop-being-built / prop | `CreateUnitGivenTrigger`, `CreateUnitStopBeingBuiltTrigger`, `CreatePropKilledTrigger`, `CreatePropReclaimedTrigger` | `ST:561-599` | 0 |
| Threat | `CreateThreatTriggerAroundUnit/Position(callback, aiBrain, unit\|pos, rings, onceOnly, value, greater, name)` | `ST:136,168` | 0 |
| Variable / mission number | `VariableBoolCheckThread(callback, varName, invert, name)`, `MissionNumberTriggerThread(callback, value, name)` | `ST:572,585` | 0 |
| Objective result | `obj:AddResultCallback(function(result) end)` ; progress: `obj:AddProgressCallback(fn)` | `SO` objects | 146/16 |
| Dialogue finished | `Dialogue(table, callback)` runs `callback` after the last line | `SF:715-735` | (931) |
| Hotkey debug | `OnCtrlF3/F4`, `OnShiftF3/F4` global functions | `FC:1632-1667` | 4/4 |

`TRG` (TriggerManager) is a **complete data-driven precedent** [verified]: 28 trigger types
(`TRG:231-295` `TriggerStarter`), 15 action types (`TRG:843-1260`: ChangeArmyAlliance, ChangeArmyColor, ChangePlatoonAI,
DamageUnits, DestroyUnits, FunctionCall, GiveArmyUnits, GiveOrders, KillUnits, LogText, PlayableArea, PlayVO,
PrintText, SpawnGroup, SpawnSubGroup, SpawnUnit), joined by `ActionConditions` (list of lists = OR of ANDs,
`TRG:136-139`). It is instantiated in `SI:88-89` but **no shipped mission uses it** (grep: only
`SF`, `ST`, `simInit`, `TRG` itself) and it has bugs (`ChangeArmyAlliance` reads `params.RelationShip`, `TRG:866`;
`DestroyUnits` uses an undefined `armyIndex`, `TRG:997`; `DamageUnits` reads `params.StartArmyName`, `TRG:940`). Use its trigger/action vocabulary as a naming reference,
do not target it.

### 2.2 Objective nodes (`Objectives = import('/lua/ScenarioFramework.lua').Objectives`, `SF:36`)

Common first four args: `Type` 'primary'|'secondary'|'bonus', `Complete` 'incomplete'|'complete', `Title`, `Description`
(strings or `LOC` keys). Return an objective handle with `.Active`, `AddResultCallback`, `ManualResult(result)`.
`table.insert(AssignedObjectives, obj)` is added so `PlayerDeath` can fail them (`FC:527, 1614`).

| Node | Signature and Target keys | Source | n/m |
|---|---|---|---|
| Kill | `Kill(Type, Complete, Title, Description, Target)`; Target `Units, MarkUnits, Hidden, FlashVisible, ShowProgress` | `SO:265` | 26/9 |
| Kill or Capture | `KillOrCapture(...)`; + `NumRequired` | `SO:444` | 43/13 |
| Capture | `Capture(...)` | `SO:347` | 15/10 |
| Reclaim units / props | `Reclaim(...)` (Units) / `ReclaimProp(...)` (`Wrecks`) | `SO:580,667` | 1/1 each |
| Locate | `Locate(...)` (Units, Wrecks) | `SO:740` | 0 |
| Protect | `Protect(...)`; Target `Units, NumRequired, MarkUnits, FlashVisible, ShowProgress, Timer, PercentProgress, ShowFaction` | `SO:1242` | 15/8 |
| Categories in area | `CategoriesInArea(Type, Complete, Title, Description, Action, Target)`; Target `MarkUnits, MarkArea, ShowProgress, Hidden, Requirements = {{Area, Category, CompareOp, Value, ArmyIndex}}` | `SO:913` | 39/13 |
| Specific units in area | `SpecificUnitsInArea(...)`; Target `Units, Area, NumRequired, MarkUnits, MarkArea, ShowProgress` | `SO:797` | 2/2 |
| Army stat compare | `ArmyStatCompare(Type, Complete, Title, Description, Action, Target)`; Target `Armies={...,'HumanPlayers'}, StatName, CompareOp, Value, Category, ShowProgress, Hidden` | `SO:1051` | 16/4 |
| Unit / category stat compare | `UnitStatCompare`, `CategoryStatCompare` | `SO:1154,1194` | 0 |
| Timer | `Timer(Type, Complete, Title, Description, {Timer=sec, ExpireResult='complete'\|'failed', ShowProgress})` | `SO:1352` | 4/2 |
| Basic (manual) | `Basic(Type, Complete, Title, Description, Image, Target{Units, MarkUnits, Area, MarkArea, ShowFaction})`; icon `Objectives.GetActionIcon('build'\|'kill'\|'move'\|'repair'\|...)` (`SO:2060`) | `SO:1435` | 12/10 |
| Camera / ControlGroup (tutorial) | `Camera(type, state, title, desc, positionTable)`, `ControlGroup(...Target{Requirements={{Category,CompareOp,Value}}})` | `SO:79,124` | 2+1 (TUT only) |
| Group of objectives | `Objectives.CreateGroup(name, userCallback, numRequired)`, `group:AddObjective(obj)` | `SO:200` | 16/6 |
| Query / manual result | `Objectives.IsComplete(obj)` (`SO:2077`), `obj:ManualResult(true\|false)`, `obj.Active` | | 18/6, 84 |
| Ping group | `PingGroups.AddPingGroup(name, blueprintID, type 'move'\|'alert'\|'attack', description)` | `SimPingGroup.lua:13` | 3/2 |

`Armies = {'HumanPlayers'}` is a special token (`SO:1018`, `OtherArmyUnitCountBuildConditions.lua:34`).

### 2.3 Action nodes (flow in -> out)

| Group | Node | Call | n/m |
|---|---|---|---|
| Spawn | Spawn group (units) | `ScenarioUtils.CreateArmyGroup(strArmy, strGroup, wreckage, balance)` -> `units` (`SU:1146`); `wreckage=true` makes wrecks | 398/19 |
| Spawn | Spawn group as platoon | `CreateArmyGroupAsPlatoon(strArmy, strGroup, formation)` -> platoon (`SU:1217`); `..Veteran(strArmy, strGroup, formation, veteranLevel)` (`SU:1279`); formations 'GrowthFormation','AttackFormation','NoFormation','None' | 484/18 + 189/10 |
| Spawn | Spawn single unit | `CreateArmyUnit(strArmy, strUnit)` (`SU:345`) | 247/18 |
| Spawn | Spawn commander | `SpawnCommander(brain, unit, effect 'Gate'\|'Warp'\|false, name\|true, pauseAtDeath, deathTrigger, enhancements)` (`SF:848`) | 88/10 |
| Spawn | Fake gate-in / teleport | `FakeGateInUnit(unit, callback, bonesToHide)` `SF:982`; `FakeTeleportUnit(unit, destroyUnit)` `SF:916` (`FakeTeleportUnits` `:938`) | 2/2 ; 14/7 |
| Orders (platoon) | Move / patrol / attack-move along chain | `PlatoonMoveChain/PlatoonPatrolChain/PlatoonAttackChain(platoon, chain, squad)` (`SF:492-508`); route variants take marker/position lists (`SF:441-475`) | 544/17 (patrol) |
| Orders (group) | Same for unit tables | `GroupPatrolChain/GroupMoveChain/GroupAttackChain(units, chain)`, `GroupFormPatrolChain(units, chain, formation)` (`SF:515-555`) | 191/12 |
| Orders | Random patrol route | `ScenarioPlatoonAI.GetRandomPatrolRoute(ScenarioUtils.ChainToPositions(chain))` (`SPAI:1956`) + `GroupPatrolRoute(units, route)` | 172/15 |
| Orders | raw `IssueAttack/IssueMove/IssueGuard/IssueNuke/IssueTransportUnload/IssueClearCommands/IssueAggressiveMove/IssueFactoryAssist/IssueUpgrade` | engine globals | 107/111/35/49/28/172 |
| Orders | Nuke | `unit:GiveNukeSiloAmmo(n)` + `IssueNuke({unit}, pos)` (`FC:1507-1522`) | 33 |
| Orders | AI tactical/nuke thread on platoon | `ArmyBrains[A]:MakePlatoon('','')`, `AssignUnitsToPlatoon(plat, units, 'Attack','NoFormation')`, `plat:ForkAIThread(plat.NukeAI\|TacticalAI)` (`FC:877-901, 1527-1537`) | 42 |
| Transport | Attach / unload / drop | `AttachUnitsToTransports(units, transports)` (`SF:1529`), `IssueTransportUnload`, `GiveUnitToArmy`; compound "DropReinforcements" `FC:422-467`; AI-driven: `PlatoonAttackWithTransports(platoon, landingChain, attackChain, instant, moveChain)` (`SF:1462`) | 10/7 ; 20/7 |
| Army | Give unit to army | `GiveUnitToArmy(unit, army, triggerOnGiven)` (`SF:277`; coop hook `COOP SF:5` redirects to Player1 with CommonArmy) | 45/11 |
| Army | Give resources / storage | `ArmyBrains[A]:GiveResource('MASS'\|'ENERGY', n)`, `:GiveStorage('ENERGY', n)` | 63 / 19 |
| Army | Unit cap | `SetArmyUnitCap(army, n)` (engine), coop `SetSharedUnitCap(n)` (`COOP SF:97`) | 51 ; 19/11 |
| Army | Alliance / colour / score | `SetAlliance(a, b, 'Ally'\|'Enemy'\|'Neutral')`, `SetArmyColor(a,r,g,b)`, `Set<Faction><Role>Color(army)` (`SF:1302-1434`, 28 presets), `SetArmyShowScore`, `SetIgnorePlayableRect` | 41, 15, ~150, 7, 7 |
| Army | Resource sharing | `GetArmyBrain(a):SetResourceSharing(bool)` (`FC:103`, `A01:249`) | 9 |
| Restrictions | add / remove | `AddRestriction(army, categories)` `SF:1056`; `RemoveRestriction(army, categories, isSilent)` `SF:1074`; coop `AddRestrictionForAllHumans`, `RemoveRestrictionForAllHumans(categories, unlockDialogue, isSilent)` (`COOP SF:29,36`), `RefreshRestrictions(brain)` `COOP SF:47`, `RestrictEnhancements({names})` `SF:804`, `UnrestrictWithVoiceoverAndDelay(cats, VOFac, delay, VO, silent)` `COOP SF:81` | 137/15, 50/8, 28/8, 16/3, 11/6 |
| Map | Playable area | `SetPlayableArea(rect\|areaName, voFlag)` (`SF:1237`) | 81/19 |
| Map | Vision | `CreateVisibleAreaLocation(radius, location, lifetime, armyBrain)` -> VizMarker (`:Destroy()`) `SF:1180`; `CreateVisibleAreaAtUnit(radius, unit, lifetime, brain)` `:1202`; `ClearIntel(position, radius)` `SF:2202` | 126/16 ; 51/12 |
| Map | Kill base / area | `KillBaseInArea(brain, area, category)` `SF:1701` | 2/1 |
| Units | flags | `unit:SetCanTakeDamage/SetCanBeKilled/SetCapturable/SetReclaimable/SetDoNotTarget(bool)`, `SetVeterancy(n)`, `SetCustomName`, `CreateEnhancement(name)`, `AdjustHealth`, `Kill()`, `Destroy()` | 54/80/51/59/40/57/69/64/21/64/114 |
| Units | Unkillable during NIS | `PauseUnitDeath(unit)` `SF:261`; `Cinematics.SetInvincible(area, bool)` `CIN:29` ; `FlagUnkillable(army, exceptions)` `SF:2142` | 27/12 ; 58/12 |
| Dialogue | Dialogue | `Dialogue(dialogueTable, callback, critical, speaker)` `SF:715`; `FlushDialogueQueue()` `SF:739`; `PlayVoiceOver(sound)` `SF:798`; `PlayTaunt(head, taunt)` `SF:759`; `PlayUnlockDialogue()` `SF:748`; `DisplayMissionText(text)` `SF:601`; `SimAnnouncement(text, secondaryText)` `COOP SF:283` | 931/18, 34/9, 0, 0, 16/4, -, 5/5 |
| Dialogue | Taunt manager | `TauntManager.CreateTauntManager(name, stringsFile)` `TMG:403`; `TM:AddTauntingCharacter(unit)`, `AddUnitsKilledTaunt(diag, brain, category, n)`, `AddEnemiesKilledTaunt`, `AddUnitKilledTaunt(diag, unit)`, `AddDamageTaunt(diag, unit, percent)`, `AddUnitGroupDeathPercentTaunt`, `AddStartBuildTaunt`, `AddAreaTaunt(diag, area, category, brain, n)`, `AddTimerTaunt(diag, seconds)`, `AddAttackTaunt(diag, opAI, attacks)`, `AddIntelCategoryTaunt`, `AddCustomTaunt/PlayCustomTaunt`, `Activate(bool)` | 46/13 ; 141 + 89 + 58 |
| Camera / NIS | Enter / exit | `Cinematics.EnterNISMode()` (locks input, `OpEnded=true`, `CIN:212`), `ExitNISMode()` `CIN:224` | 57/16 |
| Camera / NIS | Moves | `CameraMoveToMarker(marker, seconds)` `CIN:73` (needs a `Camera Info` marker), `CameraMoveToRectangle/Area`, `CameraTrackEntity(entity, zoom, seconds)`, `CameraThirdPerson`, `CameraSetZoom`, `CameraSpinAndZoom`, `CameraReset` | 286/15 ; 14/7 |
| Camera / NIS | Canned | `CDRDeathNISCamera(unit, holdTime)` `SF:2084`, `OperationNISCamera(unit, camInfo)` `SF:2072`, `MissionNISCamera`, `EndOperationCamera`, `StartOperationJessZoom` | 48/17, 13/3 |
| Flow | Wait | `WaitSeconds(n)` (threads only), `ForkThread(fn, ...)` | 737, 407 |
| Flow | Random | `Random(a, b)`, `table.random`, event picker `ChooseRandomEvent`, `ChooseRandomBases` (`COOP SF:288-349`, `ScenarioInfo.OperationScenarios['M'..n] = {Bases, Events}`) | 239 |
| End | Win / lose | `PlayerDeath(deadCommander, failureDialogue, currentObjectives)` `COOP SF:136`, `PlayerLose(dialogue, currentObjectives, check)` `COOP SF:182`, `EndOperationSafety(units)` `SF:1773`, `EndOperation(success, allPrimary, allSecondary, allBonus)` `SF:70` | 9, 2, 34/17, 24/17 |
| Misc | Build via named unit | `EngineerBuildUnits(army, unitName, ...)` `SF:2184` | 1 |

Not available from the sim: **music**. Only `UserMusic.lua` (UI side) switches battle/peaceful tracks; there is no
campaign API to start a track, so a "Play Music" node is not supportable without a UI-side hook **[verified: grep of
`SF`, `SimSync`, `simInit`, `UserSync`]**. Sounds are limited to `PlayVoiceOver(sound)`/`SyncVoice({Cue, Bank})` and
unit sounds.

### 2.4 AI nodes

**BaseManager** (`BM`, `import('/lua/ai/opai/basemanager.lua')`): `BaseManager.CreateBaseManager()` is called at module
level (`FC_m1uefai.lua:11-15`) and `:InitializeDifficultyTables(...)` inside a function.

| Node property / method | Signature | Source |
|---|---|---|
| Initialize | `Initialize(brain, baseName, markerName, radius, levelTable, diffultySeparate)`; `InitializeDifficultyTables(brain, baseName, markerName, radius, levelTable)` = same with `true` (groups get `_D<Difficulty>` appended) | `BM:407, 482` |
| Level table | `{GroupName = priority, ...}`; the **group name is independent of baseName and marker**: `FC_m2orderai.lua:23` base `'M2_Order_Main_Base'`, marker `'M2_Main_Base_Marker'`, group `M2_Main_Base` | `BM:424-428` |
| Start | `StartNonZeroBase(engineerNumber, uncapturable)` spawns all groups with priority > 0; `StartBase(groupNames, eng, unc)`, `StartDifficultyBase(groupNames, eng, unc)`, `StartEmptyBase(eng)` (build everything with engineers) | `BM:1266-1332` |
| Engineers | `SetEngineerCount(n \| {total, assist} \| {t1,t2,t3} \| {{t1,t2,t3},{a1,a2,a3}})`; `SetMaximumConstructionEngineers(n)`, `SetConstructionAlwaysAssist(bool)`, `SetPermanentAssistCount(n)`, `SetSupportACUCount(n)` | `BM:907-932, 772-793, 835, 954` |
| Upgrades | `SetUnitUpgrades(upgradeTable, 'DefaultACU'\|'DefaultSACU'\|unitName, startActive)`, `SetACUUpgrades`, `SetSACUUpgrades` | `BM:1064-1170` |
| Functionality toggles | `SetActive(type, bool)` with `Shields, Fabrication, Intel, CounterIntel, TML, Nuke, Patrol, Reclaim, LandScouting, AirScouting`; `BaseActive(bool)` whole base on/off (`FC_m2orderai.lua:859-880`) | `BM:1507-1590` |
| Build toggles | `SetBuild(type, bool)` with `Engineers, AntiAir, GroundDefense, Torpedo, AirFactories, LandFactories, SeaFactories, Factories, MissileDefense, Shields, Artillery, Experimentals, Walls, Defenses, Jammers, Radar, Sonar, Intel, Missiles, Fabrication, AirStaging, MassExtraction, EnergyProduction, Storage`; `SetBuildAllStructures(bool)` | `BM:1598-1775` (used: `'Defenses'` 19, `'Engineers'` 3) |
| Groups over time | `AddBuildGroup(groupName, priority, spawn, initial)`, `AddBuildGroupDifficulty`, `ClearGroupTemplate`, `SpawnGroup(groupName, uncapturable, balance)`, `SpawnGroupAsWreckage` | `BM:639-690, 1229-1262`; delayed group `FC_m1uefai.lua:29-32` |
| Expansion | `AddExpansionBase(baseName, engQuantity, baseData)` (parent sends engineers to child base manager) | `BM:1045`; `FC_m1uefai.lua:300,316,335` |
| Patrol/scout chains | convention: chains named `<Base>_EngineerChain`, `<Base>_AirScoutChain`, `<Base>_LandScoutChain` are picked up automatically; setters `SetDefault*PatrolChain` | `BM:443-453, 977-1018` |
| Buffs | `SetFactoryBuildRateBuff(buffName)`, `SetEngineerBuildRateBuff` | `BM:961,968` |
| Named-unit build (experimental) | `base:AddOpAI('M3_Order_CZAR', {Amount, KeepAlive, PlatoonAIFunction, PlatoonData, MaxAssist, Retry, WaitSecondsAfterDeath, BuildCondition})` (first arg is a unit name in the army) | `BM:548-560`; `X1CA_Coop_001_m3orderai.lua:263-275` |
| Naval / Reactive | `AddNavalAI(name, {MasterPlatoonFunction, PlatoonData, MaxFrigates, MinFrigates, Priority})`; `AddReactiveAI(triggeringType, reactionType, name, data)` (e.g. `'ExperimentalLand','AirRetaliation'`) | `BM:603-637` ; 211 / 170 calls |
| Corpus use | InitializeDifficultyTables 173, Initialize 70, StartNonZeroBase 224, SetActive 130 ('AirScouting' 68, 'LandScouting' 11), AddBuildGroup 61(+15), AddExpansionBase 24, StartEmptyBase 12 | [measured] |

**OpAI** (`base:AddOpAI(ptype, name, data)` -> handle; `BO`): `data = {MasterPlatoonFunction = {file, fn}, PlatoonData = {...}, Priority = n}`
(`BM:38-42` `AddOpAIData`). Methods: `SetChildQuantity(childrenType, quantity)` (`BO:397`), `SetLockingStyle(lockType, lockData)`
('None' 127, 'DeathRatio' 59, 'DeathTimer' 15, 'BuildTimer' 9; also 'RatioTimer'; data `LockTimer`, `Ratio`, `BO:749-788`),
`AddBuildCondition(file, fn, params, bName)` (`BO:548`), `SetChildActive(type, bool)`, `RemoveChildren`, `SetFormation`,
`TargetCommanderLast/Never`, `SetTargettingPriorities`, `AddFormCallback/AddDestroyCallback`, `MasterUsePool`.

| `ptype` (library `OpAI/<ptype>_save.lua`) | Child types seen in `ChildrenType` / used [measured] |
|---|---|
| `AirAttacks` (419 uses) | Gunships 152, AirSuperiority 87, Bombers 63, CombatFighters 60, Interceptors 46, TorpedoBombers 35, HeavyGunships 26, StratBombers 14, LightGunships, HeavyTorpedoBombers, GuidedMissiles |
| `BasicLandAttack` (348) | HeavyTanks 70, SiegeBots 58, MobileFlak 54, MobileMissiles 48, LightArtillery 39, LightTanks 37, MobileShields 35, HeavyBots 31, MobileHeavyArtillery 28, AmphibiousTanks 18, MobileAntiAir 16, LightBots, MobileStealth, RangeBots, MobileBombs, T1-T3Transports |
| `EngineerAttack` (44) | T1Engineers 19, T3Engineers, CombatEngineers, T2Engineers, MobileShields, transports |
| `NavalAttacks` (7) | Destroyers, Battleships, Cruisers, Frigates, Submarines, T2/T3Submarines, NukeSubmarines, Carriers, UtilityBoats, TorpedoBoats, BattleCruisers, MissileShips, AABoats |
| others in `ai/OpAI/` | `AirScout`, `BomberEscort`, `HeavyLandAttack`, `LandAssault`, `LeftoverCleanup`, `NavalFleet`, `lightairattack`, `blank` |

Master platoon functions [measured]: `PatrolChainPickerThread` 389 (`PatrolChains` list), `PatrolThread` 271 (`PatrolChain`
or `PatrolRoute`), `RandomDefensePatrolThread` 91, `LandAssaultWithTransports` 46 (`LandingChain, AttackChain,
TransportReturn, ...`), `RandomPatrolThread` 22, `SplitPatrolThread` 20, `CategoryHunterPlatoonAI` 17
(`CategoryList`), `PlatoonAttackLocation` (`Location`), `MoveToThread` (`MoveChain`), plus map-local ones
(`M3AttackCDRAI`, `HeroFightPlatoonSorianEdit` in `Operation_Citadel`). PlatoonData schema per function is in the
comments of `SPAI:420-535` and `SPAI` per-function (CategoryHunter `SPAI:700`, LandAssault `SPAI:251`).

Build conditions on OpAI, **413 of 440** are one function: `/lua/editor/otherarmyunitcountbuildconditions.lua`
`BrainsCompareNumCategory(aiBrain, targetBrains, numReq, category, compareType)` with `{'HumanPlayers'}` and a
per-difficulty threshold (`FC_m1uefai.lua:79-88`: "start this attack when the humans have >= N units"). Others:
`unitcountbuildconditions.lua` `HaveGreaterThanUnitsWithCategory(aiBrain, numReq, category, idleReq)`,
`miscbuildconditions.lua` `MissionNumber(aiBrain, num)`, `MissionNumberGreaterOrEqual`, `CheckScenarioInfoVarTable(aiBrain, varName)`,
`DifficultyEqual`, `GreaterThanGameTime`; list in `faf_repo/fa/lua/editor/*.lua`. The `ScenarioInfo.VarTable`
mechanism (`A01:217-218, 980-984` writes `ScenarioInfo.VarTable['M7_BeginAirBuild']`) is how a script flag gates an AI
builder: **the "Set Flag" node and the OpAI "Build condition: flag" are one concept**.

Classic (non-BaseManager) AI: `ArmyBrains[A]:PBMAddPlatoon{BuilderName, PlatoonTemplate = {name, 'NoPlan', {unit, min, max, 'Attack', formation}...}, InstanceCount, Priority, PlatoonType 'Land'|'Air'|'Sea'|'Any', RequiresConstruction, LocationType, BuildConditions = {{file, fn, {params}}}, PlatoonAIFunction = {file, fn}, PlatoonData}`
(`aibrains/campaign-ai.lua:421-470`, 464 calls) and `PBMAddBuildLocation(loc, radius, locType)` (`:852`). Mixed with BaseManager
in `Operation (Aeon Ransom)/NomadsaiP1.lua:30-110` (platoons as a "Raw AI builder" row type).

### 2.5 Army setup

Per army (`_save.lua` `Armies[name]`, `FC_save.lua:6072-6200`): `personality` (''), `plans` (path of a plan list, e.g.
`/lua/ai/OpAI/DefaultBlankPlanlist.lua` or a map plan, `A01_uefplanlist.lua`), `color` index, `faction` (0 UEF, 1 Aeon,
2 Cybran, 3 Seraphim; `SU:InitializeScenarioArmies` reads it), `Economy{mass,energy}`, `Alliances{name = 'Ally'|'Enemy'|'Neutral'}`,
`Units` GROUP tree (`INITIAL` auto-spawned group, `WRECKAGE` group auto-spawned as wrecks, `SU:762` and the same code in `InitializeScenarioArmies`, `SU:813-905`),
`PlatoonBuilders`. `InitializeScenarioArmies()` (`SU:813-905`) applies economy, faction, colour, personality,
alliances, `brain:InitializePlatoonBuildManager()`.
Script-side: unit cap `SetArmyUnitCap` (`X1:92-95`), colour presets or `SetArmyColor`, `SetArmyShowScore(i,false)`,
`SetIgnorePlayableRect(i,true)` for AI armies (`X1:208-209`; coop mod does it for non-human armies, `COOP simInit.lua:BeginSession`).
Civilians: an army named `Civilians` with `Neutral`/`Enemy` alliances and walls/cities groups (`FC:705, 1077`).
Coop armies `Player1..Player4` are mandatory siblings: same alliances; commander units for each player are named
units like `UEFPlayer`, `AeonPlayer`, `CybranPlayer`, `Commander` in `Player2` (`FC_save.lua:6138-6170`).

### 2.6 Difficulty branching [measured, Fort Clarke]

Three idioms, all keyed on `ScenarioInfo.Options.Difficulty` (1..3):
1. **Group suffix**: `'M1_Titans_1_D' .. Difficulty` (42 in `FC`), and groups are **cumulatively nested** in the save:
   `M1_North_Base_D3` contains group `M1_North_Base_D2` which contains `..._D1` (`FC_save.lua:48062-48070`);
   `M1_Titans_1_D3` = own units + `M1_Titans_1_D2` (`FC_save.lua:42732-42747`). The editor can derive this nesting from
   a per-unit "minimum difficulty" tag.
2. **Value table index**: `local quantity = {4, 6, 8}; ... quantity[Difficulty]` (6 in `FC`, 17-77 per AI module).
3. **Branch**: `if Difficulty == 3 then ... end` (`X1:689`, `FC:1440`, `FC:1531`).
BaseManager accepts the same triples natively: `StartNonZeroBase({{4, 6, 9}, {2, 4, 6}})` (`FC_m1uefai.lua:25`).

### 2.7 Coop player-count scaling

No shipped mission scales enemy force by the number of players [measured: no `getsize(HumanPlayers)` in the 7 scripts]. Scaling
is indirect: (a) `SetSharedUnitCap(n)` divides the cap among living players (`COOP SF:97-134`); (b) OpAI conditions
compare the **humans' unit counts** (`BrainsCompareNumCategory` `{'HumanPlayers'}`), so more players unlock more attacks;
(c) per-player commander spawn loops over `ListArmies()` for `iArmy >= ScenarioInfo.Player2` (`FC:223-240`,
`A01:281-309`, `X1CA_Coop_001_script.lua:668-681`) with faction-specific ACU names; (d) drop pods per coop army
(`FC:197-218`); (e) `CommonArmy` option redirects spawns/gifts to Player1 (`COOP SF:5-11`, `COOP SU CreateArmyUnit`).
Offer nodes: `Player Count` (data), `For Each Human Player` (flow loop), `Spawn Player Commanders` (compound),
and condition threshold "scale with player count".

---

## 3. Proposed data model

### 3.1 Storage

Graph is **editor data**, separate from the generated Lua:

```
<stem>_mission.lua      data-only Lua table (parseable by map_editor/server/luadata.py, keys sorted like luaser.lua)
<stem>_script.lua       generated stage flow (+ hand regions)
<stem>_ai_<army>.lua    generated bases / OpAI per army (module of FC_m1uefai.lua style)
<stem>_strings.lua      generated dialogue tables (+ preserved story comments)
<stem>_CustomFunctions.lua  Raw Lua library nodes
<stem>_scenario.lua     armies/teams/script paths  (written by the armies panel, not the graph)
<stem>_save.lua         units, groups, markers, chains, areas (owned by the map editor, M2)
```

Rule (MAP_EDITOR_DESIGN section 4): the editor writes the same files the Unity editor does, so the
node graph must be optional; a map with only a hand-written `_script.lua` keeps working.

### 3.2 Document

```
Mission {
  version: 1, stem, opId,
  armies:   [ Army{ name, role: player|coopPlayer|ai|civilian|ally, faction, colorPreset|rgb, personality, plans,
                    unitCap, showScore, ignorePlayableRect, economy, alliances{} } ]   // order = army index
  options:  { difficultyAware: true, coop: true, expansionTimerOption: bool, commonArmySafe: bool }
  variables:[ Var{ name, type: bool|number|string|unit|group|platoon|objective, scope: mission|stage, default } ]
  strings:  [ Dialogue{ key, lines:[{text, vid, bank, cue, faction, delay, duration}] } ]
  bases:    [ Base ]            // section 3.5; global, activated by nodes in stages
  stages:   [ Stage{ id, number, name, color, playableArea?: AreaRef, nodes:[Node], edges:[Edge], frames:[Frame] } ]
  lib:      [ RawFunction ]     // section 4
}
Node  { id (short stable, e.g. "n7f3"), type, label, pos{x,y}, params{...}, key? (script-visible handle, e.g. "M1P1"),
        scope: stage|mission, region: generated|detached }
Edge  { from:{node, port}, to:{node, port} }          // exactly one kind per edge: exec or data
Port  { name, dir: in|out, kind: exec|data, dtype?, many? }
```

Data types (typed ports, colour coded): `Army`, `Brain` (derived), `Unit`, `UnitList`, `Group` (a `_save.lua` group
name), `Platoon`, `Marker`, `Chain`, `Area`, `Category` (expression, see below), `Number`, `PerDifficulty<T>` (a 3-tuple
widget), `Bool`, `String`, `LocKey`, `Dialogue`, `Objective`, `Base`, `OpAI`, `Position`, `Formation`, `Enhancements`.
Implicit conversions: `Unit -> UnitList`, `Group -> UnitList` (via spawn node output), `Platoon -> UnitList`
(`platoon:GetPlatoonUnits()`), `Army -> Brain` (`ArmyBrains[Army]`).
`Category` is a small expression: blueprint ids / classes combined with `+ - *` (`categories.FACTORY + categories.TECH2 * categories.STRUCTURE`).
Authoring UI: picker with blueprint browser and class checkboxes; stored as text and validated by the existing
blueprint index (`find_blueprint`).

### 3.3 Flow semantics

* **Stage tab = one subgraph**. Every stage has two built-in event nodes mirroring the real split (`FC:469-483`):
  `On Enter` (compiled into `IntroMissionN`: spawns, bases, restrictions, then cutscene) and `On Ready`
  (compiled into `StartMissionN`: objectives and triggers). Cross-stage edge = `Start Stage N` action (calls
  `IntroMissionN`), which is idempotent by construction (guard emitted, `FC:688-692`).
* **Event nodes** arm when their stage is active; `once` flag (default true). Output pins: `Fired` (exec), plus data
  pins (`Unit`, `Units`, `Group`).
* **Exec chains** compile sequentially. If a chain contains `Wait`, `Cutscene` or `Dialogue wait` it compiles
  into `ForkThread(function ... end)` (WaitSeconds must be in a thread, CLAUDE.md section 1); otherwise it is a
  plain function body. `Parallel` = several `ForkThread`s; `Sequence` = ordered outputs; `Branch` (Bool), `Switch
  Difficulty` (3 outputs), `Switch Faction` (4), `Once` (flag guard), `Counter` (n-th time), `Random pick`, `Delay`.
* **Stage scope guard**: nodes with `scope=stage` emit `if ScenarioInfo.MissionNumber ~= N then return end` at the
  start of every callback and after each Wait (what `FC:623-648` does by hand).
* **Objective nodes** have exec outputs `On Complete`, `On Failed`, `On Progress (n,total)` and a data output
  `Objective`. Default: auto-registers in `AssignedObjectives` and in the stage's `Objectives.CreateGroup`
  (optional output `All Primary Done`). `Manual Result` and `Is Active/Complete` use the handle.
* **Variables** compile to `ScenarioInfo.<Name>` (visible to AI modules), flags also to `ScenarioInfo.VarTable[...]`
  (so OpAI conditions `CheckScenarioInfoVarTable` can read them).
* **Identifier rules**: node `key` default `S<stage><P|S|B><n>` for objectives (`M1P1`-style: stage, primary,
  index) so generated names look like the originals; functions `S<stage>_<key>_<event>`; no module-level `local`
  beyond imports, army constants and `Difficulty` (hook-style 200-local budget, CLAUDE.md section 2).

### 3.4 Node catalogue for the palette (first cut, about 70 nodes)

Events 16 (section 2.1), Objectives 12 (2.2), Spawn 8, Orders 8, Army/Economy 8 (cap, resources, restrictions,
colour, alliance, give unit, resource sharing), Map/Intel 5, Dialogue/Taunt 6, Camera 6, AI 8 (base, expansion, OpAI,
naval AI, reactive AI, named-unit build, base toggles, base on/off), Flow 10 (wait, sequence, parallel, branch,
switch difficulty/faction, once, counter, random, delay, for-each), Coop 4, End 3, Raw Lua 2.

Compound nodes (a subgraph shipped as one node, ungroupable): **Failsafe Timer Advance** (objective or T seconds,
`FC:530-534`), **Wave Respawner** (`FC:593-606`), **Ambush On Approach with cooldown** (`FC:623-648`), **Drop
Reinforcements** (`FC:422-467`), **Spawn Player Commanders** (`FC:223-240`), **Nuke Barrage** (`FC:1489-1548`), **Economy
Trickle (while stage)** (`FC:1024-1030`), **Unlock Tech with VO** (`COOP SF:69-95`), **Cutscene** (timeline:
EnterNIS, vision markers, camera keys with seconds, parallel threads, ExitNIS; `FC:183-323`, `AR:105-198`).

### 3.5 Base node (derived from a drag-defined base area)

Workflow in the map view: drag a rectangle (or lasso a selection) over placed structures of one army ->
"Define Base". The editor then:

1. creates `Area <Base>_Area` (rect) and marker `<Base>_Marker` (type Blank Marker) at the centre, radius =
   half-diagonal rounded up (`BM` uses radius as "anything within this distance is part of the base", `BM:407`);
2. moves the selected units into group `<Group>_D1` (or `_D1.._D3` nested by their difficulty tags, section 2.6) with
   category sub-groups `Factories / Energy / Mass / Defense / Misc / Walls / Engineers`, the convention in
   `X1CA_Coop_001_save.lua` (`Factories 26, Defense 36, Misc 28, Energy 23, Mass 23`, [measured]); flattening is
   done by the loader (`BM:AddToBuildingTemplate` `BM:1365`) so sub-groups are purely organisational;
3. offers extra "layers" = additional build groups with priority, which is how defence levels work
   (`FC_m1uefai.lua:296-298`: `M1_EB_1_PD2 = 70, M1_EB_1_WL2 = 60, M1_EB_1_PD3 = 50`);
4. creates empty chains `<Base>_EngineerChain`, `_AirScoutChain`, `_LandScoutChain` on request (auto-detected by
   `BM:443-453`).

Base properties (form + generated into `<stem>_ai_<army>.lua`):

| Property | Type | Compiles to |
|---|---|---|
| name, army | string, Army | `CreateBaseManager()` local; `ArmyBrains[Army]` |
| marker, radius | Marker, number | `Initialize(brain, baseName, marker, radius, levelTable)` |
| groups | ordered list `{group, priority, perDifficultyNested}` | `levelTable`; `InitializeDifficultyTables` if nested |
| start mode | NonZero \| Groups(list) \| Empty \| DifficultyGroups | `StartNonZeroBase / StartBase / StartEmptyBase / StartDifficultyBase` |
| engineers | `PerDifficulty<{total, assist}>` | `{{a,b,c},{x,y,z}}` argument |
| max construction engineers, always assist, permanent assist | numbers/bool | `SetMaximumConstructionEngineers / SetConstructionAlwaysAssist / SetPermanentAssistCount` |
| support ACUs, upgrades | number, enhancement lists | `SetSupportACUCount`, `SetUnitUpgrades` / `SetACUUpgrades` / `SetSACUUpgrades` |
| functionality | checkboxes | `SetActive('AirScouting'...)`, `SetBuild('Defenses', false)...` |
| defence level | named group layers + priorities | extra `levelTable` entries / `AddBuildGroup` after delay |
| delayed groups | `{group, priority, delaySeconds, perDifficulty}` | forked `WaitSeconds` + `AddBuildGroup` (`FC_m1uefai.lua:29-32`) |
| patrols / scouts | chains | default chain convention |
| expansions | `{childBase, engineers}` | `parent:AddExpansionBase(childName, n)` |
| attacks | list of OpAI children | section 3.6 |
| experimentals | list of `{unitName, maxAssist, retry, waitAfterDeath, patrolChains}` | `AddOpAI(unitName, {...})` |
| activation | node `Activate Base` in a stage; `Deactivate Base` | call of `<Module>.<Base>AI()`; `BaseActive(false)` (+ platoon disband as `DisableBase`, `FC_m2orderai.lua:859-880`) |
| buffs | names | `SetFactoryBuildRateBuff / SetEngineerBuildRateBuff` |

### 3.6 OpAI child (inside a Base, drawn as sub-nodes or a table)

`{type (AirAttacks...), name, masterFunction, patrol data (chain list), priority, children [{type, quantity PerDifficulty}], locking style + data,
conditions [{fn, params}], formation}` compile to the `AddOpAI`/`SetChildQuantity`/`SetLockingStyle`/`AddBuildCondition`
block of `FC_m1uefai.lua:33-90`. Condition library with typed parameters mirrors `editor/*.lua`
(only `BrainsCompareNumCategory` is needed first). The child-type list per `ptype` is generated by parsing
`ai/OpAI/<ptype>_save.lua` `ChildrenType` (list above), so mod-added OpAI saves appear automatically.

### 3.7 Compile pipeline

`graph -> validate -> IR (per stage: setup block, ready block, handlers) -> emitters` ; the emitter for each node type
is a template with named holes. Output regions are marked (section 4.2). Strings go to `_strings.lua`;
dialogue lines authored in the node inspector (text, optional `vid/bank/cue`, faction) with a speaker unit/character.

### 3.8 Ten representative nodes: compiled output

Assume stage 1, `Difficulty` local, army constants emitted from the army list, `UEF = 4`, strings module `OpStrings`.
Signatures are those in section 2; `callback` arguments are generated functions.

**N1 Timer (event) -> Dialogue (action)**
```lua
-- >>> SCED n1a timer
ScenarioFramework.CreateTimerTrigger(S1_n1a_Fire, 40)      -- CreateTimerTrigger(callback, seconds, name, doOnTickSecond, onTickSecond)
-- <<<
function S1_n1a_Fire()
    if ScenarioInfo.MissionNumber ~= 1 then return end    -- stage scope guard
    ScenarioFramework.Dialogue(OpStrings.S1_Intro, nil, true)   -- Dialogue(dialogueTable, callback, critical, speaker)
end
```
Per-difficulty seconds: `local t = {1200, 900, 600}` and `t[Difficulty]` (`FC:870-871`).

**N2 Area trigger (units of an army left in area)**
```lua
ScenarioFramework.CreateAreaTrigger(S1_n2_Fire, ScenarioUtils.AreaToRect('M1_North_Base_Area'),
    categories.AEON * categories.CONSTRUCTION, true, true, ArmyBrains[Order])
-- (callback, area, category, onceOnly, lessThan, aiBrain, unitCount, requireBuilt, name) ; X1:684
```
`lessThan=true` with no `unitCount` fires when none are present (`ST:93-125`).

**N3 Spawn group as platoon + patrol chain (difficulty-suffixed group)**
```lua
local platoon = ScenarioUtils.CreateArmyGroupAsPlatoon('UEF', 'M1_Titans_1_D' .. Difficulty, 'GrowthFormation')
ScenarioFramework.PlatoonPatrolChain(platoon, 'M1_Titan_Chain_1')       -- FC:140-141
ScenarioInfo.S1_Titans = platoon                                         -- optional data-out
```

**N4 Kill objective with progress, stage advance on complete**
```lua
ScenarioInfo.M1P1 = Objectives.Kill('primary', 'incomplete', OpStrings.M1P1Title, OpStrings.M1P1Desc,
    { Units = ScenarioInfo.S1_Targets, MarkUnits = true, FlashVisible = true, ShowProgress = true })   -- SO:265
ScenarioInfo.M1P1:AddResultCallback(function(result)
    if result then IntroMission2() else PlayerLose() end                  -- exec out pins
end)
table.insert(AssignedObjectives, ScenarioInfo.M1P1)
```

**N5 Categories-in-area objective (destroy all factories in two areas)**
```lua
ScenarioInfo.M1P2 = Objectives.CategoriesInArea('primary', 'incomplete', OpStrings.M1P2Title, OpStrings.M1P2Desc, 'kill',
  { MarkUnits = true, Requirements = {
      { Area = 'M1_UEF_North_Base_Area', Category = categories.FACTORY, CompareOp = '<=', Value = 0, ArmyIndex = UEF },
      { Area = 'M1_UEF_South_Base_Area', Category = categories.FACTORY, CompareOp = '<=', Value = 0, ArmyIndex = UEF } } })  -- FC:489-514
```

**N6 Restrictions + unit cap (stage setup)**
```lua
ScenarioFramework.AddRestrictionForAllHumans(categories.EXPERIMENTAL + categories.SUBCOMMANDER)   -- COOP SF:29
ScenarioFramework.RemoveRestrictionForAllHumans(categories.EXPERIMENTAL, true)                    -- COOP SF:36 (unlockDialogue)
ScenarioFramework.SetSharedUnitCap(1500)                                                          -- COOP SF:97
ScenarioFramework.SetPlayableArea('M2_Playable_Area', false)                                       -- SF:1237(rect|name, voFlag)
```

**N7 Cutscene compound (thread)**
```lua
function S1_Cutscene()
    Cinematics.EnterNISMode()                                               -- CIN:212
    local v1 = ScenarioFramework.CreateVisibleAreaLocation(110, 'M1_Vis_1_1', 0, ArmyBrains[Player1])  -- SF:1180
    Cinematics.CameraMoveToMarker(ScenarioUtils.GetMarker('Cam_1_2'), 18)   -- CIN:73 marker, seconds
    WaitSeconds(4)
    Cinematics.CameraMoveToMarker(ScenarioUtils.GetMarker('Cam_1_3'), 14)
    v1:Destroy()
    Cinematics.ExitNISMode()                                               -- CIN:224
    StartMission1()                                                         -- exec out "Done"
end   -- called through ForkThread(S1_Cutscene) from IntroMission1 (FC:177, 183-285)
```

**N8 Base (module `<stem>_ai_uef.lua`) + Activate Base**
```lua
local BaseManager = import('/lua/ai/opai/basemanager.lua')
local UEFM1NorthBase = BaseManager.CreateBaseManager()
function UEFM1NorthBaseAI()
    UEFM1NorthBase:InitializeDifficultyTables(ArmyBrains[UEF], 'M1_North_Base', 'M1_North_Base_Marker', 25, {M1_North_Base = 100})   -- BM:482
    UEFM1NorthBase:StartNonZeroBase({{4, 6, 9}, {2, 4, 6}})                                                                           -- BM:1266
    UEFM1NorthBase:SetActive('AirScouting', true)                                                                                     -- BM:1507
    UEFM1NorthBase:SetBuild('Defenses', false)                                                                                        -- BM:1598
    UEFM1NorthBase:AddExpansionBase('M1_Expansion_Base_1', 1)                                                                         -- BM:1045
end   -- stage script: M1UEFAI.UEFM1NorthBaseAI()  (FC:108)
```

**N9 OpAI child with per-difficulty quantity, human-count condition and chain picker**
```lua
local opai = UEFM1NorthBase:AddOpAI('BasicLandAttack', 'M1_NorthLandAttack1',
    { MasterPlatoonFunction = {SPAIFileName, 'PatrolChainPickerThread'},
      PlatoonData = { PatrolChains = {'M1_North_Land_Attack_Chain_1', 'M1_North_Land_Attack_Chain_2'} },
      Priority = 100 })                                                       -- BM:548 / BO AddOpAIData
opai:SetChildQuantity({'LightArtillery', 'LightTanks'}, ({6, 6, 8})[Difficulty])   -- BO:397
opai:SetLockingStyle('None')                                                       -- BO:749
opai:AddBuildCondition('/lua/editor/otherarmyunitcountbuildconditions.lua', 'BrainsCompareNumCategory',
    {'default_brain', {'HumanPlayers'}, ({10, 6, 4})[Difficulty], categories.ALLUNITS - categories.DEFENSE, '>='})   -- BO:548; FC_m1uefai.lua:87-88
```

**N10 Win / lose / end**
```lua
function PlayerWin()
    if not ScenarioInfo.OpEnded then
        ScenarioInfo.OpComplete = true
        ScenarioFramework.Dialogue(OpStrings.PlayerWin, KillGame, true)       -- FC:1606-1611
    end
end
function PlayerDeath(deadCommander) ScenarioFramework.PlayerDeath(deadCommander, nil, AssignedObjectives) end   -- COOP SF:136
function KillGame() UnlockInput(); ScenarioFramework.EndOperation(ScenarioInfo.OpComplete, ScenarioInfo.OpComplete, true) end -- SF:70 (success, allPrimary, allSecondary, allBonus)
```

### 3.9 `_scenario.lua` / `_save.lua` entries the graph/armies panel writes

* `_scenario.lua`: `type = 'campaign_coop'`, `script = '/maps/<stem>/<stem>_script.lua'`, `norushoffsetX/Y_<Army>` for
  every army, `Configurations.standard.teams = {{name='FFA', armies={...}}}` in index order (`FC_scenario.lua:7-41`).
* `_save.lua`: `Armies[x].{personality, plans, color, faction, Economy, Alliances}`; areas (`RECTANGLE`), markers
  (`Blank Marker 450`, `Camera Info 14` with `zoom, canSetCamera, canSyncCamera` and orientation, `Rally Point 37`,
  `Mass 104`, `Hydrocarbon 7` in `FC_save.lua`), `Chains[name].Markers = {names}`.
* Graph-owned references are by **name**: a node referencing a missing area/marker/chain/group is a validation error,
  never a generated `error()` at runtime (`SU:AreaToRect` message does not even include the name, `SU:230-240`).

---

## 4. What is hard to express as nodes, and the escape hatch

| Hard case | Evidence | Treatment |
|---|---|---|
| Thread loops with state (while stage, `repeat ... until`) | `FC:1024-1030`, `FC:1336-1348` (`while v:IsUnitState('Moving')`), `A01:1419-1450` | Compound nodes for the 5-6 common loops; otherwise Raw Lua in a forked function node |
| Cross-stage mutable state, counters | `A01:204-215` `M7_AirPatrolCount`, `FC:580-581` lock flags, `ScenarioInfo.M1Percies1Locked` | `Variable` nodes with `Get/Set/Increment/Compare`; stored on `ScenarioInfo.*` so AI modules see them |
| Index math over unit lists (nuke 1..8 delays) | `FC:874-916` (`UEFTacNuke[1]..[8]`, no bounds check) | `For Each (with delay)` loop node: collapses 40 repeated lines, adds bounds |
| Custom platoon AI functions / build conditions | `FC_CustomFunctions.lua`, `Rebels_Rest_CustomFunctions.lua:1-20`, `Operation_Citadel/platoon.lua` (1393 lines) | Raw Lua library file; the node references `{file, fn}` as `MasterPlatoonFunction`; doc-comment convention below |
| Brain-API pokes (`MakePlatoon`, `GetPlatoonUniquelyNamed`, `PBM*`, `ArmyBrains[x]:GetListOfUnits`) | corpus method counts (GetListOfUnits 235, MakePlatoon 143, PBMAddPlatoon 464) | Provide `Get Units (army, category, area?)` node; PBM rows as a table node; the rest Raw Lua |
| Dynamic names (`'M1_Titans_' .. i .. '_D' .. Difficulty`, `'NIS_Tanks_' .. i`) | `FC:129-151, 329-341` | `For i = a..b` loop node with a string-template parameter, validated for every expansion |

### 4.1 Raw Lua node

Two forms: (a) **Inline statement block** with declared inputs/outputs (typed pins become local variables in scope:
`units`, `army`, `Difficulty`, `stage`), its text emitted verbatim inside the node's region; (b) **Library function**
in `<stem>_CustomFunctions.lua` (an ordinary module, so `import()`ed once) with a header comment the editor parses to
make pins, exactly the convention the original GPG editor used and that community maps still carry:

```lua
--  function: MoveChainPickerThread = AddFunction
--      parameter 0: string: platoon = "default_platoon"     (Rebels_Rest_CustomFunctions.lua:6-9)
```
Extend it with `parameter N: Type name = default` so library functions become nodes automatically (types from section 3.2).
Lua is the Moho dialect (5.0): the node editor's Lua editor runs the repo validators
(`scripts/validate_lua_syntax.py`, `check_hook_integrity.py`) on every Raw block before accepting it
(CLAUDE.md section 5), flags `^`, `#` length, `%`, `...`, writes into nil tables, `WaitSeconds` outside a thread, and
`WaitSeconds` inside `pcall`.

### 4.2 Round-trip policy (recommended)

1. **Regions**. Generated text lives between marker comments (Lua 5.0 safe line comments only):
   `-- >>> SCED:<regionId> hash=<8 hex>` ... `-- <<< SCED:<regionId>`; one region per node-chain function, per base, per
   header. Everything outside regions (comments, helper functions, `OnCtrlF3`) is **preserved byte for byte**. User
   regions use `-- >>> USER:<name>` / `-- <<< USER:<name>` and are never touched; new files start with empty ones at
   file end and after each stage.
2. **Detection on load**: recompute each region hash. Match = unchanged. Mismatch = "edited by hand". The graph also
   stores the last generated text per region (`generated_snapshot`), so a 3-way diff (snapshot, current, regenerated)
   is possible.
3. **Resolution** (per region, never silent): *Keep generated* (discard the edit), *Detach* (the region becomes a
   Raw Lua node carrying the edited text, pinned at the same place; graph nodes that used to produce it are marked
   `detached` and skipped), *Merge* (3-way diff view). Regions found without a graph node become Raw Lua nodes
   ("orphan region").
4. **Unrecognised scripts** (hand-written, no regions): offered only as "Adopt": the whole file becomes one
   read-only legacy region; a token scan lists the area/marker/chain/group/unit names it references (string
   literals matching names in `_save.lua`) so validation and renaming still work. Auto-lifting arbitrary Lua into
   nodes is out of scope. A later "Lift known idioms" pass can match the 12 canonical patterns (section 1.3) because
   the corpus uses them verbatim, but this is not part of the first milestone **[inferred]**.
5. **Renames**. Renaming an area/marker/chain/group/unit in the map editor offers a graph rewrite; regenerated
   regions follow, Raw Lua regions are searched and listed (not rewritten) with a "rewrite string literals" button.
6. **Diff hygiene**. Deterministic output (sorted keys in `_mission.lua`, stable node ids, stable function order
   by stage then node `pos`), so git diffs of generated Lua are readable; header line
   `-- Generated by FAF Studio vN; graph hash <hash>`.
7. **Stage files vs one file**: emit `_script.lua` (flow) and one `_ai_<army>.lua` per army (as every real mission
   does, 2-6 AI modules); keep the one-file option for small missions.

---

## 5. Editor features around unit placement for mission design

### 5.1 Placement and editing (map side, M2)

* **Named units**: scripts address single units by their save name (`ScenarioInfo.UnitNames[army]['MexToUpgrade1']`,
  `FC:119, 347`; `ScenarioUtils.CreateArmyUnit(army, name)` `SU:345`). Inspector field `Script name`; auto-names
  `UNIT_nnnn` are fine for group members (`FC_save.lua:48070` onward).
* **Groups**: tree with nesting (`GROUP{Units={...}}`), ownership per army, drag between groups, "make group from
  selection", rename with reference check, group visibility toggles, group colour in the viewport.
  Special groups `INITIAL` (auto-spawn at start, `SU:503`) and `WRECKAGE` (auto-spawn as wrecks, `SU:762`).
* **Difficulty tags**: per unit/group "present from difficulty 1/2/3"; the editor writes the cumulative `_D1 > _D2 > _D3`
  nesting (section 2.6) and a viewport filter "show difficulty n". Preview toggles: show D1 only, D2, D3.
* **Army reassignment** of a selection (moves units between `Armies[x].Units`, keeps positions; warns if the group is
  referenced by a node of the old army), "convert army to Neutral/Civilians".
* **Grids and snapping**: 1 unit = 1 ogrid; structures snap to the build grid by footprint (blueprint
  `Physics.SkirtSizeX/Z`), unit snaps to terrain height; `Position` is stored as world coordinates (`FC_save.lua:6140`).
  Rotate by 90 degrees step; mirror/rotate symmetry shared with the terrain tools.
* **Formations and spawn shapes**: place N units of a type in line/column/wedge/grid/circle, spacing field; "paint
  group" along a drawn path; random scatter with min distance (for civilian cities, wreck fields, `FC` walls).
* **Base templates**: save selected structures as a reusable template (blueprint ids + offsets + sub-group tags; the vault already carries such files,
  `Mission_3_-_Withered_Fields.v0001/*.scunits`, format not opened **[inferred]**) and stamp it with faction
  conversion (UEF `ueb*` -> Aeon `uab*` -> Cybran `urb*`, equivalents from `BuildingTemplates`), rotation and army;
  "Define Base" from a dragged area (section 3.5). Template library per user plus a few shipped bases (main,
  forward, naval, air, defence ring).
* **Patrol-chain drawing**: click-to-add markers into a chain; chains are ordered lists of markers (`FC_save.lua:4864`
  onward `Chains[name].Markers`); draw as arrows with numbers, loop flag display, insert/split/reverse, "one marker in
  several chains" allowed (`SU:195-207 FindParentChain`); naming helper by convention (`<Base>_EngineerChain`,
  `<Stage>_<Army>_<Role>_Chain_<n>`); chain tags land/air/naval to run a path check.
* **Camera markers**: `Camera Info` marker with zoom and heading from the current view ("capture camera"), key order
  preview in the cutscene node (play the camera path in the viewport).
* **Areas** as named rectangles with a colour and a purpose tag (objective area, playable area, base area, trigger
  area); a playable-area chain `M1 < M2 < M3 < M4` check that each stage area contains the previous (map expansion).
* **Playtest**: "Run from this stage" (injects `ScenarioInfo.MissionNumber` and calls the stage's `IntroMissionN`),
  "skip stage" debug hotkeys auto-generated (`FC:1652-1664`), resource cheat, difficulty/coop count selectors.

### 5.2 Validation catalogue (static unless marked runtime)

Real findings from the corpus show each check is worth building:

| Check | Real instance |
|---|---|
| Stage never started (dead stage) | `Operation (Aeon Ransom)_script.lua:152` `MissionP1` defined, never called anywhere; `IntroP2` (`:197`) has no objectives |
| Callback/function referenced but not defined | `AR:112-130` passes `PlayerDeath` (never defined in the file) to `SpawnCommander` |
| Wrong argument list to framework call | `AR:130` `CreateArmyUnit('Player4','Commander','Warp',true,true,PlayerDeath)` (the function takes 2 args) |
| Duplicate/identical requirements | `AR:167,174` two `CategoriesInArea` requirements with the same area and army |
| Objective with no trigger/result handler | stage objectives without `AddResultCallback` or without successor (e.g. `FC:551-569` secondary has handler only for vision) -> warn "objective never influences flow"; primary with no path to `Win` |
| Debug flags left on | `AR:25` `local Debug = true`, `FC:66-70` Skip flags |
| Undeclared globals | `FC:201` `coop = 1`, `FC:228` `factionIdx` (global leak; Lua 5.0 globals are shared across the mission env) |
| Unit-list index out of range | `FC:879-915` `UEFTacNuke[1..8]` without count check (crash if the map has fewer silos) |
| Missing group/area/marker/chain/unit name | e.g. `'M1_Percies_1_D' .. Difficulty` must exist for D1, D2 and D3 (`FC:633`); check every difficulty expansion |
| Difficulty coverage | a `_D1` group without `_D2/_D3` nesting; `quantity[Difficulty]` tables with fewer than 3 entries |
| Army index drift | `FC:27-36` constants vs `Configurations` order; coop armies `Player2-4` missing alliances |
| Units off-map / outside playable area of the stage that spawns them | stage `SetPlayableArea` vs unit positions (AI units may exist off-map only with `SetIgnorePlayableRect`, set for AI armies by the coop mod) |
| Units on unpathable/blocked ground, structures overlapping | live sim path/buildability checks (already available in the editor sim per MAP_EDITOR status) |
| Missing blueprints / mod units | unit type ids not found in vanilla + mod list (`find_blueprint`); restrictions listing unknown ids (`A01:1555-1665` style lists) |
| Category expression invalid | parse `categories.xyz` tokens against blueprint index (e.g. `categories.zeb9501`, `FC:352`) |
| `WaitSeconds` outside thread / inside `pcall` / in `OnPopulate` | Lua check on Raw nodes (`SI:420-428` only warns at runtime) |
| Trigger leaks | stage-scoped event without stage guard; timer created in a loop without guard; objective without `AssignedObjectives` entry (cannot fail on death) |
| Coop | no Player2-4 ACU entries; `ScenarioInfo.HumanPlayers` used without coop mod type; `CommonArmy` incompatible calls (`CreateArmyUnit('Player2'..)`) |
| Unused things | groups, chains, markers, areas never referenced by any node/base/script (heavy: `FC_save.lua` has 450 blank markers) |
| AI | base `radius` smaller than distance of its farthest unit; `levelTable` group missing for a difficulty; OpAI patrol chain missing; OpAI `ptype` child name not in `<ptype>_save.lua`; a base started but never deactivated at the end; expansion base with no engineers; BM unit names duplicated across armies |
| Runtime (play-test harness) | parse sim log after a headless run for `WARN`/`*AI ERROR`/`SCENARIO UTILITIES WARNING` strings (`SU:1146-1166 error(...)`, `SI:421-428` pcall), count spawned vs expected units per group, measure time-to-first-objective |

---

## 6. Recommendations and open items

1. **Build order** inside M6: (1) armies panel + `_scenario.lua` + constants; (2) stage skeleton + timers + spawn/orders
   + dialogue + win/lose + restrictions (covers about 60 % of calls, the top 10 targets in section 0); (3) objectives and
   cutscene compound; (4) Base + OpAI nodes (most lines of a big mission live here: `FC` AI modules are about 4,600 of 6,390 lines);
   (5) validation panel; (6) Raw Lua + round trip.
2. Treat **the AI modules as data-first**: a table UI (base -> OpAI rows with per-difficulty cells) beats a node canvas
   for 1,638 `AddOpAI` calls in the corpus; nodes stay for flow.
3. **Do not generate TriggerManager code**; target `ScenarioFramework` / `Objectives` as real missions do.
4. Generated missions require the **FAF coop support mod** for `campaign_coop` (`HumanPlayers`, `SetSharedUnitCap`,
   `PlayerDeath`). Add a check that the editor's play-test mounts `lobby_coop.cop` **[open: how the editor's
   `init_editor.lua` mounts it; coop `mod_info.lua` has `selectable = false`, mountpoints lua/units]**.
5. Open: music (no sim API), localisation (`LOC` keys vs plain text; FC uses plain English), units with
   `Orders`/`Platoons` templates in `_save.lua` (`Scenario.Platoons`, `Scenario.Orders`, empty in all sampled maps; not
   needed), `Props` in save, `operation.lua` briefing integration (campaign UI only).
6. Extracted artefacts (scratchpad, regenerate if needed): `coop/` (text members of `lobby_coop.cop`), `scan.json`, `tools/scan.py`, `tools/opai.py`.
