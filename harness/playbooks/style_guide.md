# Style guide template (write this before building anything)

The style guide is the contract every builder and judge works against. Fill every section with
CONCRETE values (hex codes, sizes, durations, names), never adjectives alone. Keep it to about two pages.

## 1. Direction
- One line: what the game should feel like, in player terms ("a warm, cosy harbour at dusk; slow,
  satisfying, tactile"; "neon speed, loud and sharp, every surface reflects").
- Three reference takeaways: what to take from each reference (a top Roblox game, a console game, a film
  or art style). Takeaways are principles ("chunky rounded panels with a hard drop shadow"), not assets.
- Words to avoid: the three ways this could go wrong ("generic sci-fi grey", "cluttered", "cute but flat").

## 2. Canvas and layout
- Design canvas: 1920x1080 dp (desktop) scaled by one UIScale from the viewport's short side; phone check
  at ~900 dp tall. Safe areas: never place UI inside the Roblox top-bar keep-out (the top-left ~212x58 dp)
  or under the phone notch; keep interactive targets >= 44 dp.
- Grid: an 8-dp spacing scale (4, 8, 12, 16, 24, 32, 48, 64). Every margin and gap comes from it.
- Screen regions: where the HUD lives (corners), where prompts appear, what stays clear (centre action).

## 3. Colour
- Tokens with roles: background, surface, surface-raised, text, text-muted, primary accent, secondary
  accent, success, warning, danger, rarity or team colours if any. Give hex values.
- Accent rule: which one accent carries "act here" (primary buttons, key info), how much of the screen it
  may cover (usually < 10%), and where it is forbidden.
- Contrast: body text >= 4.5:1 against its surface; check light and dark areas of the world behind UI.

## 4. Type
- Faces (Roblox FontFace names) for display, headings, body, numbers. Roblox TextSize is the LINE
  height, not the em size: account for it when matching sizes across faces.
- Scale: display / h1 / h2 / body / caption / numeric sizes in dp, weights, letter-spacing, case rules.
- Rules: at most two faces; numbers in a tabular/numeric face where they change.

## 5. Shapes and depth
- Shape language: corner radii (or a slanted "house angle"), border weights, how panels, buttons, cards and
  icons are built (9-slice textures with SliceCenter / SliceScale, UIStroke, UICorner, UIGradient).
- Depth recipe: the layers every raised element uses (e.g. soft shadow, gradient body, 1-dp rim light,
  glyph, state glow) and how selected / pressed / disabled change it.
- Iconography: one style (filled vs outline, stroke width, corner treatment), generated or drawn as a set.

## 6. Motion tokens
- Durations: fast (0.12 s), base (0.2 s), slow (0.35 s), dramatic (0.6 s+) — adjust per game.
- Easing: entrances ease-out (Quint/Back small overshoot), exits ease-in, never Linear for UI.
- Patterns: press (scale 0.94 -> 1 with a click), hover lift, panel entrance (fade + 12-24 dp slide,
  children staggered 30-50 ms), number roll-ups, reward bursts.

## 7. Camera language
- Default gameplay camera: type, FOV, distance, height, offset, smoothing, collision behaviour.
- Signature shots: when the camera leaves default (intro, reward, boss, finish line) and how (dolly, cut,
  shake budget, FOV kick), plus limits (no shake over 0.3 s outside payoffs, never lose the player).

## 8. VFX language
- Palette and layering: the value hierarchy every effect uses (where the brightest part sits, the body
  colour, the contrast layer that makes it read on this game's backgrounds); rendering style (painterly,
  cel, pixel, realistic, graphic); particles vs beams vs meshes vs screen effects; lifetime rules.
- Budget: what is allowed on screen at once; which moments earn big effects.

## 9. World and lighting
- Lighting: Technology (Future), time of day, ClockTime, ambient/outdoor ambient, Atmosphere density/haze,
  ColorCorrection, Bloom, SunRays, Depth of field if any — concrete values.
- Materials and palette of the world; scale (studs per metre, avatar height ~5-6 studs); landmarks and
  silhouettes; how the world frames the play space.

## 10. Audio
- Mood and music per state (menu, explore, tension, reward); UI sounds (hover, press, confirm, error);
  gameplay cues; layering rules (transient + body + tail); loudness ladder.

## 11. References board
- Generated mockups / concept frames for the key screens and moments (image generation), each judged and
  approved before building. They are targets, not assets to paste in.
