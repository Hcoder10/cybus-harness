# Game feel

Covers responsiveness, impact, "juice", feedback layering, movement feel, anticipation and recovery.
Game feel is judged from SEQUENCES, never single stills.

## Capture
- Frame strips (8-16 frames over 1-2 s, evenly spaced) around each core verb: the input, the response, the
  impact, the recovery.
- A strip of movement (start, top speed, stop, turn, jump / land where applicable).
- The playtest log: input timestamps vs. first visible response, if available.

## Anchors
- **1-2**: input lag, no feedback, floaty or broken movement, actions that feel like nothing happened.
- **4**: works, but actions have no weight: no sound, no particles, no screen response; movement starts and
  stops instantly.
- **7**: every core verb has layered feedback (animation + VFX + sound + camera + UI); movement tuned with
  acceleration and deceleration; rewards pop.
- **9**: tactile: hit-stop on big impacts, squash and stretch, anticipation and recovery, crisp timing,
  feedback scaled to magnitude. You can feel it with the sound off and hear it with your eyes closed.

## Checks
1. **Latency.** Visible response within 100 ms of input: play local effects and animation on the client
   immediately, reconcile with the server after.
2. **Layering.** Each core verb answers on at least three channels (motion, VFX, sound, camera, UI).
3. **Impact.** Big hits / collisions / successes get a strong first frame (flash, pop), hit-stop 40-120 ms,
   knockback or recoil, shake scaled by magnitude, and a sound with a transient.
4. **Anticipation and recovery.** Big actions wind up (even 80-150 ms) and recover; nothing starts or stops
   in a single frame unless snappiness is the point.
5. **Movement.** Acceleration / deceleration curves; turn responsiveness; air control; jump buffering and
   coyote time where jumping matters; landing feedback.
6. **Rewards.** Gains pop (scale bounce, particle burst, count-up, sound); bigger rewards get bigger, longer
   feedback.
7. **Failure.** Clear, fast and fair: the player sees why, loses little, and is back in play quickly.
8. **Consistency.** The same verb always gives the same family of feedback; magnitudes are ordered.

## Common failures -> fixes
- Silent clicks -> a UI press sound + scale bounce on every button.
- Floaty movement -> raise acceleration, shorten deceleration, add a landing squash and dust.
- Feedback only after the server replies -> predict locally; show the effect immediately.
- Everything shakes -> one budget; only the top tier of events earns shake.
