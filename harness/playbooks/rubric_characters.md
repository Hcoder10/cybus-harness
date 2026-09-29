# Characters

Covers player avatars and how the game presents them, NPCs, enemies, creatures, and characters shown in
menus (portraits, lineups, shops).

## Capture
- A lineup of every character type, a silhouette version (all black on white) of the same lineup, characters
  in-world at gameplay distance, and close-ups where menus show them.

## Anchors
- **1-2**: broken rigs, missing parts, default blocky placeholders where designed characters are needed.
- **4**: free-model characters in mismatched styles; roles indistinguishable; avatars look wrong in the
  game's lighting or scale.
- **7**: characters designed for this game: distinct silhouettes per role, palette-coded, consistent with
  the world's style, readable at gameplay distance; player avatars look good in the game.
- **9**: characters with personality (proportion, pose, accessories, idle behaviour), roles readable at a
  glance, memorable designs, integrated with the UI (portraits, colours, names) and VFX.

## Checks
1. **Silhouette.** Each role is identifiable from its silhouette alone.
2. **Readability at distance.** Colour blocking and value contrast against the environment; nameplates or
   outlines where the genre needs them, styled from the tokens.
3. **Style consistency.** Proportions, detail level and materials match each other and the world.
4. **Role coding.** Allies / enemies / neutrals / bosses coded consistently (colour, shape, size, VFX).
5. **Avatars.** User avatars are respected and look good (lighting, scale, camera), or replaced deliberately
   and consistently where the design calls for it.
6. **Presentation.** Menu portraits and lineups are posed and lit (a key light, rim, a backdrop), not raw
   T-poses on flat colour.
7. **Rig integrity.** Joints move correctly; accessories attached; no parts left behind.

## Common failures -> fixes
- Enemies look like players -> a distinct silhouette feature + role colour + outline.
- Portraits as raw captures -> a posed rig in a small lit scene (ViewportFrame) with a backdrop.
- Mixed styles -> pick one style and rebuild or retexture the outliers.
