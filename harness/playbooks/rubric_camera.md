# Camera and cinematics

Covers the gameplay camera, framing, field of view, transitions between states, cinematic shots,
camera shake, and cutscenes.

## Capture
- Frame strips (8-12 frames over 1-2 s) of: moving and turning, moving near walls and under ceilings, the
  menu-to-gameplay transition, the signature moment, any cutscene.
- A still from the default camera at rest and at full speed.

## Anchors
- **1-2**: clips through walls, jitters, loses the player, snaps abruptly, or is the untouched default
  where the genre clearly needs something else.
- **4**: default Roblox follow camera; nothing designed for this game; no transitions.
- **7**: a camera designed for the genre (distance, height, offset, FOV), smooth, never clips, reacts
  subtly to speed and action; eased transitions between states.
- **9**: cinematic: composed frames, the camera tells the player where to look, shake / FOV kicks / slow
  motion spent only on payoffs, authored shots for the signature moment, letterboxed or framed cutscenes
  that can be skipped.

## Checks
1. **Framing.** The subject sits on a third with lead room in the direction of motion; threats and goals are
   in view; the horizon is level unless tilted on purpose.
2. **FOV.** Chosen per state (e.g. slightly wider at speed, narrower for aiming or dialogue); changes are
   eased, never instant.
3. **Smoothing.** Critically damped springs or eased lerps; no jitter at any frame rate (use delta time); no
   lag so large the player drifts off-screen.
4. **Collision.** No clipping into walls or props; no sudden pops when an occluder appears.
5. **Shake budget.** Short (<= 0.3 s outside payoffs), decaying, directional, scaled to the event's
   magnitude, and disabled by a reduce-motion setting.
6. **Transitions.** Menu -> play, play -> results and into / out of cutscenes use eased camera moves or
   deliberate cuts, never an unmotivated snap.
7. **Signature moment.** The camera does something special there (a dolly, a low angle, a slow-motion beat,
   a hold on the result).
8. **Control.** Player camera control feels right on mouse, touch and gamepad (sensitivity, inversion
   respected, no fighting the player).

## Common failures -> fixes
- Shake on everything -> keep shake for impacts above a threshold; scale by magnitude; decay in 0.15-0.3 s.
- Linear camera tweens -> Quint/Sine easing; hold for a beat at the end of cinematic moves.
- Camera ignores speed -> +5-15 degrees FOV and a slight pull-back as speed rises.
- Cutscene camera through geometry -> author the path with collision-free waypoints; test every frame.
