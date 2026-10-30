- WorldKit2 (W = require(ReplicatedStorage.Kit.WorldKit2); server or edit mode): genre-general worlds. Every WorldKit.* call
  also works through W (W.lighting, W.island, W.water, ...). Call LookKit.apply(look) first: colours come from LookKit.palette;
  every builder also takes palette={role=Color3} and seed. Everything is anchored; tiny bits cast no shadow; decor never collides.
- W.prop(kind, {position, rotation=deg, cframe?, scale=1, color, palette, seed, parent, ...}) -> Model (PrimaryPart set; pivot =
  ground centre, front faces -Z). Kinds (W.propKinds): nature tree(style=round|pine|palm|blossom|dead, height, snow) round_tree pine
  palm blossom dead_tree bush rock(moss) flowers grass mushroom cactus crystal log reeds lily_pad snowman lollipop candy_cane gumdrop
  asteroid; build house(width, depth, floors, roof, lit) shop(text, accent) tower(style=castle|watchtower|skyscraper|neon, height)
  skyscraper fence(length, style=picket) lamp streetlight torch sign(text) flag bridge(length, width) ramp(width, height, length)
  pillar low_wall sandbags platform(size); items crate barrel chest coin(value) gem(value) weapon_rack; interior counter stove(on)
  sink fridge table(round, cloth) chair plate(food) pot shelf/bookshelf(jars) bed desk(computer) rug(round) fireplace plant
  lab_bench; vehicles car boat buoy umbrella. Stations (counter stove sink fridge table desk lab_bench weapon_rack) are tagged
  KitStation (attr Station) -> hand to GameplayKit Station/prompt. Coins/gems tagged KitCoin/KitGem (attr Value).
- W.biome(kind, {center, size=256, seed, density=1, palette, parent}) -> {folder, spawn=Vector3, props, ...}. kinds: grassland beach
  islands desert canyon snowy_mountains forest swamp volcanic neon_city candy space_asteroids. Smooth terrain + clustered props
  with a clear centre (spawn there). The look's terrain colours finish it (snow look + snowy_mountains, desert look + canyon ...).
- W.populate({center, size=n|Vector2, kinds={{"pine", weight, {opts}}...}, count=40, clusters=6, spread=0.1, clear=0, onWater,
  float={min,max}, include={parts to stand on}, seed, parent}) -> {Model}: clustered scatter on raycast ground. W.groundAt(x, z).
- W.course(points, {width=16, style="road"|"water"|"rail"|"platforms", gates=true|n|false, closed, spacing=14, supports=true})
  -> {model, samples={CFrame}, gates={Part}, length, start=CFrame}. Catmull-Rom through points; gate arches with invisible
  triggers tagged KitGate (GateIndex, IsStart): GameplayKit Race.new({gates = course.gates}).
- W.platformingCourse({start, length=14, difficulty=1..5, theme="grass"|"candy"|"lava"|"ice"|"sky"|"neon", direction, coins=true})
  -> {model, platforms, checkpoints={Part}, goal=Part, start=CFrame}. Jumpable gaps (3..11 studs, rises <=4; after a bounce pad
  up to 13). Hooks: KitMover (MoveOffset, MovePeriod), KitSpinner (SpinSpeed), KitCrumble, KitBounce (BouncePower), KitCheckpoint
  (Index), KitGoal, KitCoin. W.animate() (server, once) runs them and carries riders; ALSO call W.animate({movers=false,
  spinners=false, crumble=false}) from a LocalScript so bounce pads launch the (client-owned) character. coins=true spins pickups.
  Or hand checkpoints to GameplayKit Checkpoints.new({parts = obby.checkpoints}).
- W.arena({center, shape="square"|"circle", size=160, wallHeight=14, style="military"|"scifi"|"fantasy"|"toon", cover=true,
  ramps=true, spawns=8}) -> {model, spawns={CFrame}, center, size}: mirrored 4-way cover, raised centre with ramps, spawn pads
  (invisible parts tagged KitSpawn). GameplayKit Rounds.new({arenaSpawns = arena.spawns}).
- W.room({center=floor centre, size=Vector3(40,14,32), theme="kitchen"|"tavern"|"office"|"lab"|"bedroom", doors={"south"},
  windows=true, ceiling=false, lights=true}) -> {model, stations={{kind, part, position}}, spawn, floorY, bounds}. Alias W.interior.
- W.town({center, blocks=3, blockSize=56, street=16, style="suburb"|"city"|"neon"|"medieval"|"western"}) -> {model, blocks,
  intersections, spawn}. W.dungeon({center, rooms=8, cell=8, roomCells={2,4}, height=12, torches=true}) -> {model, rooms={{center,
  size}}, start, finish} (chest + gem tagged KitGoal in the last room). Open-topped for follow/top-down cameras.
Rules: Part Shape=Cylinder lies along X; Ball parts are always spheres (W uses SpecialMesh Sphere for ellipsoids); never write
empty MeshParts. Sizes: keep biome size <= 512 and town blocks <= 4 (part counts grow with area; populate caps at max=400).
Example: LookKit.apply("snow"); W.biome("snowy_mountains", {size=320}); W.prop("house", {position=W.groundAt(30, 0)})
