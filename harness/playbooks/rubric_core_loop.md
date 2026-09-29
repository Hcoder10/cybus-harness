# Core loop and systems

Covers the game design as played: clarity of goals, the loop, progression, pacing, onboarding, reward
cadence, fail states, session shape, and whether the systems actually work.

## Capture
- A playtest: frame strips across one full loop and one full session (join -> first action -> reward ->
  progression -> end / results), the playtest event log, the output log, and the design doc.

## Anchors
- **1-2**: no playable loop, or it breaks (errors, soft-locks, nothing happens).
- **4**: a loop exists but goals are unclear, rewards are flat, nothing to progress toward, no reason to keep
  playing.
- **7**: the loop is clear within 30 s of joining, goals always visible, rewards satisfying, progression
  hooks, a difficulty ramp, fast fail -> retry.
- **9**: compelling: mastery depth, real decisions, variety within the loop, the signature moment recurs,
  onboarding teaches by doing, session hooks bring the player back.

## Checks
1. **Time to first meaningful action** under 30 s from join, with no reading required.
2. **Goal clarity.** The player always knows the next objective (UI, world cues, or both).
3. **Reward cadence.** Small feedback every few seconds, a medium reward every minute or so, a big one per
   session.
4. **Progress.** Visible progress (bars, counters, unlocks, levels) that persists where appropriate.
5. **Difficulty.** Ramps; early success is easy; later challenge requires skill or decisions.
6. **Failure.** Fast retry, small loss, the player learns what went wrong.
7. **Onboarding.** Contextual prompts at the moment of need; no walls of text.
8. **Multiplayer sense.** Other players are visible and relevant (shared goals, competition, or presence).
9. **Correctness.** Server-authoritative state for anything that matters (currency, scores, progress);
   remote events validated; no errors in the output log; no soft-locks.

## Common failures -> fixes
- Player spawns with nothing to do -> a first objective in view with a prompt and a path.
- Rewards are only text -> tie rewards to visible, spendable progress.
- Client-trusted currency -> move the logic to the server; validate every remote.
