# World art and lighting

Covers the environment: level layout as seen, lighting, atmosphere, materials, props, sky, landmarks and
composition of spaces.

## Capture
- An establishing wide shot, several views at player-eye height along the main path, detail close-ups of
  props, the sky / horizon, and each lighting state (e.g. day and night) the game uses.

## Anchors
- **1-2**: baseplate, default grey parts, floating or intersecting parts, untouched default lighting, visible
  void or world edge.
- **4**: basic parts with default materials, flat noon lighting, no atmosphere, repetitive, no landmarks,
  free-model props in clashing styles.
- **7**: a coherent palette and material set, tuned lighting (key light direction, ambient, atmosphere,
  colour correction), landmarks, paths that lead the eye, props that tell a story, a readable play space.
- **9**: a place with a mood you would screenshot: light as a design element (key / fill / rim, chosen sun
  angle for form), foreground / midground / background depth, strong silhouettes, detail graded by
  importance, and a world that guides the player without signs.

## Checks
1. **Lighting.** Not the default: a chosen time of day and sun angle, tuned ambient, atmosphere (density,
   haze, colour), colour correction, restrained bloom; local lights (with shadows where it matters) that
   create pools and focal points.
2. **Value structure.** The play space and interactive objects read against the background (value and
   saturation contrast); the brightest, most saturated things are the important ones.
3. **Palette and materials.** World colours from the style guide; a consistent material set (not default
   Plastic everywhere unless the style says so); textures at consistent scale.
4. **Composition.** Sightlines to objectives; landmarks for orientation; framing (arches, trees, cliffs);
   paths and lighting lead the eye.
5. **Scale.** Doors, stairs, props sized to the avatar; no accidental giant or tiny objects.
6. **Density.** Detail where the player looks; calm where they should not; no empty baseplate vistas; no
   clutter blocking movement.
7. **Sky and edges.** A sky that fits the mood; world boundaries hidden (terrain, fog, walls, water); no
   visible void or baseplate edge.
8. **Craft.** No z-fighting, gaps, floating parts, mismatched seams, or stretched textures.

## Common failures -> fixes
- Flat noon look -> lower the sun (morning / golden hour / dusk), warm key vs. cool ambient, add atmosphere.
- Everything the same value -> darken the background, lighten or saturate the play space and pickups.
- Random free-model props -> build a small kit of props in one style from primitives or one source.
- Empty map -> cluster props into vignettes along the path; leave calm areas deliberately.
