- LookKit (LK = require(ReplicatedStorage.Kit.LookKit); server or edit mode): the whole art direction from one call. Call it
  FIRST, before building the world: WorldKit2 props read LookKit.palette when they are built.
- LK.apply(look, overrides?) -> palette. look = "toon_bright" (N64/Mario: saturated, soft shadows, SmoothPlastic) |
  "realistic" (neutral grade, hard shadows, haze, subtle bloom, far DoF; real materials) | "cozy" (warm pastel late sun, soft)
  | "neon_night" (dark, saturated emissives, big bloom) | "dark_fantasy" (cold desaturated fog, cool rim light) | "snow" |
  "desert" | "candy" | "space" (no atmosphere, starfield). Sets Lighting (clock, ambient, colour shift, shadow softness, env
  scales), Atmosphere, Sky "KitSky" (stars, sun/moon size), Clouds, KitBloom / KitGrade / KitSunRays / KitDOF, Terrain material
  colours + water. Removes leftover Sky/Atmosphere instances. Shares effect names with WorldKit.lighting (use one or the other).
  overrides: any preset section replaced key by key: {lighting={ClockTime=...}, atmosphere={}, sky={}, clouds={}, bloom={},
  grade={}, sunrays={}, dof=false|{}, terrain={Grass=Color3}, water={WaterColor=...}, palette={role=Color3|"#hex"},
  mats={role=Enum.Material}, tween=seconds (blend from the current look)}.
- LK.palette.<role> (Color3) for the current look. Roles: primary secondary accent ground groundAlt dirt rock sand wood woodDark
  leaf leafAlt blossom flower water wall roof floor trim ink light glow metal path danger gold sky fabric snow; plus lists
  LK.palette.neon / LK.palette.candy. LK.color(role, fallback?) -> Color3. LK.current = look name (also Lighting attr KitLook).
- LK.mat(role) -> Enum.Material for roles default ground stone wood metal fabric glass roof floor wall glow leaf road (toon looks
  answer SmoothPlastic). LK.style(part, colorRole, materialRole?) paints a part from the look. LK.isToon.
- LK.skybox({bk, dn, ft, lf, rt, up = image id | "rbxassetid://..", orientation=Vector3?}) sets KitSky's six faces (e.g. generated
  art); survives later apply calls; LK.skybox(nil) stops re-applying it. Without it the default sky is tinted by Atmosphere.
- LK.material(name, {base=Enum.Material, colorMap=id, normalMap?, roughnessMap?, metalnessMap?, studsPerTile=8, color?,
  overrideBase=false}) -> rec: registers a tileable material (ComfyUI textures). Tries a MaterialVariant in MaterialService;
  game scripts may not set its maps (engine: plugin security), so LK.useMaterial(partOrModel, name) then tiles Texture
  instances on all six faces instead. overrideBase=true (variant only) re-skins every part/terrain of that base material.
- LK.outline(model, color=palette.ink, thickness?) -> Highlight?: cel outline (fill hidden). Engine renders at most 31
  Highlights: LookKit counts its own and returns nil past 31, so outline a parent Model of many props once. thickness is
  ignored (Highlight outlines are fixed-width). Use for heroes/pickups/key props, not every tree.
- LK.toonify(model, {quantize=true, palette?, outline=false, outlineColor?}) -> model: SmoothPlastic, no reflectance, each colour
  snapped to the nearest palette colour (Neon/Glass kept) - makes imported or stray parts match the look.
- LK.looks (list), LK.presets (tables, read-only by convention), LK.highlightBudget = 31.
Engine limits: Lighting.Technology is not scriptable - "realistic" wants Future (set in Studio), all looks still read under
ShadowMap. Atmosphere makes legacy Fog inert (LookKit parks FogEnd far). Terrain grass blades (Decoration) are not scriptable.
Example: LK.apply("cozy", {palette={primary="#E07A5F"}}); WorldKit2.room({theme="kitchen"}) -- kitchen in the cozy palette.
