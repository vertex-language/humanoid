# humanoid

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)
[![license: MIT](https://img.shields.io/badge/license-MIT-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](LICENSE)

People built from a kit. A **kit** is one glTF file: a body with morph
targets, interchangeable parts fitted to it (hair, brows, lashes, eyes,
outfits, shoes, hats) that the same targets move, skins and eye colors as
material variants, and a description of its sliders. A **recipe** is a
person: which parts, which slider values, which skin and colors, as a few
hundred bytes of JSON. `Figure` turns a kit and a recipe into meshes, a
skeleton and skins ready to animate and draw; `humanoid/motion` makes
one move. Pure Vertex, no `gpu`: drawing is `render/figure`'s.

---

## Packages

### `humanoid`

| Name | What it is |
| :--- | :--- |
| `Kit` | `Load(path)`: the body and every part as `Piece`s (rigged, at rest), `Sliders`, `Skins`, `Eyes`, `Slots`, `JointDeltas`. `Part(slot, id)`, `FindSlot`, `FindSlider`, `VariantIndex`. Images decode on demand (`Image`), on several threads (`Prefetch`), or in the background (`PrefetchInBackground`). |
| `Recipe` | `Shape` (slider id → -1…1), `Parts` (slot → part id), `SkinTone`, `SkinTint`, `HairColor`, `Eyes`, `Colors` (dyes by slot), `Name`. `Encode()` and `DecodeRecipe` for JSON. |
| `Random(kit, seed:, roll:)` | A plausible person: most sliders near the middle, a few far out; a heritage; parts in every slot that needs one; colors people have (`HairColors`). The same seed gives the same person. `Roll` bounds it. |
| `Figure` | A built person: `Layers` (one per mesh: morphed, the body without what clothes cover, its material, a second skin to blend, tint, dye, a `Revision` that bumps when it changes), `Skeleton` (joints moved with the shape: a tall person's knees are higher), `Height`, `Images()`. `Set(recipe)` rebuilds only what changed. Hair a hat would hold is clipped. Every body stands with its soles on Y = 0, whatever the shape. |

### `humanoid/motion`

A person who moves: what character-sim's man was, made general so a crowd
can share it (npc-sim).

| Name | What it is |
| :--- | :--- |
| `Rig` | A skeleton with its bones found by name (hips, spine, chest, neck, head, and each side's shoulder, arm, forearm, hand, thigh, shin, foot, toe), from a `Figure`'s skeleton or a glTF; `Parts()` fits ragdoll bodies and joint limits to it. |
| `Clips` | Idle, walk, run, sprint, jump, fall, land and crouch, keyed for any rig; `Hold` (a staff upright in front) and `Cast` (raise, thrust with a `release` event, back). |
| `Character` | A capsule controller, the animation (locomotion blended by speed with its cycles in step, air poses, landing, leaning into turns, feet on the floor), a ragdoll, and the states between (`moving`, `air`, `ragdoll`, `gettingUp`). Alone, `Update(dt, input)` steps a physics world of its own; in a crowd, many share one `physics.World` and a schedule calls `Control` (fixed, before physics), `Settle` (fixed, after) and `Animate` (per frame). `Hit`, `GoLimp`, `Launch`, `Recover`, `Respawn`. `Colliders` are what it stands on: a plane, or a heightfield for hills; `Ground(x, z, below:)` finds the height under a point through them (getting up on a slope stands it there). `Socket(side)` is where a held thing goes in that hand (+Y along it; in the right hand up is up in the hold pose). `Holding` keeps the right arm in the hold pose over any gait. `Play(clip)` plays an action over the upper body (a mask: arms whole, torso and head partly) while the legs keep walking, the chest turned toward `Aim`; its events come back from `TakeEvents()`. |
| `Input` | What a player or a mind asks for: `Move` relative to the camera, or `Direction` in the world; `Sprint`, `Walk`, `Jump`. |

---

## The kit format

A glTF 2.0 file (GLB) any viewer opens; what's particular is where things
are and what they're named.

- **Skeleton**: a skin whose joints have the model's axes (translations
  only), named for the bones the animations use (`hips`, `spine`, `chest`,
  `neck`, `head`, `shoulder.L`, `upper_arm.L`, `forearm.L`, `hand.L`,
  `thigh.L`, `shin.L`, `foot.L`, `toe.L` and the `.R`s).
- **Body**: the node with `extras.slot = "body"`. One morph target per
  slider end, named `<slider>-` and `<slider>+` (`extras.targetNames`), and
  a `_HIDE` attribute: per vertex, a bit for each garment that covers it.
- **Parts**: a node per part, `extras.slot`, `extras.id`, `extras.label`,
  and for garments `extras.hideBit`. A part has the morph targets that move
  it (by the same names).
- **Skins and eye colors**: `KHR_materials_variants` variants named
  `skin:<name>` and `eyes:<name>` on the body's and the eyes' primitives.
- **Description**: the scene's `extras.humanoid`: `bones`, `slots` (id,
  optional, parts), `sliders` (id, label, group, minus, plus), `skins`
  (variant, label, tone 0 light … 1 dark, age 0 young … 1 old), `eyes`, and
  `jointDeltas` (for each target that moves joints, each joint's offset at
  weight 1).
- Morph deltas are normalized int16 (`KHR_mesh_quantization`, required)
  and sparse where they touch few vertices.

`character-gen/tools/bake_kit.py` makes one from MakeHuman's CC0 assets.

## A recipe

```json
{
  "version": 1,
  "name": "Dale",
  "shape": { "height": 0.3, "nose-size": -0.25, "jaw": 0.4 },
  "parts": { "hair": "short04", "brows": "eyebrow003", "outfit": "male_worksuit01", "shoes": "shoes05", "hat": "" },
  "skin": { "tone": 0.2, "tint": [1.02, 1, 0.98] },
  "hair": [0.035, 0.022, 0.014],
  "eyes": "eyes:green",
  "colors": { "outfit": [0.3, 0.38, 0.62] }
}
```

---

## Example

```vertex
import "fs"
import "humanoid"

let kit = try humanoid.Kit.Load(fs.Path("humans.glb"))
var r = humanoid.Random(kit, seed: 42)
r.Shape["height"] = 0.4
let person = humanoid.Figure(kit, r)
// person.Layers: meshes to draw; person.Skeleton: to animate
```

---

## Testing

```bash
vsc run check [kit.glb]    # a kit loads; recipes build; sliders move meshes and joints; clothes hide; JSON round trip; rolls repeat
```

---

## License

[MIT](LICENSE). Kits carry their own licenses: character-gen's is made
from MakeHuman's CC0 assets.
