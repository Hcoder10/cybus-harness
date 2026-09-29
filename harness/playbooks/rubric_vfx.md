# VFX

Covers particles, beams, trails, mesh effects, lighting flashes, screen effects, and UI effects.

## Capture
- Frame strips (8-12 frames over the effect's life: anticipation, peak, dissipation) for each key effect.
- Each key effect over a bright and a dark background.
- A busy moment with several effects at once.

## Anchors
- **1-2**: nothing, or default sparkles / fire / smoke objects, flicker, effects that never disappear.
- **4**: single-layer effects with default textures, constant size and transparency, uniform colour,
  lifetimes too long (mud), effects that hide the action.
- **7**: layered effects (a value hierarchy plus secondaries), custom or well-chosen textures, fast-in slow-out
  timing, palette colours, readable silhouette, cleaned up after use.
- **9**: designed effects: anticipation -> impact -> dissipation with a shape language matching the game,
  light that touches the scene, screen-space accents only on payoffs, a coherent family of effects.

## Checks
1. **Layers.** A value hierarchy (the brightest part where the energy is, a body in the effect's colour, a
   contrast layer so it reads on any background: a darker edge, an outline or a complementary accent, in
   the game's own style), plus secondaries (sparks, debris, dust) and an afterglow or smoke.
   A single emitter is a 4 at best.
2. **Timing.** A strong frame within the first 1-3 frames of an impact; ease-out decay; lifetimes as ranges;
   no effect lingering past its meaning.
3. **Curves.** Size, transparency and colour change over life (sequences, not constants).
4. **Texture and shape.** Textures fit the style (painterly, cel, pixel, realistic); flipbooks where motion
   helps; no stock sparkles unless the style calls for them.
5. **Colour.** From the palette; value contrast against the background; bloom does not white-out the frame.
6. **Readability.** The player can still read the action; big effects do not hide threats or UI.
7. **Light.** Emissive effects light the scene briefly (a short-lived light) when the moment deserves it.
8. **Direction.** Effects are oriented to the action (motion direction, impact normal).
9. **Cleanup and cost.** Emitters disabled / destroyed after use; particle counts and rates sane.

## Common failures -> fixes
- Confetti soup -> fewer, larger, shaped particles; a clear core; shorter lifetime.
- Additive white-out -> lower brightness and light emission; add a contrast layer.
- Effect same colour as the world -> shift hue or value; add an outline or contrast layer.
- Leaks (effects piling up) -> Debris / explicit cleanup after the effect's max lifetime.
