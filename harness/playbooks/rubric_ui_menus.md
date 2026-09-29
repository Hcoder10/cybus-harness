# UI: menus and screens

Covers the title / main menu, shop, inventory, upgrades, settings, results, dialogs, and the loading screen.

## Capture
- Every screen at desktop (1920x1080) and phone landscape (~844x390 dp), with real content filled in.
- States on one sheet: hover, pressed, selected, disabled, empty (nothing owned, no money, long names).
- A frame strip (6-8 frames over ~0.6 s) of a screen opening and of a primary button press.

## Anchors
- **1-2**: default TextButtons and grey Frames, default fonts, clipped or overlapping text, elements off-screen.
- **4**: consistent colours but flat rounded rectangles, one font at one weight, everything centred in a
  column, no depth, no states, emoji or mismatched icons, text either huge or tiny.
- **7**: a custom visual language (shape language, depth recipe, textured or gradient panels), a clear
  primary action, spacing from a grid, visible states, eased transitions, a coherent icon set, readable on
  a phone.
- **9**: every screen feels authored: a composition with a focal point (hero art, character, item render),
  layered depth, choreographed motion with staggered children, a sound on every interaction, and the menu
  itself sells the fantasy of the game.

## Checks (each failure is an issue)
1. **Primary action reads in under a second.** One primary button per screen, visually dominant (size,
   accent colour, position); secondary actions quieter; destructive actions separated.
2. **Composition.** A focal point and deliberate negative space; not a stack of equal boxes. Related items
   grouped (proximity), unrelated items separated.
3. **Depth.** Raised elements use the style guide's depth recipe (shadow, gradient body, rim light,
   texture). A plain single-colour rectangle with UICorner is a major issue at the 7+ bar.
4. **Type.** Faces and sizes from the type scale; display face for titles only; body text at least ~14 dp on
   phone; no stretched or TextScaled text without a UITextSizeConstraint; no default legacy fonts unless the
   style guide chose them.
5. **Grid and alignment.** Margins and gaps from the spacing scale; edges align; consistent padding inside
   every panel; nothing touching a panel edge.
6. **Icons.** One family (same stroke, fill, corner, perspective); no emoji; icons paired with labels where
   meaning is not obvious.
7. **States.** Hover, pressed, selected, disabled and focus (gamepad) all look different; selection is
   unmistakable.
8. **Motion.** Screens enter and exit with eased motion from the motion tokens (fade + short slide or
   scale), children staggered; no linear tweens; no pop-in.
9. **Scale and safe areas.** Works at phone and desktop; nothing inside the Roblox top-bar keep-out;
   touch targets >= 44 dp; no clipping at either size.
10. **Content.** Real names, prices, stats and art; empty states designed (not a blank grid); long text
    truncates or wraps cleanly; numbers formatted (1,250 / 1.2K).
11. **Backdrop.** Menus sit on an authored backdrop, a blurred / dimmed world, or a composed 3D scene, never
    floating unintentionally over raw gameplay.

## Common failures -> fixes
- Grey-box UI -> apply the depth recipe and palette tokens; add a textured or gradient body and a rim.
- Everything the same size -> establish hierarchy: one hero element, one primary button, quieter rest.
- Accent colour everywhere ("Christmas tree") -> accent only on the primary action and key numbers.
- Mixed corner radii and stroke weights -> use the tokens everywhere.
- Offset black frame as a "shadow" -> a soft 9-slice shadow image or layered transparency.
- Tiny text on phone -> raise body size, reduce copy, move secondary info into a details view.
