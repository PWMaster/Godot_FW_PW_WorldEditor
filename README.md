# PWE-Manager – Forsaken World in Godot

A fan project that brings the MMORPG *Forsaken World* (Angelica engine) to **Godot 4.7**:
an editor plugin that reads the original game data, plus a playable client/server game built on top of it.

> **No game assets are included.** You need your own copy of the original game client;
> all data is read from it at import time or at runtime.

## PWE-Manager (Godot editor plugin)

- **Reads the original client directly**: opens the game's `.pck` archives through a virtual file system,
  with no unpacking needed (including Chinese GBK-encoded file names and texts).
- **Models & animations**: characters, NPCs, monsters and equipment become Godot scenes with
  skeletons, animations, attachment points and animation events.
- **Visual effects**: the game's particle effect files are rebuilt as Godot nodes and shaders,
  with a preview player.
- **Maps**: terrain, buildings, water, lighting, ambient sounds and monster spawns are imported into one scene,
  along with the navigation data for pathfinding.
- **User interface**: the game's dialog layouts are rebuilt as Godot UI (textures, fonts, both UI skins).
- **Game data readers**: item and NPC database, quests, skills and status effects, plus a small
  interpreter for the client's compiled Lua scripts.
- **Data check**: compares client and server data (versions, quests, maps, spawns).

## The game (client + server, written in GDScript)

- **Own server**: encrypted networking, SQLite database, accounts with salted password hashing,
  and a server control panel inside the editor.
- **Login & character creation** in the original look, covering all races and classes, appearance options
  and a 3D preview.
- **Open world**: explore the starting map with other players, NPCs and roaming monsters;
  minimap, chat, and target selection by click or Tab.
- **Original HUD**: character and target frames, hotbars, skill window, inventory, character sheet,
  quest log and quest tracker, with two switchable UI skins.
- **Quests** from the original quest data: NPC dialogues, kill and collect objectives, rewards,
  and auto-pathing to quest NPCs and locations.
- **Inventory & equipment**: equipped weapons and armor appear on the character; gathering; item tooltips.
- **Combat**: auto-attack with the original damage formula, hits, crits and misses, monster AI
  (aggro, chase, return home), death and revival, experience and level-ups.
- **Skills**: cast bar, mana costs, cooldowns and range checks; values come from the original skill
  formulas; skill animations and effects.
- **Status effects**: buffs and debuffs (damage and healing over time, stat changes, stacking rules),
  shown as icons with timers and tooltips plus visual effects on the character.
- **Languages**: German, English and French.

## What this fork adds

- **Perfect World 1.5.5 support**: adds a matching data profile and import tools for playable character roles and class templates from the server's `ptemplate.conf`.
- **On-demand world streaming**: loads terrain, buildings and nearby map objects from the original client data as you move, instead of requiring a fully prebuilt map scene. A free camera can inspect the streamed world independently of the character.
- **Legacy character models**: supports older `.ski` v8 skin files and fallback model paths used by PW 1.5.5 characters.
- **More reliable local server workflow**: improves server shutdown and process monitoring, and includes tests for login, world interactions, restarts and reconnects.

## Getting started

1. Install **Godot 4.7** and the SQLite GDExtension
   [sqlite3.gd](https://github.com/Yeicor/sqlite3.gd) into `addons/sqlite3.gd/`.
2. Copy your original *Forsaken World* client into `Stock-PWE-Client/` (the `.pck` files stay packed),
   and your server files into `Stock-PWE-Server/` (both folders are ignored by Godot and git).
3. Open the project. The **PWE-Manager** docks appear in the editor: import a map (e.g. the starting map `s9`)
   with the ECM-GFX-MAP dock.
4. The game server needs data tables (`addons/PWE-Manager/Server/*.json`) that are generated from your own
   client and server files with the scripts in `addons/PWE-Manager/tools/server_data/`
   (usage is described at the top of each script).
5. Start the server from the SERVER dock, then run the project to log in and play.

## Testing

An automated test suite (bots, UI-driven world tests, server restart/reconnect tests and a load test with 25 bots)
runs headless and with the Vulkan and OpenGL renderers.

## Status

Work in progress. Next up: crowd-control effects (stun, root, silence), the remaining class skills,
skill learning, monster skills and talents.

## Screenshots

<img width="1400" height="600" alt="GFX editor" src="https://github.com/user-attachments/assets/e9de8fd2-4dd6-4667-a52b-757088faa872" />

<img width="1000" height="1200" alt="GFX element properties" src="https://github.com/user-attachments/assets/e21b6dcd-f057-4037-92ab-7afc9e71dd1e" />

<img width="1920" height="1040" alt="Editor overview" src="https://github.com/user-attachments/assets/219eba5d-c5c7-43c4-b38d-44e000333331" />

<img width="895" height="519" alt="UI dialog (XML) view" src="https://github.com/user-attachments/assets/6ee0b583-80fb-4f85-ad94-bb1756ebe38c" />

## Disclaimer

Non-commercial fan project. Not affiliated with or endorsed by Perfect World or its subsidiaries.
*Forsaken World* and all related names are trademarks of their respective owners.
