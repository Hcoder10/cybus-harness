- LevelKit (LV = require(ReplicatedStorage.Kit.LevelKit); server or edit mode; also WorldKit2.level(kind, opts)): a WHOLE
  level in one call -- start every world with it, then customize on top. Deterministic for a seed.
- LV.build(kind, {look="toon_bright", seed=7, scale=1, islands=4, difficulty=1..4, arc=200, palette={role=Color3},
  lookOverrides, applyLook=true, parent=workspace.StudioWorld, name="Level", clearTerrain=true, style, blocks, spawns}) -> info
  kinds: "sky_islands" (3D platformer: a big hub island the player spawns ON, `islands` more rising in an arc around it,
  the last one the Crown island; stepping-platform paths between them; sea + cloud puffs far below) | "meadow_course"
  (the same plateaus + paths in a grassy valley ringed by hills; falling lands on the valley floor) | "arena" (WorldKit2.arena
  + ground, hills, dressing outside the walls) | "town" (WorldKit2.town + ground, trees at the edges).
  It applies the look (LookKit.apply), WIPES Terrain and any old `name` folder, builds, and claims the SpawnLocation onto
  solid ground. Dressing (look-matched trees, bushes, flowers, rocks, lamps flanking every path end) sits in clusters at
  island rims, never on the spawn, the walking lines or the paths.
- info = {kind, look, folder, spawn=Vector3, islands={{name, top=Vector3, center, radius}} (hub first), courses={{from, to,
  platforms={Vector3}, model}}, checkpoints={Vector3}, collectibles={Vector3} (coins), goals={Vector3} (stars), goal=Vector3
  (Crown star), hazards={{kind="thorns", part, position, radius}}, bounds={min, max}, arena?, spawns? (arena CFrames), town?}.
  LV.describe(info) -> readable summary string (print or return it from studio_build).
- Tags it sets (CollectionService): KitCheckpoint (Index; hub = 1 at the spawn) -> GameplayKit Checkpoints.new({parts=...});
  KitCoin (Value) on coins arcing over every jump and ringing each star; KitGoal (Island, Final) on each island's star;
  KitHazard (Damage) on thorn-patch touch parts -> GameplayKit Hazard.kill/zone(part); KitSpawn on the SpawnLocation;
  KitMover (difficulty >= 2) / KitCrumble (>= 3) on path platforms -> call WorldKit2.animate() once at runtime.
- Jumps are player-scale and never scaled: platform edge gaps ~4.6..8 studs by difficulty, rises <= 3.5 per jump.
- Customize, don't rebuild: add a landmark near info.islands[1].top, swap a star for your own goal, add props with
  WorldKit2.prop(kind, {position = WorldKit2.groundAt(x, z)}). Calling build again replaces the whole level.
Example: local info = LV.build("sky_islands", {look = "candy", seed = 3, islands = 5}); print(LV.describe(info))
