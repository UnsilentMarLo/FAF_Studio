# Mission basics
summary: Armies, stages, objectives and triggers without writing a script.
keywords: mission, campaign, stage, objective, trigger, armies, alliances, bases, cutscene, dialogue, strings, run, play test, node, script

Missions are made in the Mission workspace. The mission is compiled into the map script when the map is saved (the part between the EDITOR MISSION marker lines), so you can keep editing the rest of the script by hand.

## Set up

1. File > Map info...: set the map type to campaign so that the other armies get the campaign brain (without it they are passive).
2. Armies panel: the list of armies, their faction, colour, economy and, on the Alliances page, who is enemy, ally or neutral towards whom. Click a row to cycle the state; "Both ways" sets the other side as well.
3. Place the units of each army with the Unit tool (Objects or Mission workspace). Groups keep units together for orders and triggers.

## Stages and nodes

1. Stages panel: Add stage creates a stage; Up and Down reorder them; Remove deletes one.
2. A stage runs its enter nodes first, then its ready nodes. All objectives of a stage must be done before the next stage starts, or its failsafe timer runs out.
3. Add node adds an action or a trigger to the selected stage. Triggers (timer, group destroyed, unit killed, units in an area, objective decided) hold child nodes: select the trigger and use Add inside. Edit... changes the parameters of the selected node.
4. Bases panel: define a base from an area, with AI that builds and attacks. Strings panel: the dialogue lines the "Play a dialogue" node uses.

## Test it

F5 starts a test run. The Run panel shows the stage, objectives, flags and warnings the script raised, lets you jump to a stage, set flags and skip timers. Stop returns to the editor.

## Release

Validation and File > Release map... include the mission checks.
