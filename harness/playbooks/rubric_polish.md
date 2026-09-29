# Polish

Covers the last 10% that separates a front-page game from a demo: loading, transitions, edge states,
errors, input devices, performance, settings, and small delights.

## Capture
- The first 10 s after joining (frame strip), the loading screen, transitions between every major state,
  edge states (empty, maxed, long names, zero money, disconnect / respawn), phone layout, the output log
  (errors and warnings), and performance stats (frame rate, memory, instance counts).

## Anchors
- **1-2**: errors in the output, pop-in, broken states, placeholder text.
- **4**: works on the happy path only; rough edges everywhere else; no loading screen; jarring cuts.
- **7**: a clean output log, assets preloaded behind a styled loading screen, transitions everywhere, edge and
  empty states designed, settings (music, sound, reduce motion), steady frame rate on desktop.
- **9**: nothing breaks the spell: no pops or flicker, every state designed, keyboard / mouse, touch and
  gamepad all first-class, accessible text, good performance on phones, small delights (idle animations,
  hover sounds, secrets).

## Checks
1. **Output log.** No errors, no "Infinite yield possible", no warnings from the game's scripts.
2. **Loading.** Key assets preloaded; a styled loading screen replaces the default; no untextured flashes.
3. **Transitions.** Every state change is eased or deliberately cut; no single-frame pops.
4. **Edge states.** Empty, maxed, long text, zero currency, lost connection, respawn: all handled and
   styled.
5. **Input.** Every action works on keyboard / mouse, touch and gamepad, with the right prompts.
6. **Performance.** Stable frame rate; no per-frame allocations piling up; effects and connections cleaned
   up; reasonable instance counts; streaming where the map is large.
7. **Settings and persistence.** Settings exist, apply immediately, and persist; progress saves safely.
8. **Delights.** At least a few moments of care beyond the requirements.

## Common failures -> fixes
- Output log full of warnings -> fix each; wrap WaitForChild with timeouts where appropriate.
- Default loading screen -> a ReplicatedFirst loading screen with the game's art and a real progress bar.
- Jank on resize -> scale-based layout with one UIScale driven by the viewport.
