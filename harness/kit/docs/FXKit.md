- FXKit (FX = require(ReplicatedStorage.Kit.FXKit)): ~50 tuned effect presets on top of VFX; USE THESE instead of hand-made specs.
  Client: FX.play(name, at, opts) -> h (h:stop(); h:set(k) scales a continuous preset's rate, e.g. by speed). at = Vector3 | CFrame |
  BasePart | Attachment | Model. Server: FX.play / FX.playAll(name, at, opts) plays on every client (remote is internal; a client's
  playAll plays locally and the server relays it to the others). FX.register() once on the client also makes VFX.play(name) work.
- Looks: FX.setStyle("toon"|"realistic"|"cozy"|"neon") once to match the game (N64/cel -> toon; shooter -> realistic; cooking/farm ->
  cozy; sci-fi/arcade -> neon), or opts.style per call. opts: variant, color (main colour, Color3 | "#hex"), scale, intensity,
  normal (surface normal: impacts, splashes), direction (forward: muzzle, dash, slash), follow, to, area, juice=false (no camera extras).
  A name may carry its variant: "explosion_large", "muzzle_flash_shotgun", "fire_torch", "drift_sparks_3", "slash_arc_left".
- movement: jump_puff, land_dust ({impact=0..1}), double_jump_ring, dash_streak ({direction}), speed_lines, boost_flame*, drift_sparks*
  (variant "1"|"2"|"3" = blue/orange/purple), water_splash, wake_spray* (on the boat part), footstep_dust, skid_marks (on a chassis part)
- combat: muzzle_flash (rifle|pistol|shotgun; at = muzzle, {direction}), bullet_tracer ({to, impact="concrete"|...}), impact_concrete,
  impact_metal, impact_wood, impact_flesh (cartoon, no gore), impact_water ({normal}), explosion (small|large: shake, flash, debris,
  scorch), hit_spark, critical_hit (adds hitstop + flash), shield_hit, heal_aura, death_poof, slash_arc (right|left; at = character
  CFrame), magic_bolt ({to}: flies, then magic_impact), magic_impact, lightning ({to})
- pickups: coin_collect, gem_sparkle*, star_burst, level_up (column + rings + confetti), confetti_burst, firework, checkpoint_activate,
  portal_swirl* (faces the part's front)
- ambient*: steam, cooking_sizzle, smoke_plume, fire (campfire|torch), fireflies, falling_leaves, falling_petals, snowfall, rain,
  dust_motes, sparkles, bubbles, waterfall_mist, lava_embers ({area}), neon_flicker (at = a neon BasePart or a position)
  (* = continuous: runs until h:stop(); on an Instance it follows it.) Weather with at = nil follows the camera:
  FX.weather("rain"|"snowfall"|"falling_leaves"|"falling_petals"|"fireflies"|"dust_motes", {area=60}) -> h (rain splashes on the ground)
- Direct helpers: FX.tracer(from, to, {impact, normal, color}); FX.lightning(from, to, {color}); FX.bolt(from, to, {speed=60, arc,
  color, onHit=fn(pos)}); FX.skid(part, {width, lifetime, offset}) -> VFX trail (:enable(on), :destroy()); FX.flicker(partOrPos, {color,
  rate}) -> h; FX.speedLines(0..1, {color}) -> h (h:set(speed / topSpeed) every frame; 0 fades out); FX.debris(at, {count, size, speed,
  color}); FX.scorch(at, size, seconds)
- Juice: FX.hitstop(0..1) (30-120 ms freeze); FX.punch(0..1, direction?) (FOV snap + shake + push); FX.flash(color, strength=0.35,
  seconds=0.15); FX.slowmo(scale, seconds) (VFX + camera only); FX.shakeAt(at, trauma, radius) (fades with camera distance).
- Textures: built-in Roblox sprites by default. FX.texture(slot, imageId, {layout="4x4", fps=24, mode="loop"}) swaps a slot for a generated
  sprite or flipbook (slots: flame, smoke, dust, spark, ember, star, glint, glow, ring, fireball, confetti, debris, shard, leaf, petal,
  drop, snow, bubble, mist, magic, streak, scorch, vortex, soft, circle, puff, square). FX.names(group?), FX.info(name), FX.spec(name, opts).
