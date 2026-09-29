# HUD: the in-play overlay

Covers health / resource bars, timers, score, objectives, minimap, action and ability buttons, prompts,
notifications, damage / reward numbers, feeds, and touch controls.

## Capture
- Gameplay at desktop and phone, in a calm moment and in the busiest moment (every HUD element active).
- Over the brightest and the darkest parts of the world.
- A frame strip (8 frames over ~1 s) of the HUD reacting: taking damage, gaining a reward, an objective update.

## Anchors
- **1-2**: missing or broken HUD; overlaps Roblox core UI (top bar, chat, player list, mobile jump button);
  unreadable over the world.
- **4**: default-looking bars and TextLabels crowding the screen; raw numbers ("87/100") bigger than the bar;
  everything always visible; no reaction to events.
- **7**: minimal, anchored to corners and edges, readable over any background, styled from the tokens,
  reacts to events with motion; touch controls sized and placed for thumbs.
- **9**: the HUD is nearly invisible until it matters, then speaks with motion and sound; the centre of the
  screen stays clear for play; information appears exactly when needed; diegetic touches where they help.

## Checks
1. **Centre clear.** Nothing persistent in the central ~40% of the screen except transient, purposeful
   feedback (hit markers, prompts near the object).
2. **Priority.** The one number the player must track (health, time, speed, score) is the most legible
   element; the rest are smaller and quieter.
3. **Readability over the world.** Backing plates, strokes or shadows so text reads over sky, snow, neon and
   night; contrast >= 4.5:1 for numbers.
4. **Reaction.** Bars animate (a delayed "ghost" chunk on loss, a flash on gain); numbers roll; notifications
   enter and leave with the motion tokens and queue instead of stacking on top of each other.
5. **Prompts.** Show the glyph for the current input (key, gamepad button, or a tap target); appear near the
   object or in one consistent place.
6. **Touch.** Buttons >= 44 dp, reachable by thumbs, not overlapping the jump button or the thumbstick, with
   pressed states.
7. **Core UI.** Roblox chat, player list, top bar and mobile controls are respected or deliberately
   disabled and replaced.
8. **Density.** Information not needed right now is hidden or collapsed; no permanent tutorial text.

## Common failures -> fixes
- Big text in the middle of the screen -> move to an edge; show centrally only for moments that matter.
- Bars that snap -> tween with a lagging ghost bar and a flash.
- HUD invisible on bright areas -> dark translucent backing plate, UIStroke on text.
- Notifications overlapping -> a queue with a max of 3 visible and eased slide-in.
