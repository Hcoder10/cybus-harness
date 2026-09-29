# Animation

Covers character animation (idle, locomotion, actions, reactions), object and prop animation, and the
motion of UI.

## Capture
- Frame strips (10-16 frames) of: idle (over ~2 s), walk / run cycle, each core action, a hit reaction,
  transitions between states (idle -> run -> action -> idle).
- UI: a strip of a screen opening, a button press, a reward appearing.

## Anchors
- **1-2**: T-poses, frozen characters, sliding feet, broken limbs, props floating away from hands.
- **4**: default Roblox animations for everything, a few stiff custom ones, linear tweens, snaps between
  states.
- **7**: custom animations for the core verbs with anticipation and follow-through, blended transitions,
  weight; UI motion eased and staggered from the motion tokens.
- **9**: personality in every motion: breathing idles and fidgets, overlapping action, clean arcs, secondary
  motion, poses that read as silhouettes in any frame, timing synced to sound and VFX.

## Checks
1. **Principles.** Anticipation, follow-through / overlap, arcs, slow in / slow out, clear staging, squash and
   stretch where the style allows, exaggeration matched to the tone.
2. **Poses.** Key poses read as silhouettes; weight shifts are visible.
3. **Transitions.** Blends of ~0.1-0.25 s between states; no pops; correct priorities (actions over
   movement over idle).
4. **Contact.** Feet do not slide (playback speed matched to movement speed); props stay in hands.
5. **Procedural touches.** Lean into turns, head / eyes looking at targets, recoil, breathing, where they help.
6. **Sync.** Impacts in the animation line up with the sound and VFX frame.
7. **Objects.** Doors, pickups, machines and collectibles move with easing (bob, spin, squash on collect).
8. **UI motion.** Durations and easings from the motion tokens; staggered children; no linear tweens.

## Common failures -> fixes
- Stiff swings -> add a 3-6 frame anticipation and a 6-10 frame follow-through.
- Foot sliding -> scale the run animation speed with the humanoid's actual velocity.
- Instant state changes -> fade tracks with a fade time; set priorities explicitly.
- Collectibles that just vanish -> scale-bounce, burst and fade on pickup.
