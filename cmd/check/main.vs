// humanoid: a kit loads, recipes build into figures, sliders move meshes
// and joints, clothes hide what they cover, recipes survive JSON, rolls
// are repeatable.
//
//     vsc run check [kit.glb]
package main

import (
    "fs"
    "humanoid"
    "math"
    "time"
)

var failures = 0

func check(_ ok: bool, _ what: string) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

func main() -> int32 {
    let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../character-gen/assets/humans.glb"
    let t0 = time.Instant.Now()
    let kit: humanoid.Kit
    do {
        kit = try humanoid.Kit.Load(fs.Path(path))
    } catch {
        print("load: \(error)")
        return 1
    }
    check(kit.Sliders.count > 30 && kit.Slots.count >= 6 && kit.Skins.count >= 3 && !kit.Eyes.isEmpty,
          "the kit loads: \(kit.Sliders.count) sliders, \(kit.Slots.count) slots, \(kit.Parts.count) parts, \(kit.Skins.count) skins, \(kit.Eyes.count) eye colors (\(t0.Elapsed().AsMilliseconds()) ms)")

    var r = humanoid.Recipe()
    r.Parts = ["hair": "short02", "brows": "eyebrow001", "outfit": "male_casualsuit03", "shoes": "shoes02"]
    let t1 = time.Instant.Now()
    let f = humanoid.Figure(kit, r)
    check(f.Layers.count >= 6, "a recipe builds \(f.Layers.count) layers (\(t1.Elapsed().AsMilliseconds()) ms)")
    let h0 = f.Height
    check(h0 > 1.6 && h0 < 1.9, "standing \(h0) m")
    let bodyTris = f.Layers[0].Mesh.TriangleCount
    check(bodyTris < kit.Body.Mesh.TriangleCount, "clothes hide what they cover (\(kit.Body.Mesh.TriangleCount) → \(bodyTris) triangles)")

    var tall = r
    tall.Shape["height"] = 1
    let t2 = time.Instant.Now()
    f.Set(tall)
    let ms = t2.Elapsed().AsMilliseconds()
    let head = f.Skeleton.RestPositions()[f.Skeleton.Index(of: "head")!].Y
    var short = r
    short.Shape["height"] = -1
    let small = humanoid.Figure(kit, short)
    check(math.Abs(f.Layers[0].Mesh.Bounds().Min.Y) < 0.01 && math.Abs(small.Layers[0].Mesh.Bounds().Min.Y) < 0.01,
          "the height slider spans \(small.Height) to \(f.Height) m, feet on the floor at both ends")
    check(f.Height > h0 + 0.08, "the height slider makes him taller (\(f.Height) m, rebuilt in \(ms) ms)")
    check(head > kit.Skeleton.RestPositions()[kit.Skeleton.Index(of: "head")!].Y + 0.05, "and moves his joints with him (head joint \(head))")

    let text = tall.Encode()
    do {
        let back = try humanoid.DecodeRecipe(text)
        check(back.Shape == tall.Shape && back.Parts == tall.Parts && math.Abs(back.SkinTone - tall.SkinTone) < 1e-4,
              "a recipe survives JSON")
    } catch {
        check(false, "a recipe survives JSON: \(error)")
    }
    let a = humanoid.Random(kit, seed: 42), b = humanoid.Random(kit, seed: 42), c = humanoid.Random(kit, seed: 43)
    check(a.Encode() == b.Encode() && a.Encode() != c.Encode(), "a roll is the same for the same seed, different for another")
    let rolled = humanoid.Figure(kit, a)
    check(rolled.Layers.count >= 5 && rolled.Height > 1.4, "a rolled character builds (\(rolled.Layers.count) layers, \(rolled.Height) m)")
    let t3 = time.Instant.Now()
    kit.Prefetch(f.Images())
    check(f.Images().count > 4, "its \(f.Images().count) images decode in \(t3.Elapsed().AsMilliseconds()) ms")
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}
