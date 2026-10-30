- GameplayKit (GK = require(ReplicatedStorage.Kit.GameplayKit)): server-authoritative systems; remotes are internal (never wire one).
  Server: X.new(opts) (all opts default). Any client requiring GK gets coin bob/spin, knockback, G drop / R throw. Signals:
  s:Connect(fn) -> conn; objects :destroy() / maid:Give(obj). Client state: GK.watch(system, attr, fn), GK.get, or :GetAttribute below.
- GK.Rounds.new({minPlayers=1, lobby=8, countdown=3, duration=120, results=6, autoRestart=true, arenaSpawns={CFrame}, lobbySpawn,
  endWhen=fn(r)->reason?, onStart=fn(players), onEnd=fn(reason, players)}) -> r; r:finish(reason); r.StateChanged(state, prev);
  watch "Rounds": State ("Lobby"|"Countdown"|"Playing"|"Results"), TimeLeft, Round, Reason
- GK.Score.new({stats={"Score"}, start=0, descending=true}) -> s:add(player, n, stat?); s:set; s:get; s:ranking(stat?) ->
  {{player,name,value,rank}}; s.Changed(player, stat, value); leaderstats auto; player attr Rank; watch "Score": Top (JSON top 10).
  GK.Objectives.new({list={{id, text, goal=1, reward=fn(player)}}, sequential=false, onComplete, onAll}) -> o:progress(player, id, n=1);
  o:set; o:get; o:isComplete; o.Completed(player, id); player attrs Obj_<id>, ObjDone; client: GK.Objectives.client().list()
- GK.Timer.new({duration=60|nil (stopwatch)}) -> t:start/pause/reset/elapsed/remaining; t.Tick; t.Finished; GK.Timer.format(s, centis).
  GK.Health.new(model|part, {max=100, regen=0, invuln=0.4, destroyOnDeath, team, onDeath, onDamage}) -> h:damage(n, source,
  {knockback=Vector3}); h:heal; h:kill; h.Died(source); h.Damaged; attrs HP/MaxHP/Invulnerable. GK.Health.damage(anyPart, n, source)
  (auto-wraps Humanoids, respects teams + ForceField); GK.Health.players({invuln=1}); GK.knockback(target, velocity)
- GK.Teams.new({teams={{name, color=BrickColor}}, autoAssign=true}) -> t:assign(player, name?); t:of(x); GK.sameTeam(a,b).
  GK.Checkpoints.new({parts=Folder|{BasePart} (sorted by number), fallY=-30, forwardOnly=true, onReached=fn(player, i)}) -> c:get/
  set/respawn/reset(player); touch to set, death or falling respawns at the last one; player attr Checkpoint
- GK.Weapon.new(name, {kind="hitscan"|"projectile"|"melee", damage=20, cooldown, range, speed, arc=Vector3 (melee box), knockback,
  onHit=fn(attacker, target, dmg, pos)}) -> w:fireFrom(model, dir?); client: GK.Weapon.client(name).fire(dir?) (server re-validates).
  GK.hitscan(origin, dir, range, ignore) / GK.hitbox(cframe, size, ignore) / GK.sphere(pos, r, ignore) -> damageable models
- GK.Collectibles.new({points={CFrame|Vector3|part} | region={center, size, count}, template, value=1, stat="Coins", score=Score,
  magnet=0, respawn=nil|s, onCollect=fn(player, value, total, item)}) -> c:count(player); player attr <stat>.
  GK.prompt(part, {action="Use", object, hold=0, distance=10, key, onUse=fn(player, part)}) -> h.Used (server-checked distance/rate)
- GK.Carry.new({colors={[type]=color}, throwSpeed=55, onPickup, onDrop}) -> c:spawn(type, at) -> part; c:make(part, type);
  c:held(player); c:give(player, part); c:take(player); c:drop(player, throw?); E pick up, G drop, R throw; player attr Holding
- GK.Station.new(part, {carry=Carry|inventory=Inv, accepts, process={{from="Raw", to="Cooked", time=5, label="Cooking"}, ...}, recipes,
  onChange=fn(state, item)}) -> st:put(type); st:takeTop(); part attrs State ("Empty"|label|"Ready"), Item, Progress 0..1, Contents
- GK.Recipes.new({{inputs={"Bun","Cooked Patty"}, output="Burger", time=0}}) -> r:match(types); r:craft(inv, player, output).
  GK.Inventory.new({name="Main", slots=20, stack=99}) -> inv:add(player, item, n); inv:remove -> bool; inv:count/has/list; client .client(name).list()
- GK.Enemy.new({position, model? (default GK.rig({style="humanoid"|"monster", color, scale})), kind="melee"|"ranged", hp=100,
  speed=14, sight=70, fov=110, hearing=12, attackRange, damage=10, cooldown=1.1, patrol={Vector3}, flee=0 (hp frac), leash=140,
  team="Enemies", onAttack=fn(e, target)->false?, onDeath=fn(e, killer)}) -> e.State (idle|patrol|chase|attack|flee|return|dead), e.Died
- GK.Spawner.new({points | region, waves={{count, interval, enemy={...}}} | waveCount/baseCount/growth, enemy={defaults},
  between=5, maxAlive=20, autoStart, onWave, onCleared, onAllCleared}) -> sp:start(); sp:stop(); watch "Waves": Wave, Alive, Status
- GK.Race.new({gates=Folder|{part} (gate 1 = start/finish), laps=3, countdown=3, onGate, onLap=fn(r, lap, t), onFinish=fn(r, place,
  t)}) -> race:start(); race:addFollower(model, {speed=60, drive=fn(model, target, scale, dt)?, rubber={min=0.85, max=1.2}});
  race:standings(); race.WrongWay(r, on); player attrs RacePlace/RaceLap/RaceWrongWay/RaceTime; watch "Race": Status, Count, Standings
- GK.Mover.new(part, {offset=Vector3 | points, time=3, pause=0.6, mode="pingpong"|"loop"}) (riders carried); GK.Door.new(part,
  {open=CFrame, proximity, key=itemType, closeAfter}) -> d:open/close/toggle; GK.Hazard.spinner({position, length, speed, damage}) /
  .laser({from, to, on, off}) / .crusher({position, drop}) / .kill(part) / .zone(part, {damage, cooldown, knockback, active=fn})
