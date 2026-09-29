# Animation clips (Kit.Anim)

Games here ship without uploaded assets, so custom character animation cannot use Animation assets. You author
clips as data with `author_clip(name, spec)`: it checks the clip (every problem at once), packs it into
`ReplicatedStorage.Shared.ClipPack`, and shows you a contact sheet (front and side view of an R15 figure per
frame, hand and foot trails, a timeline with keys and markers). `ReplicatedStorage.Kit.Anim` plays the clips on any
rig whose joints are Motor6Ds. Look at every sheet: if a pose does not read there, it will not read in the game.

## Clip format

```json
{
  "length": 0.8, "looped": false, "priority": "action",
  "keys": [
    {"t": 0, "pose": {"RightShoulder": [0, 0, 5], "RightElbow": [10, 0, 0]}},
    {"t": 0.3, "ease": "quadOut", "pose": {"RightShoulder": [-40, 0, 20], "RightElbow": [90, 0, 0]}},
    {"t": 0.4, "ease": "expoIn", "pose": {"RightShoulder": [110, 0, 10], "RightElbow": [15, 0, 0]}},
    {"t": 0.8, "ease": "sine", "pose": {"RightShoulder": [0, 0, 5], "RightElbow": [10, 0, 0]}}
  ],
  "markers": [{"t": 0.4, "name": "hit"}]
}
```

| field | meaning |
|---|---|
| `length` | seconds, 0.05 to 60 |
| `looped` | `true` for cycles (idle, walk, run), `false` for one-shots (default) |
| `priority` | `core` < `idle` < `movement` < `action`; default `idle` when looped, else `action` |
| `rig` | `"R15"` (default: R15 joint names, limits checked) or `"custom"` (any Motor6D names) |
| `keys` | `{t, pose, ease}` in increasing `t`; the first at `t = 0` |
| `pose` | `{Joint: [rx, ry, rz]}` or `{Joint: [rx, ry, rz, px, py, pz]}`: degrees, then studs |
| `ease` | how the motion arrives at this key (see Easing); default `sine` |
| `markers` | `{t, name}`: events for sound, VFX and hitboxes at exact frames |

- A key poses only the joints it lists. Each joint's curve runs through the keys that pose it, so leaving a joint
  out of a key lets it keep moving between its own keys: that is how you offset joints for overlap.
- One-shot: a joint not posed at `t = 0` starts from rest at `t = 0`; every joint holds its last key to the end,
  and the clip holds its last pose while it fades out. Pose everything you move in the first and last keys.
- Looped: the last key is at `t = length` and repeats the `t = 0` pose (for joints in both); every curve wraps
  round the loop, so offset joints loop seamlessly too.
- Two keys of the same joint must differ by less than 180 degrees on each axis: the runtime turns the short way
  round, so a bigger change goes the other way. Add a key in between (a full spin takes three steps of 120).

## Axes and signs

Every value is relative to the rest pose (standing straight, arms hanging at the sides, facing forward), in the
character's own axes at rest: **X = its right, Y = up, Z = back** (it faces -Z). The rotation is
`CFrame.Angles(rx, ry, rz)`: turn rz about Z, then ry about Y, then rx about X, all about the parent's axes. Each
joint's rotation is relative to its parent, so an elbow bends relative to the upper arm wherever the arm points.

- **rx** (pitch): + swings a hanging limb FORWARD (and on up); + tips an upright part (spine, head) BACK.
- **ry** (yaw): + turns toward the character's LEFT (counter-clockwise seen from above). On a hanging limb it
  twists the limb about its own length.
- **rz** (roll): + swings a hanging limb toward the character's RIGHT; + tilts an upright part to its LEFT.
- Mirror a pose left <-> right: swap the Left / Right joint names and negate ry and rz (keep rx); for Root, Waist
  and Neck negate ry, rz and px.
- Use one main axis per joint where you can; combine them sparingly.

| joint | moves | rx + | ry + | rz + | limits rx / ry / rz |
|---|---|---|---|---|---|
| Root | the whole body, pivot at the hips; px py pz move it | tips the body back (- pitches forward) | turns the body left | rolls the body to its left | any / any / any, move 12 studs |
| Waist | chest, arms, head | arches back (**- bends forward**) | twists the chest left | bends to its left side | -80..45 / -60..60 / -45..45 |
| Neck | head | looks up (**- looks down**) | looks left | tilts the head to its left shoulder | -60..60 / -85..85 / -45..45 |
| RightShoulder | right upper arm | raises it forward: 90 points forward, 180 straight up; - swings it back | twists it | raises it out to the RIGHT side: 90 = T-pose; - across the body | -80..190 / -100..100 / -60..190 |
| LeftShoulder | left upper arm | same as the right | twists it | **-** raises it out to the LEFT side: -90 = T-pose; + across | -80..190 / -100..100 / -190..60 |
| Right/LeftElbow | forearm | **bends the elbow** (forearm forward and up); 0 is straight | twists the forearm | keep near 0 | -5..155 / -100..100 / -15..15 |
| Right/LeftWrist | hand | bends the hand forward | twists it | swings it toward the right | -80..80 / -60..60 / -80..80 |
| RightHip | right thigh | swings the leg forward (step, kick, knee up); - back | turns the toes left | swings the leg out to the RIGHT | -60..130 / -60..60 / -35..70 |
| LeftHip | left thigh | same as the right | turns the toes left | **-** swings the leg out to the LEFT | -60..130 / -60..60 / -70..35 |
| Right/LeftKnee | shin | **NEGATIVE bends the knee** (shin swings back); + is the wrong way | keep near 0 | keep near 0 | -160..5 / -20..20 / -15..15 |
| Right/LeftAnkle | foot | lifts the toes (- points them down) | turns the toes left | rolls the foot | -65..45 / -35..35 / -35..35 |

Other joints (on the default rig) may take small offsets (up to 1 stud); only Root moves far. Root offsets move the
feet with the body, so moving Root sideways or forward slides planted feet: use it for bobs, crouches and dips.

**Pose recipes** (checked by forward kinematics):
- Arm pointing forward: Shoulder `[90, 0, 0]`. Straight up: `[180, 0, 0]`. Out to the side: Right `[0, 0, 90]`,
  Left `[0, 0, -90]`. Swung back: `[-50, 0, 0]`. Forward and across the chest: Right `[90, 0, -20]`, Left `[90, 0, 20]`.
- Cocked arm (upper arm out to the side, forearm up: throw, wave, flex): Right Shoulder `[90, 0, 90]` + Elbow
  `[100, 0, 0]`; Left Shoulder `[90, 0, -90]` + Elbow `[100, 0, 0]`. (With the arm out to the side, rx twists it,
  which turns the elbow's bend upward.)
- Crouch with planted feet: keep each foot flat with `Ankle rx = -(Hip rx + Knee rx)` and drop Root:

  | Hip rx | Knee rx | Ankle rx | Root py |
  |---|---|---|---|
  | 15 | -30 | 15 | -0.06 |
  | 30 | -60 | 30 | -0.23 |
  | 45 | -90 | 45 | -0.51 |
  | 60 | -120 | 60 | -0.87 |

- On the toes: Ankle `[-20, 0, 0]` and Root py `+0.18`.
- Jumps and falls: the Humanoid's physics moves the root part through the air; the clip shapes the body (crouch,
  extend, tuck, reach, absorb) with small Root offsets. The sheet's ground line is where the feet stand when the
  root part is at rest, and author_clip reports keys where a foot sinks into it or both feet leave it.

## Easing

`ease` belongs to the key the motion arrives at, and says how it gets there:

| ease | motion into the key | use it for |
|---|---|---|
| `linear` | constant speed | mechanical motion, the middle of a long arc |
| `sine`, `quad`, `cubic`, `expo` | slow out of the previous key AND slow into this one (sharper in that order) | moving from one held pose to another |
| `<style>In` (e.g. `quadIn`, `expoIn`) | starts slow, arrives FAST | strikes, drops, the frame that hits (accelerate into the impact) |
| `<style>Out` (e.g. `quadOut`, `expoOut`) | starts fast, arrives SLOW | settles, the top of a jump, recoil (the snap then the drift) |
| `back`, `backIn`, `backOut` | overshoots (`backOut`: past the key and back; `backIn`: pulls back first) | snappy poses, springy settles |

`In` / `Out` mean what `Enum.EasingDirection` means in TweenService. Timing: at 60 fps a frame is 0.017 s; a fast
strike moves in 2-4 frames (0.03-0.07 s), anticipation takes 0.1-0.3 s, a settle 0.2-0.5 s.

## Priorities, blending and markers

- Per joint, a higher priority overrides the lower ones by its weight; the same priority mixes by weight. Only the
  joints a clip poses are affected: an arm-only `action` over a `movement` walk keeps the legs walking.
- `play(name, {fade = 0.15})` blends in; a one-shot holds its last pose while it fades out (`fadeOut`, default
  `fade`); `track:stop(fade)` blends out. `{hold = true}` keeps a one-shot's last pose until stopped.
- Put markers on contact frames (the key where a strike lands, a foot plants, an object is released), then sync:
  `track.Marker("hit"):Connect(function() Sound.play("hit"); Shake.kick(0.3) end)`.

## Playing clips (Kit.Anim)

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Anim = require(ReplicatedStorage.Kit.Anim)

local rig = Anim.load(character)                  -- once per character (cached); any Motor6D rig
local run = rig:play("run_cycle")                 -- looped: calling play again returns the same track
local speed = humanoid.RootPart.AssemblyLinearVelocity.Magnitude
run:adjustSpeed(speed / 16)                       -- 16 = the speed the cycle was authored for: no foot sliding
local swing = rig:play("sword_swing", { fade = 0.08 })
swing.Marker("hit"):Connect(function() Sound.play("slash_hit") end)
swing.Ended:Connect(function() end)               -- after it fades out
rig:stopAll(0.2)
```

- Kit.Anim blends over Roblox's Animator: joints your clips do not pose keep the default animation. For full
  control while clips play, `rig:takeOver(true)` pauses the rig's own AnimationTracks and restores them after.
- Procedural layers, alone or on top of clips: `rig:lean(1)` (into turns, from the velocity),
  `rig:lookAt(part or position)` / `rig:lookAt(nil)`, `rig:breathe(true)`, `rig:recoil("RightShoulder", {-25, 0, 0},
  0.3)` for hits and shots, `rig:squash(0.3)` for a blobby rig with a SpecialMesh.
- Motor6D.Transform does not replicate. Play clips on the client: for everyone to see another character's clip,
  the server fires a RemoteEvent (character, clip name) and every client plays it on that character.
- Clips can also be registered from code: `Anim.register({ name = "wave", length = 1, keys = { ... } })`.

## Examples

Each block is a complete `spec` for `author_clip(name, spec)`.

### `idle_breath`
A looped idle: the chest rises and the head stays level, and the arms follow a quarter second later (overlap:
the shoulder and elbow keys are offset from the waist keys).

```json
{
  "length": 2.4, "looped": true, "priority": "idle",
  "keys": [
    {"t": 0, "pose": {
      "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 4], "RightElbow": [8, 0, 0],
      "LeftShoulder": [0, 0, -4], "LeftElbow": [8, 0, 0]
    }},
    {"t": 1.1, "ease": "sine", "pose": {"Waist": [3, 0, 0], "Neck": [-2.5, 0, 0]}},
    {"t": 1.35, "ease": "sine", "pose": {
      "RightShoulder": [0, 0, 7], "RightElbow": [12, 0, 0], "LeftShoulder": [0, 0, -7],
      "LeftElbow": [12, 0, 0]
    }},
    {"t": 2.4, "ease": "sine", "pose": {
      "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 4], "RightElbow": [8, 0, 0],
      "LeftShoulder": [0, 0, -4], "LeftElbow": [8, 0, 0]
    }}
  ]
}
```

### `jump`
Anticipation crouch (feet planted, arms back), a fast extension into the launch (`quadIn`), a tuck that eases
into the top (`sineOut`), legs reaching for the ground, an absorbing landing, and the recovery. Markers on the
launch and the landing contact.

```json
{
  "length": 1.1, "looped": false, "priority": "action",
  "keys": [
    {"t": 0, "pose": {
      "Root": [0, 0, 0], "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 5],
      "RightElbow": [10, 0, 0], "LeftShoulder": [0, 0, -5], "LeftElbow": [10, 0, 0],
      "RightHip": [0, 0, 0], "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftHip": [0, 0, 0],
      "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }},
    {"t": 0.24, "ease": "quadOut", "pose": {
      "Root": [0, 0, 0, 0, -0.51, 0], "Waist": [-22, 0, 0], "Neck": [15, 0, 0],
      "RightShoulder": [-35, 0, 10], "RightElbow": [25, 0, 0], "LeftShoulder": [-35, 0, -10],
      "LeftElbow": [25, 0, 0], "RightHip": [48, 0, 0], "RightKnee": [-90, 0, 0],
      "RightAnkle": [42, 0, 0], "LeftHip": [48, 0, 0], "LeftKnee": [-90, 0, 0],
      "LeftAnkle": [42, 0, 0]
    }},
    {"t": 0.34, "ease": "quadIn", "pose": {
      "Root": [0, 0, 0, 0, 0.35, 0], "Waist": [6, 0, 0], "Neck": [10, 0, 0],
      "RightShoulder": [135, 0, 12], "RightElbow": [15, 0, 0], "LeftShoulder": [135, 0, -12],
      "LeftElbow": [15, 0, 0], "RightHip": [-8, 0, 0], "RightKnee": [-5, 0, 0],
      "RightAnkle": [-40, 0, 0], "LeftHip": [-8, 0, 0], "LeftKnee": [-5, 0, 0],
      "LeftAnkle": [-40, 0, 0]
    }},
    {"t": 0.56, "ease": "sineOut", "pose": {
      "Root": [0, 0, 0, 0, 0.35, 0], "Waist": [-8, 0, 0], "Neck": [0, 0, 0],
      "RightShoulder": [60, 0, 35], "RightElbow": [60, 0, 0], "LeftShoulder": [60, 0, -35],
      "LeftElbow": [60, 0, 0], "RightHip": [70, 0, 5], "RightKnee": [-110, 0, 0],
      "RightAnkle": [15, 0, 0], "LeftHip": [70, 0, -5], "LeftKnee": [-110, 0, 0],
      "LeftAnkle": [15, 0, 0]
    }},
    {"t": 0.76, "ease": "sineIn", "pose": {
      "Root": [0, 0, 0, 0, 0.1, 0], "Waist": [-4, 0, 0], "RightShoulder": [20, 0, 60],
      "RightElbow": [20, 0, 0], "LeftShoulder": [20, 0, -60], "LeftElbow": [20, 0, 0],
      "RightHip": [15, 0, 0], "RightKnee": [-20, 0, 0], "RightAnkle": [-10, 0, 0],
      "LeftHip": [15, 0, 0], "LeftKnee": [-20, 0, 0], "LeftAnkle": [-10, 0, 0]
    }},
    {"t": 0.86, "ease": "quadOut", "pose": {
      "Root": [0, 0, 0, 0, -0.62, 0], "Waist": [-28, 0, 0], "Neck": [18, 0, 0],
      "RightShoulder": [35, 0, 40], "RightElbow": [35, 0, 0], "LeftShoulder": [35, 0, -40],
      "LeftElbow": [35, 0, 0], "RightHip": [55, 0, 0], "RightKnee": [-100, 0, 0],
      "RightAnkle": [45, 0, 0], "LeftHip": [55, 0, 0], "LeftKnee": [-100, 0, 0],
      "LeftAnkle": [45, 0, 0]
    }},
    {"t": 1.1, "ease": "sine", "pose": {
      "Root": [0, 0, 0], "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 5],
      "RightElbow": [10, 0, 0], "LeftShoulder": [0, 0, -5], "LeftElbow": [10, 0, 0],
      "RightHip": [0, 0, 0], "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftHip": [0, 0, 0],
      "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }}
  ],
  "markers": [{"t": 0.34, "name": "launch"}, {"t": 0.76, "name": "land"}]
}
```

### `throw`
An overhand throw. Anticipation: the chest twists away, the arm cocks behind the head and the free arm aims at the
target. The release accelerates into the key (`expoIn`), the follow-through carries the arm down across the body
and the chest over the front leg, then everything settles. The feet stay planted.

```json
{
  "length": 1, "looped": false, "priority": "action",
  "keys": [
    {"t": 0, "pose": {
      "Root": [0, 0, 0], "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 5],
      "RightElbow": [10, 0, 0], "LeftShoulder": [0, 0, -5], "LeftElbow": [10, 0, 0],
      "RightHip": [0, 0, 0], "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftHip": [0, 0, 0],
      "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }},
    {"t": 0.35, "ease": "sineOut", "pose": {
      "Root": [0, 0, 0, 0, -0.06, 0], "Waist": [8, -45, 0], "Neck": [0, 40, 0],
      "RightShoulder": [90, 0, 90], "RightElbow": [110, 0, 0], "LeftShoulder": [80, 0, -15],
      "LeftElbow": [20, 0, 0], "RightHip": [10, 0, 0], "RightKnee": [-30, 0, 0],
      "RightAnkle": [20, 0, 0], "LeftHip": [20, 0, 0], "LeftKnee": [-10, 0, 0],
      "LeftAnkle": [-10, 0, 0]
    }},
    {"t": 0.47, "ease": "expoIn", "pose": {
      "Root": [0, 0, 0, 0, -0.1, 0], "Waist": [-15, 35, 0], "Neck": [0, -25, 0],
      "RightShoulder": [140, 0, 20], "RightElbow": [20, 0, 0], "LeftShoulder": [10, 0, -25],
      "LeftElbow": [60, 0, 0], "RightHip": [-12, 0, 0], "RightKnee": [-22, 0, 0],
      "RightAnkle": [34, 0, 0], "LeftHip": [28, 0, 0], "LeftKnee": [-35, 0, 0], "LeftAnkle": [7, 0, 0]
    }},
    {"t": 0.65, "ease": "quadOut", "pose": {
      "Root": [0, 0, 0, 0, -0.16, 0], "Waist": [-35, 45, 0], "Neck": [15, -30, 0],
      "RightShoulder": [45, 0, -35], "RightElbow": [30, 0, 0], "LeftShoulder": [-20, 0, -20],
      "LeftElbow": [70, 0, 0], "RightHip": [-15, 0, 0], "RightKnee": [-25, 0, 0],
      "RightAnkle": [40, 0, 0], "LeftHip": [35, 0, 0], "LeftKnee": [-45, 0, 0],
      "LeftAnkle": [10, 0, 0]
    }},
    {"t": 1, "ease": "sine", "pose": {
      "Root": [0, 0, 0], "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 5],
      "RightElbow": [10, 0, 0], "LeftShoulder": [0, 0, -5], "LeftElbow": [10, 0, 0],
      "RightHip": [0, 0, 0], "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftHip": [0, 0, 0],
      "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }}
  ],
  "markers": [{"t": 0.47, "name": "release"}]
}
```

### `hit_react`
Struck from the front: the snap back happens in 0.08 s (`expoOut`: all the speed at the start), the knees give,
the body recovers past neutral, and the head lags behind the chest (its own key at 0.38) before a springy settle
(`back`). The `impact` marker at 0 plays the hit sound the moment the clip starts.

```json
{
  "length": 0.7, "looped": false, "priority": "action",
  "keys": [
    {"t": 0, "pose": {
      "Root": [0, 0, 0], "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 5],
      "RightElbow": [10, 0, 0], "LeftShoulder": [0, 0, -5], "LeftElbow": [10, 0, 0],
      "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }},
    {"t": 0.08, "ease": "expoOut", "pose": {
      "Root": [0, 0, 0, 0, -0.03, 0], "Waist": [22, 0, 6], "Neck": [22, 0, 8],
      "RightShoulder": [35, 0, 25], "RightElbow": [45, 0, 0], "LeftShoulder": [30, 0, -30],
      "LeftElbow": [40, 0, 0], "RightKnee": [-20, 0, 0], "RightAnkle": [20, 0, 0],
      "LeftKnee": [-15, 0, 0], "LeftAnkle": [15, 0, 0]
    }},
    {"t": 0.3, "ease": "sineOut", "pose": {
      "Root": [0, 0, 0, 0, -0.06, 0], "Waist": [-10, 0, 2], "RightShoulder": [-10, 0, 12],
      "RightElbow": [25, 0, 0], "LeftShoulder": [-10, 0, -12], "LeftElbow": [25, 0, 0],
      "RightKnee": [-25, 0, 0], "RightAnkle": [25, 0, 0], "LeftKnee": [-20, 0, 0],
      "LeftAnkle": [20, 0, 0]
    }},
    {"t": 0.38, "ease": "sineOut", "pose": {"Neck": [-10, 0, -3]}},
    {"t": 0.7, "ease": "back", "pose": {
      "Root": [0, 0, 0], "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 5],
      "RightElbow": [10, 0, 0], "LeftShoulder": [0, 0, -5], "LeftElbow": [10, 0, 0],
      "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }}
  ],
  "markers": [{"t": 0, "name": "impact"}]
}
```

### `celebrate`
A crouch with fists pulled in (anticipation), a spring up onto the toes into a wide V that overshoots
(`backOut`), the elbows settling a beat later, and a proud final pose. Play it with `{hold = true}` to keep the pose
until you stop it.

```json
{
  "length": 1, "looped": false, "priority": "action",
  "keys": [
    {"t": 0, "pose": {
      "Root": [0, 0, 0], "Waist": [0, 0, 0], "Neck": [0, 0, 0], "RightShoulder": [0, 0, 5],
      "RightElbow": [10, 0, 0], "LeftShoulder": [0, 0, -5], "LeftElbow": [10, 0, 0],
      "RightHip": [0, 0, 0], "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftHip": [0, 0, 0],
      "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }},
    {"t": 0.22, "ease": "quadOut", "pose": {
      "Root": [0, 0, 0, 0, -0.27, 0], "Waist": [-15, 0, 0], "Neck": [-10, 0, 0],
      "RightShoulder": [30, 0, -15], "RightElbow": [110, 0, 0], "LeftShoulder": [30, 0, 15],
      "LeftElbow": [110, 0, 0], "RightHip": [35, 0, 0], "RightKnee": [-65, 0, 0],
      "RightAnkle": [30, 0, 0], "LeftHip": [35, 0, 0], "LeftKnee": [-65, 0, 0],
      "LeftAnkle": [30, 0, 0]
    }},
    {"t": 0.42, "ease": "backOut", "pose": {
      "Root": [0, 0, 0, 0, 0.18, 0], "Waist": [12, 0, 0], "Neck": [20, 0, 0],
      "RightShoulder": [20, 0, 150], "RightElbow": [10, 0, 0], "LeftShoulder": [20, 0, -150],
      "LeftElbow": [10, 0, 0], "RightHip": [0, 0, 0], "RightKnee": [0, 0, 0],
      "RightAnkle": [-20, 0, 0], "LeftHip": [0, 0, 0], "LeftKnee": [0, 0, 0], "LeftAnkle": [-20, 0, 0]
    }},
    {"t": 0.55, "ease": "quadOut", "pose": {"RightElbow": [25, 0, 0], "LeftElbow": [25, 0, 0]}},
    {"t": 1, "ease": "sine", "pose": {
      "Root": [0, 0, 0], "Waist": [8, 0, 0], "Neck": [15, 0, 0], "RightShoulder": [15, 0, 140],
      "RightElbow": [15, 0, 0], "LeftShoulder": [15, 0, -140], "LeftElbow": [15, 0, 0],
      "RightHip": [0, 0, 0], "RightKnee": [0, 0, 0], "RightAnkle": [0, 0, 0], "LeftHip": [0, 0, 0],
      "LeftKnee": [0, 0, 0], "LeftAnkle": [0, 0, 0]
    }}
  ],
  "markers": [{"t": 0.42, "name": "peak"}]
}
```

## Craft notes

1. **Key poses first.** Write the story poses only (start, anticipation, action / contact, follow-through,
   settle) and author the clip. On the sheet, every key pose must read as a silhouette in the front OR the side
   view: limbs clear of the body, a clear line of action. Fix the poses before anything else.
2. **Then breakdowns.** Add the in-between key that shapes the path: an arm swinging over the top rather than
   through the body, a head that dips on the way down. Follow the hand and foot trails on the sheet: arcs, not
   straight lines or zig-zags.
3. **Spacing through easing.** Anticipation eases in (`Out` into the wind-up, the character gathers), the action
   is fast (`In` or `expoIn` into the contact, 2-4 frames), follow-through decelerates (`quadOut`, `expoOut`), and
   a settle can overshoot (`backOut`, `back`). Uneven timing between keys reads as weight; even timing reads as
   a machine.
4. **Overlap by offsetting keys per joint.** Parts do not all stop together: the torso leads, the head and arms
   arrive 0.03-0.1 s later, hands after the forearms. Give the lagging joints their own keys a few frames after
   the torso's (leave them out of the torso's key), as `hit_react` does with the neck and `celebrate` with the
   elbows.
5. **Anticipation and follow-through.** Move the other way first (crouch before a jump, twist away before a
   throw), and carry past the end before settling. Stiff swings usually lack both.
6. **Weight and contact.** Planted feet stay on the ground line: bend hips and knees, keep ankles flat with
   `Ankle rx = -(Hip rx + Knee rx)`, and drop Root py (see the crouch table). Put a marker on every contact
   frame and hang the sound, the VFX and the camera kick on it.
7. **Cycles.** A walk or run loop keys the passing and contact poses; the last key repeats the first; the
   opposite arm swings with each leg; the body dips on contact and rises on passing. Match the cycle to the
   character's speed with `adjustSpeed` so feet do not slide.
8. **Common mistakes.** Knees bent with positive rx (the leg snaps forward). A left arm posed with the right
   arm's rz sign. Changes of 180 degrees or more between keys. Moving Root sideways or forward while the feet
   should stay put. Joints moved in the middle of a one-shot but missing from its first or last key.
