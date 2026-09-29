# Roblox craft notes for builders

How the rubrics' qualities are actually built on Roblox. Use the game's style guide values; these are
techniques, not a style.

## Project shape
- Server logic in ServerScriptService, client logic in StarterPlayerScripts / StarterGui, shared modules in
  ReplicatedStorage (Tokens, Net, UI kit, Sound, Camera, VFX helpers). Remotes created by the server in one
  place and validated on every server handler.
- One `Tokens` ModuleScript holds palette, type, spacing, radii, motion durations/easings, sound ids: every
  script reads from it; no magic numbers elsewhere.
- Clean up: disconnect connections and destroy instances on state exit (a small maid / janitor pattern).

## UI
- One ScreenGui per layer (HUD, menus, overlays, loading) with `ResetOnSpawn = false`,
  `ZIndexBehavior = Sibling`, and a `ScreenInsets` / `IgnoreGuiInset` choice made on purpose; read
  `GuiService:GetGuiInset()` to keep clear of the top bar.
- Design on a 1920x1080 canvas, then one `UIScale` per ScreenGui = viewport short side / 1080 (clamped),
  updated on `Camera:GetPropertyChangedSignal("ViewportSize")`. Positions and sizes in offsets from the
  spacing scale, anchored with AnchorPoint.
- Depth: `ImageLabel` with `ScaleType = Slice`, `SliceCenter`, `SliceScale` for textured panels and soft
  shadows; `UIGradient` for bodies and sheens; `UIStroke` (ApplyStrokeMode Border for frames, Contextual for
  text) for rims and outlines; `UICorner` from the radius tokens.
- Layout: `UIListLayout` / `UIGridLayout` with padding tokens, `UIPadding` inside panels, `AutomaticSize`
  for content-sized containers, `UIAspectRatioConstraint` for cards, `UISizeConstraint` for limits.
- Type: `FontFace = Font.new(family, weight, style)`; TextSize is the LINE height, not the em size, so faces
  differ visibly at the same TextSize; use `TextScaled` only with a `UITextSizeConstraint`; `TextTruncate`
  and `TextWrapped` for long strings; `RichText` for inline emphasis.
- Motion: `TweenService:Create(obj, TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
  goal)`; stagger children with small delays; press = scale 0.94 via a UIScale on the button, then back with
  Back easing.
- 3D in UI: `ViewportFrame` with a WorldModel, a posed model, a Camera, lighting via Ambient / LightColor /
  LightDirection, for portraits, items and hero art.
- Art without uploads: paint textures with paint_texture (a layered-shape spec: panel and button skins with
  soft shadows and rims, glows, icons built from shapes, particle / beam textures) and apply them with
  `Textures.apply(guiOrEmitter, name)` (ImageContent / TextureContent from EditableImages). Paint tintable
  textures in LA (white + alpha) and colour them with ImageColor3 / the emitter's Color. Icons as one set.

## Camera
- A camera module bound with `RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 1, fn)`,
  or `CameraType = Scriptable` for authored shots; springs / exponential smoothing using delta time
  (`alpha = 1 - math.exp(-k * dt)`).
- Collision: raycast from the focus to the desired camera position and pull in before geometry.
- Shake as a decaying offset (noise * amplitude * decay) added after smoothing; a reduce-motion setting
  scales it to zero. FOV changes tweened.

## Feel and VFX
- Client-first feedback: play the animation, sound and effect locally on input; the server validates and
  replicates to others.
- Hit-stop: briefly slow the local animation tracks (AdjustSpeed) and hold the camera for 40-120 ms.
- `ParticleEmitter`: Color / Size / Transparency sequences, Lifetime and Speed ranges, `LightEmission`,
  `LightInfluence`, `Brightness`, `ZOffset`, `Drag`, `Acceleration`, `Squash`, flipbooks
  (`FlipbookLayout`, `FlipbookMode`, `FlipbookFramerate`), `:Emit(n)` for bursts with `Rate = 0`.
- `Beam` and `Trail` between Attachments for arcs, slashes, speed lines; `Highlight` for outlines;
  short-lived `PointLight` for flashes; `Debris:AddItem` or explicit cleanup after the max lifetime.
- Screen effects: `ColorCorrectionEffect` / `BloomEffect` / `BlurEffect` tweened briefly for payoffs;
  UI flashes and vignettes as ImageLabels.

## Animation
- `Animator:LoadAnimation(animation)`; set `Priority`; `Play(fadeTime, weight, speed)`; `AdjustSpeed` to
  match movement speed; markers (`GetMarkerReachedSignal`) to sync sounds and VFX to contact frames.
- Animations must be assets the game can load. In a session without uploads, procedural animation (tweening
  or springing Motor6D transforms / CFrames in `RunService` steps) is the fallback; newer rigs may use
  AnimationConstraint instead of Motor6D, so check the rig before writing to joints.
- Object motion: bob / spin / squash with TweenService; collect = scale bounce + burst + fade.

## World and lighting
- In Studio edit mode set `Lighting.Technology` (Future for local light shadows), `ClockTime`,
  `GeographicLatitude`, `Brightness`, `Ambient` / `OutdoorAmbient`, `EnvironmentDiffuseScale` /
  `EnvironmentSpecularScale`, plus `Atmosphere` (Density, Offset, Color, Decay, Glare, Haze), a `Sky`,
  `ColorCorrectionEffect`, `BloomEffect` (subtle), `SunRaysEffect`, and `DepthOfFieldEffect` only if it helps.
- Build from a small kit of props in one style; `MaterialVariant`s or consistent materials; anchor
  everything static; `CastShadow = false` on tiny props; `StreamingEnabled` for large maps.
- Hide world edges with terrain, water, fog, or walls; no visible baseplate.

## Audio
- `SoundGroup`s (Music, SFX, UI, Ambience) under SoundService with volumes; every Sound assigned to one.
- 3D sounds parented to parts / attachments with `RollOffMode` and min / max distances; UI and music 2D.
- Variation: `PlaybackSpeed` randomised +-5-10%; a small pool per event.
- Ducking: tween the music group's volume, or a `CompressorSoundEffect` with `SideChain` from the SFX group.
- Find sounds with search_audio (public Creator Store audio, usable by id); verify every id loads
  (`Sound.IsLoaded`, `TimeLength > 0`); 2-3 ids per event for variation.

## Robustness
- `ReplicatedFirst` loading screen (`RemoveDefaultLoadingScreen`) with `ContentProvider:PreloadAsync`.
- DataStores inside pcall with retries and `UpdateAsync`; never trust client values for currency or score.
- `WaitForChild` with timeouts where the child may never come; no busy waits; `task.wait` / `task.spawn`.
