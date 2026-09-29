# The studio scale and the principles every aspect shares

## Scale (every judge, every aspect)
- **1-2 broken / placeholder**: errors, missing pieces, default Roblox parts and fonts, overlaps, unreadable.
- **3-4 typical hobby Roblox game**: works, but generic: stock grey UI, default fonts, flat lighting, no feedback.
- **5-6 competent**: a clear style, mostly consistent, readable; lacks polish, juice, cinematic intent.
- **7 strong front-page Roblox game**: custom, cohesive, responsive, readable on a phone; few rough edges.
- **8 excellent**: every screen and moment feels authored; feedback layered; camera and motion intentional.
- **9 the bar**: cohesive and AAA-feeling on Roblox: one visual language everywhere, cinematic camera,
  layered VFX, tuned feel, restraint, payoff moments that land. A player would screenshot it.
- **10 best-in-class**.

## Principles (apply to every aspect, every genre)
1. **One system, written first.** Palette tokens, type scale, shape language, depth recipe, motion tokens,
   camera language, VFX language, audio mood: decided in the style guide BEFORE building, then obeyed.
   Anything that contradicts the style guide is a defect even if it looks fine alone.
2. **Hierarchy.** At any moment one thing matters most and it reads first (size, contrast, position,
   motion). Secondary information is quieter. If everything is loud, nothing is.
3. **Restraint.** Minimal chrome over the world; the game world is the hero. Loudness (big type, flashes,
   shake, bloom, music swells) is spent on payoff moments only.
4. **Readability.** Text at least ~14 dp on a phone canvas, contrast >= 4.5:1 for body text, nothing
   under the Roblox top-bar keep-out, nothing clipped, nothing overlapping unintentionally, safe areas
   respected on phone and desktop.
5. **Native to Roblox.** Built from Roblox parts, R15 avatars, Roblox lighting, the platform's input
   conventions (touch, mouse+keyboard, gamepad); art that looks like it belongs in a top Roblox game, not
   stock illustrations pasted in.
6. **Feedback everywhere.** Every input answers within 100 ms (visual + audio); every state change is shown
   (press, hover, disabled, selected, reward, damage, success, failure).
7. **Motion with intent.** Easing (never linear for UI), anticipation and follow-through, staggered
   entrances, consistent durations from the motion tokens.
8. **Cohesion across the game.** The title screen, HUD, menus, world, VFX and sounds feel made by one
   team for one game.
9. **Verified by looking.** Nothing is done until it has been captured and judged. Code that "should"
   look right is not evidence.

## Severity
- **blocker**: broken, unreadable, overlapping, clipped, off-screen, placeholder, crashes, contradicts the
  style guide, missing a required piece.
- **major**: clearly below the bar for this aspect (weak hierarchy, generic, no feedback, flat lighting).
- **minor**: noticeable polish issue (spacing, timing, colour drift).
- **nit**: taste-level refinement.
