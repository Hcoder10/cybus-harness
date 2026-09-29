# Texture specs: art as data

No image generation, no uploads: custom art (panel and button skins, soft shadows, glows, icons built from
shapes, particle and beam textures, rings, bursts, streaks) is painted with `paint_texture(name, spec)`. The
spec is JSON: layered shapes, each with one paint and optional effects. The harness renders it, shows you the
result (over a checkerboard, stretched as a 9-slice when it has one, tinted when it is LA), and packs it into the
game. In the game, `Textures.apply(instance, name)` (ReplicatedStorage.Kit.Textures) shows it. Look at every
texture you paint and repaint it (same name) until it matches the style guide.

## Canvas

```
{"size": [w, h], "format": "RGBA", "slice": [x0, y0, x1, y1], "supersample": 4, "layers": [ ... ]}
```

| key | value |
|---|---|
| `size` | `[width, height]`, each 8..1024 (required) |
| `format` | `"RGBA"` (default) or `"LA"`: white/grey + alpha, coloured in the game by `ImageColor3` (labels) or `Color` (ParticleEmitter, Beam, Trail). Paint LA textures in white and shape them with alpha. |
| `slice` | the 9-slice centre rectangle `[x0, y0, x1, y1]` in whole pixels (Roblox `SliceCenter`: the edges of the stretchable middle, not insets). `Textures.apply` sets it on labels whose `ScaleType` is `Slice`. |
| `supersample` | 1..8, default 4: anti-aliasing. Large textures are supersampled less automatically. |
| `layers` | 1..64 layers, drawn in order (first = bottom) |

Coordinates are pixels: `(0, 0)` is the top-left corner, x grows right, y grows down, pixel `i` covers `[i, i+1]`.
Shape angles (arc `start`/`end`, star and rays `rotation`) are degrees clockwise from 12 o'clock. Layer `rotate`
is degrees clockwise about the shape's centre. A layer may carry a `note` (ignored).

## Shapes

Every layer has `"shape"` plus that shape's keys. `box` is `[x0, y0, x1, y1]` (left, top, right, bottom).
Unset `box` / `center` mean the whole texture / its centre.

| shape | keys (defaults) |
|---|---|
| `fill` | the whole texture; takes only a paint, `noise`, `opacity`, `blend` |
| `rect` | `box` |
| `rounded_rect` | `box`, `radius` or `radii: [top_left, top_right, bottom_right, bottom_left]` (radii shrink to fit) |
| `ellipse` | `box`, or `center` + `radius` (a number or `[rx, ry]`) |
| `circle` | `center`, `radius` (half the shorter side) |
| `ring` | `center`, `outer` (or `radius`), `inner`: radii in px, inner < outer |
| `polygon` | `points: [[x, y], ...]` (3..512) |
| `star` | `center`, `radius` (outer), `points` (5), `inner` (0.5: inner radius as a fraction), `rotation` (0: first point up) |
| `line`, `polyline` | `points` (2..512), `width`, `taper` (the width at the last point; default = width; 0 = a point), `cap`: `"round"` (default) or `"flat"`, `smooth` (false; true = a curve through the points) |
| `arc` | `center`, `radius`, `start` (0), `end`, `width`, `taper` (width at `end`), `cap` (`"round"`); at most 360 degrees |
| `rays` | a burst of spokes: `center`, `count`, `inner` (0), `outer`, `width` (4, at the inner end), `taper` (0: pointed tips; wider than `width` for wedges), `rotation` (first ray, 0 = up), `cap` (`"flat"`), `jitter` (0..1: random shorter rays), `seed` |

A layer needs a paint, a `stroke`, or both. A stroke with no paint draws just the outline.

## Paint (one per layer, and for strokes)

- `"color": "#RRGGBB"` or `"#RRGGBBAA"` (AA = alpha: `"#00000080"` is half-transparent black).
- `"linear": {"angle": 90, "stops": [[0, "#6BE39B"], [1, "#35B96B"]]}`: across the shape's bounding box
  (the texture for `fill`). `angle` 0 = left to right, 90 = top to bottom (default), 180 = right to left, 270 =
  bottom to top. `stops` are `[position 0..1, colour]` (1..16), or plain colours spaced evenly.
- `"radial": {"stops": [...], "center": [x, y], "radius": r or [rx, ry]}`: from the centre (default: the
  shape's centre) out to `radius` (default: half the bounding box on each axis); past it, the last stop.
- Stops blend with their alpha, so fading a colour out to any fully transparent stop keeps its hue (no dark or
  grey fringe): `[[0, "#FF5A3C"], [1, "#00000000"]]` fades red to nothing.
- `"noise": {"amount": 0.15, "scale": 8, "octaves": 3, "seed": 0, "target": "color"}` modifies the layer's
  paint: `"color"` jitters brightness (grain, stone, fabric), `"alpha"` breaks up the alpha (smoke, dust,
  grunge). `scale` is the cell size in px. Deterministic for a given seed.

## Effects (per layer)

| key | what |
|---|---|
| `opacity` | 0..1, the whole layer including its shadow and glow |
| `blur` | px (Gaussian): softens the layer itself (soft blobs, light bloom, motion) |
| `rotate` | degrees clockwise about the shape's centre (gradients turn with it) |
| `blend` | `"normal"`, `"add"` (light: sparks, glows), `"multiply"` (shade), `"screen"` (soft lighten) |
| `stroke` | `{"width": 2, "color": "#FFFFFF", "align": "inside"}`; `align`: `inside` (default), `center`, `outside`; `linear` / `radial` instead of `color` for a gradient rim |
| `shadow` | beneath the layer: `{"offset": [0, 2], "blur": 4, "color": "#00000080", "spread": 0}`; `spread` grows (or with a negative value shrinks) the shape first. A list stacks shadows: a wide soft one plus a tight dark one reads as real depth. |
| `glow` | beneath the layer: `{"blur": 8, "color": "#FFFFFF", "strength": 1, "spread": 0}`; `strength` above 1 makes it denser |
| `inner_shadow` | inside the fill: `{"offset": [0, 2], "blur": 3, "color": "#00000066"}`. A dark one with a +y offset shades the top inside edge (pressed, recessed); a light one with a +y offset is a top rim highlight; a -y offset shades the bottom |

`shadow`, `glow` and `inner_shadow` take one object or a list of up to 4. Order inside a layer: shadows, glows,
then fill, inner shadows, stroke; `blur` and `opacity` apply to the layer, then it is blended onto the layers below.

## Craft

- Keep everything inside the canvas: leave a margin of about the shadow offset plus 2-3 times its blur, or the
  texture edge cuts it off. The same for glows.
- 9-slice skins stay small (64-160 px). The centre rectangle must start after each corner's radius, shadow and
  rim, and the stretched middle band should not change along the stretch direction. Scale corners in the game
  with `SliceScale`, not by painting bigger.
- Pixel-crisp detail: put hard edges on whole pixels (box edges at integers, strokes `inside`).
- One light direction across the whole set: highlights on top edges, shadows falling down.
- Particles, beams and glows: paint them LA in white, fade the alpha to 0 before the texture edge (or the square
  shows), and colour them in the game.
- Variants (hover, pressed, disabled, selected) are separate textures with the same size and slice, so swapping
  them never moves the layout.
- Memory: each texture in use costs w x h x 4 bytes of the EditableImage budget (about 70 MB on desktop, less on
  phones): 256 x 256 is 256 KB. Share one texture across many labels, prefer 9-slices to big images, and
  `Textures.release(name)` what a closed screen no longer shows.

## Examples

### 9-slice panel skin: soft drop shadow and a rim highlight

Two stacked shadows (wide and soft, tight and dark), a vertical body gradient, a faint inner shade at the
bottom, and a second layer that is only a stroke: a rim that is bright at the top and fades down.

```json
{"size": [128, 128], "slice": [44, 44, 84, 84], "layers": [
  {"shape": "rounded_rect", "box": [16, 12, 112, 108], "radius": 22,
   "linear": {"angle": 90, "stops": [[0, "#2E384C"], [1, "#1E2533"]]},
   "shadow": [{"offset": [0, 6], "blur": 9, "color": "#00000055"},
              {"offset": [0, 2], "blur": 2.5, "color": "#00000066"}],
   "inner_shadow": {"offset": [0, -3], "blur": 4, "color": "#0000002E"}},
  {"shape": "rounded_rect", "box": [16, 12, 112, 108], "radius": 22,
   "stroke": {"width": 1.5, "align": "inside",
              "linear": {"angle": 90, "stops": [[0, "#FFFFFF59"], [0.45, "#FFFFFF10"], [1, "#FFFFFF08"]]}}}
]}
```

### Tintable radial glow (LA) for particles

White with a soft alpha falloff that reaches 0 before the edge; the emitter's `Color` tints it.

```json
{"size": [64, 64], "format": "LA", "layers": [
  {"shape": "fill",
   "radial": {"stops": [[0, "#FFFFFFFF"], [0.2, "#FFFFFFC0"], [0.55, "#FFFFFF38"], [1, "#FFFFFF00"]]}}
]}
```

### Icon built from shapes

A dial: a dark rim circle with a drop shadow, a face with an off-centre radial highlight and an inside stroke,
twelve tick marks from `rays`, two tapered hands and a hub.

```json
{"size": [96, 96], "layers": [
  {"shape": "circle", "center": [48, 50], "radius": 38, "color": "#1B2130",
   "shadow": {"offset": [0, 3], "blur": 3, "color": "#00000070"}},
  {"shape": "circle", "center": [48, 48], "radius": 36,
   "radial": {"center": [40, 36], "radius": 48, "stops": [[0, "#FFFFFF"], [1, "#DCE3EE"]]},
   "stroke": {"width": 4, "align": "inside", "color": "#39465E"}},
  {"shape": "rays", "center": [48, 48], "count": 12, "inner": 24, "outer": 29, "width": 2.5, "taper": 2.5,
   "cap": "round", "color": "#8793A8"},
  {"shape": "line", "points": [[48, 48], [48, 26]], "width": 5, "taper": 3.5, "color": "#39465E"},
  {"shape": "line", "points": [[48, 48], [63, 57]], "width": 4, "taper": 3, "color": "#E0533D"},
  {"shape": "circle", "center": [48, 48], "radius": 4.5, "color": "#39465E"}
]}
```

### Button skin with a pressed variant

The normal button is a lip (darker, 5 px lower) under a lit face with a light inner-shadow rim on top. The
pressed button moves the face down onto the lip, darkens it, and shades its top edge. Same size and slice.

`button_primary`:

```json
{"size": [128, 56], "slice": [24, 24, 104, 32], "layers": [
  {"shape": "rounded_rect", "box": [4, 8, 124, 52], "radius": 16, "color": "#1F7A45",
   "shadow": {"offset": [0, 2], "blur": 2, "color": "#00000059"}},
  {"shape": "rounded_rect", "box": [4, 3, 124, 47], "radius": 16,
   "linear": {"angle": 90, "stops": [[0, "#6BE39B"], [1, "#35B96B"]]},
   "inner_shadow": {"offset": [0, 2], "blur": 1, "color": "#FFFFFF66"}}
]}
```

`button_primary_pressed`:

```json
{"size": [128, 56], "slice": [24, 24, 104, 32], "layers": [
  {"shape": "rounded_rect", "box": [4, 8, 124, 52], "radius": 16, "color": "#1F7A45",
   "shadow": {"offset": [0, 1], "blur": 1, "color": "#00000059"}},
  {"shape": "rounded_rect", "box": [4, 7, 124, 51], "radius": 16,
   "linear": {"angle": 90, "stops": [[0, "#4FCB82"], [1, "#2FA35E"]]},
   "inner_shadow": {"offset": [0, 2], "blur": 2, "color": "#0000003D"}}
]}
```

## In the game

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Textures = require(ReplicatedStorage.Kit.Textures)

local panel = Instance.new("ImageLabel")
panel.BackgroundTransparency = 1
panel.ScaleType = Enum.ScaleType.Slice      -- before apply(), so it also sets SliceCenter
Textures.apply(panel, "panel_skin")

emitter.Color = ColorSequence.new(Color3.fromRGB(255, 170, 70))
Textures.apply(emitter, "glow_soft")         -- LA: the emitter's Color tints it

button.ScaleType = Enum.ScaleType.Slice
Textures.apply(button, "button_primary")
button.MouseButton1Down:Connect(function()
	Textures.apply(button, "button_primary_pressed") -- and nudge the label down with the face (4-5 px)
end)
button.MouseButton1Up:Connect(function()
	Textures.apply(button, "button_primary")
end)
```

`Textures.apply` returns false (and warns once) when the texture is missing or the image memory is spent, so
keep a plain fallback look (a background colour or UICorner frame) under textured elements.
