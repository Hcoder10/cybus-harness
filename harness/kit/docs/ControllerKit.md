- ControllerKit (CK = require(ReplicatedStorage.Kit.ControllerKit)): tuned feel profiles; pick one, override numbers, connect
  events (ev:Connect(fn)). All opts optional; every controller has :setEnabled(bool), :state(), :Destroy(). Keyboard/mouse + gamepad
  + touch (buttons only when TouchEnabled). Camera via CameraRig: camera = {CameraRig.follow opts} tunes it, false keeps yours.
- CK.platformer(player|character?, {runSpeed=32, accel=110, decel=150, turn=280, airControl=0.6, jumpHeight=9.5, coyote=0.1,
  buffer=0.13, jumpCut=0.45, fallGravity=1.7, maxFall=190, doubleJump={height=7.5, count=1}|false, longJump={speed=64, height=5,
  minSpeed=16}|false, dive={speed=52, up=14}|false, dash={speed=72, time=0.16, cooldown=0.6}|false, groundPound={hang=0.14,
  speed=160}|false, wallKick=true|{out, height, reach, grace} (off by default), onLand=fn(impactSpeed, ctl), camera, keys})
  (LocalScript) -> ctl; ctl.Jumped(kind "jump"|"long"|"wall"), .DoubleJumped(n), .Landed(impactSpeed), .GroundPound(pos),
  .Dashed("dash"|"dive"). Space/A jump, Ctrl/C/L2 crouch (crouch+jump = long jump; in air = ground pound), Shift/X dash.
  It owns Humanoid.WalkSpeed/JumpHeight while enabled: change speeds with ctl:set({runSpeed = 40}), never WalkSpeed.
- CK.topDown(player?, {view="isometric"|"topDown", speed=22, accel=95, decel=120, turnRate=14, clickToMove=true, pathfind=true,
  marker=true, interact={radius=10, tag="Interactable", keys, highlight=true, prompt="E", filter=fn(inst), candidates=fn()}|false,
  camera}) (LocalScript) -> ctl; ctl.FocusChanged(inst|nil), .Interacted(inst), .MoveTargetSet(pos), .Arrived(pos);
  ctl:moveTo(pos); ctl:stop(); ctl:focus(). Tag interactable parts/models with CollectionService tag "Interactable".
- CK.shooter({view="fps"|"tps", weapon="rifle"|"smg"|"pistol"|"shotgun"|"sniper"|"launcher"|{name, base, ...overrides},
  weapons={name=overrides}, walkSpeed=18, sprintSpeed=28, crouchSpeed=10, adsSpeed=11, fov, sensitivity=1, adsSensitivity=0.6,
  adsTime=0.16, aimToggle=false, viewmodel=true|Model (PrimaryPart + Attachment "Muzzle")|false, crosshair=true, hud=true, camera})
  (LocalScript) -> ctl; ctl.Fired(info), .Hit(result) (local prediction), .HitConfirmed({damage, killed, head}) (server),
  .ReloadStarted(s), .Reloaded(), .AmmoChanged(ammo, reserve), .Aimed(bool), .StateChanged("ready"|"reloading"|"empty"|"sprinting");
  ctl:equip(weapon); ctl:reload(); ctl:ammo() -> (ammo, reserve). LMB/R2 fire, RMB/L2 aim, R/X reload, Shift sprint, C crouch.
  Weapon stats: damage, headshot, rpm, auto, pellets, magazine, reserve, reload, range, adsFov, mode="hitscan"|"projectile",
  spread={hip, ads, move, crouch, bloom, bloomMax, recover}, falloff={start, finish, min}|false, recoil={pitch, yaw, kick, recover,
  back}, projectile={speed, gravity, splash={radius, damage, min}}, tracer. CK.weapons() -> the preset table.
- CK.shooterServer({weapons, hitTolerance=7, maxOriginError=9, friendlyFire=false, onDamage=fn(attacker, humanoid, dmg, info)
  -> false cancels (default humanoid:TakeDamage), onKill=fn(attacker, humanoid, info)}) (Script): owns ammo + fire rate, re-casts
  every shot, accepts lag-tolerant claimed hits, applies falloff/headshots/splash. Pass the SAME weapons table to both halves.
- CK.vehicle(nil|model, {kind="kart"|"car"|"hover"|"boat", spawn=CFrame, color, accent, maxSpeed, accel, grip, driftGrip,
  steer, freq (suspension Hz), ratio, rest, drift={tiers, boosts, ...}|false, boost={speed, accel, fov}, waterLevel |
  waterHeight=fn(x, z) -> y, input=fn() -> (throttle, steer, drift), camera={distance, height, pitch, fov, rotSpeed} | false}).
  SERVER: spawns the chassis (or adopts your model: PrimaryPart root facing -Z, a Seat) and gives the sitter network ownership;
  h.Entered(player)/.Exited(player). CLIENT: CK.vehicle("seated", sameOpts) drives whichever KitVehicle you sit in;
  CK.vehicle(nil, opts) builds a client-only vehicle and drives it now (prototypes). Client ctl: .Landed(impact), .Airborne(),
  .DriftStarted(dir), .DriftTier(tier), .DriftEnded(tier), .Boosted(tier|"pad"), .Bumped(impact), .Fell(), .Entered(), .Exited();
  ctl:boost(seconds) (boost pads), ctl:reset(cf?), ctl:exit(), ctl:state() -> {speed, forwardSpeed, grounded, drifting, tier,
  boosting, onWater, cframe}. WASD/stick/thumbstick, R2/L2 throttle/brake, Space/Shift/R1 drift, R/Y reset, F/B exit.
