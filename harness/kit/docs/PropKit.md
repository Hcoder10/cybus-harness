- PropKit (PK = require(ReplicatedStorage.Kit.PropKit); server or client): spawns generated props. Make props with the builder
  tool generate_prop: each lands as a ModuleScript at ReplicatedStorage.Shared.Props.<Name> returning {name, style, size, palette,
  parts}. An asset arg is that table, its ModuleScript, or the name (required + cached). Props are part-built (Block, Ball, block +
  SpecialMesh Sphere): no mesh ids. Longest side = scale studs; pivot = bottom centre; front faces -Z.
- PK.spawn(asset, {position | cframe, scale=6, rotation=deg yaw | Vector3 deg, tint=Color3, tintAmount=0.35, palette={[i]=Color3},
  material=SmoothPlastic, detail="full"|"low", collide="box"|"parts"|"none", anchored=true, parent=workspace, name}) -> Model.
  position = where the bottom centre goes. PrimaryPart = invisible "Root" at the bottom centre (model:PivotTo(CFrame.new(groundPoint))
  grounds it). collide "box" = one invisible "Hitbox" part sized to the bbox, visual parts non-colliding/massless (cheap, use it);
  "parts" = every visual part collides; "none" = nothing. anchored=false welds everything to Root. detail="low" drops parts smaller
  than 4% of the prop (distant / repeated props). Attributes: model PropName, PropScale; each part PropColor (palette index).
- PK.recolor(model, {[i]=Color3}): repaint a spawned prop by palette index (team colours, states).
- PK.variants(asset, n, seed?, base?) -> {opts}: copies of base opts, scale (base.scale or 6) +-15%, random yaw, palette hue +-0.04 and
  value +-8% (one shift per variant). for _, o in PK.variants(a, 5, 1) do o.position = ...; PK.spawn(a, o) end
- PK.scatter(asset, area, count, {jitter=0.2, seed, minSpacing, castHeight=200, exclude={Instance}, ...spawn opts}) -> {Model}:
  area = {center, radius} | {min, max} | BasePart (its top face). Raycasts straight down to the ground (ignoring the props it placed),
  random yaw, scale jitter; points with no ground are skipped (may return fewer than count).
- PK.list() -> {names under Shared.Props} ({} if none); PK.bounds(asset, scale=6) -> Vector3 studs (for layout and spacing).
- Errors on a bad asset (missing palette/parts, bad colour index, unknown prop name) with a clear [PropKit] message.
Example: local Props = ReplicatedStorage.Shared.Props
  PK.spawn(require(Props.Mushroom), {position = Vector3.new(0, 0, 10), scale = 8})
  PK.scatter("Rock", {center = Vector3.zero, radius = 80}, 25, {minSpacing = 10, detail = "low"})
