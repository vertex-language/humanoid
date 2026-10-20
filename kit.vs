// Package humanoid builds people from a kit: one glTF file holding a
// body with morph targets, interchangeable parts (hair, brows, outfits,
// shoes, hats) fitted to it and moved by the same targets, skins and eye
// colors as material variants, and a description of the sliders. A
// Recipe (plain JSON) says which parts, which slider values, which skin
// and colors; Build turns a kit and a recipe into meshes, a skeleton and
// a skin ready to animate and draw. It draws nothing itself and knows
// no GPU.
//
// The kit format is described in the README; tools/bake_kit.py in
// character-gen makes one from MakeHuman's CC0 assets.
package humanoid

import (
    "anim"
    "anim/skin"
    "encoding/json"
    "fs"
    "image"
    "image/png"
    "math/geom"
    "mesh"
    "scene/gltf"
    "sync"
)

/// Slider is one control of the body's shape, from -1 to 1.
public struct Slider {
    public var Id: string
    public var Label: string
    /// What it's shown under: "Body", "Nose", "Eyes"…
    public var Group: string
    /// The morph target at -1, and at +1 ("" when that side doesn't move).
    public var Minus: string
    public var Plus: string
}

/// SkinTone is one of the kit's skin textures.
public struct SkinTone {
    /// The material variant that selects it.
    public var Variant: string
    public var Label: string
    /// 0 light … 1 dark.
    public var Tone: float32
    /// 0 young … 1 old.
    public var Age: float32
}

/// EyeColor is one of the kit's eye textures.
public struct EyeColor {
    public var Variant: string
    public var Label: string
}

/// Slot is a place a part goes: "hair", "outfit"…
public struct Slot {
    public var Id: string
    /// Whether a character may go without.
    public var Optional: bool
    /// Its parts' ids, in the kit's order.
    public var Parts: [string]
}

/// Piece is one mesh of the kit, rigged, at rest with no sliders moved.
public struct Piece {
    /// "body", or the part's slot.
    public var Slot: string
    public var Id: string
    public var Label: string
    public var Mesh: mesh.Mesh
    public var Skin: skin.Skin
    /// Its morph targets; TargetIndex finds one by name.
    public var Targets: [skin.Morph]
    public var TargetIndex: [string: int]
    /// The glTF material, and the ones its variants pick.
    public var Material: int
    public var Variants: [int: int]
    /// For a garment: which bit of the body's Hide it sets (-1: none).
    public var HideBit: int
    /// For the body: per vertex, the bits of the garments that cover it.
    public var Hide: [uint32]
}

/// KitError is a file that isn't a humanoid kit.
public struct KitError: Error, CustomStringConvertible {
    public let Message: string
    public var description: string { return "humanoid: \(Message)" }
}

/// Kit is a loaded kit.
public final class Kit {
    public let Document: gltf.Document
    /// The skeleton at rest, with no sliders moved.
    public let Skeleton: anim.Skeleton
    public let Sliders: [Slider]
    public let Skins: [SkinTone]
    public let Eyes: [EyeColor]
    public let Slots: [Slot]
    public let Body: Piece
    /// The parts, by "slot.id".
    public let Parts: [string: Piece]
    /// For each target that moves joints, how far each bone's joint
    /// moves at weight 1.
    public let JointDeltas: [string: [geom.Vec3]]
    let images: imageCache

    /// Load reads a kit file.
    public static func Load(_ path: fs.Path) throws -> Kit {
        return try Kit(try gltf.Load(path))
    }

    public init(_ doc: gltf.Document) throws {
        Document = doc
        guard let meta = doc.Extras?["humanoid"] else { throw KitError(Message: "no humanoid description in the scene's extras") }
        var sliders: [Slider] = []
        for s in meta["sliders"]?.Array ?? [] {
            sliders.append(Slider(Id: s["id"]?.String ?? "", Label: s["label"]?.String ?? "", Group: s["group"]?.String ?? "",
                                  Minus: s["minus"]?.String ?? "", Plus: s["plus"]?.String ?? ""))
        }
        Sliders = sliders
        var skins: [SkinTone] = []
        for s in meta["skins"]?.Array ?? [] {
            skins.append(SkinTone(Variant: s["variant"]?.String ?? "", Label: s["label"]?.String ?? "",
                                  Tone: float32(s["tone"]?.Double ?? 0), Age: float32(s["age"]?.Double ?? 0)))
        }
        Skins = skins
        var eyes: [EyeColor] = []
        for e in meta["eyes"]?.Array ?? [] {
            eyes.append(EyeColor(Variant: e["variant"]?.String ?? "", Label: e["label"]?.String ?? ""))
        }
        Eyes = eyes
        var slots: [Slot] = []
        for s in meta["slots"]?.Array ?? [] {
            var ids: [string] = []
            for p in s["parts"]?.Array ?? [] { ids.append(p.String ?? "") }
            slots.append(Slot(Id: s["id"]?.String ?? "", Optional: s["optional"]?.Bool ?? true, Parts: ids))
        }
        Slots = slots

        var body: Piece? = nil
        var parts: [string: Piece] = [:]
        var skeleton: anim.Skeleton? = nil
        for (i, n) in doc.Nodes.enumerated() where n.Mesh >= 0 && n.Skin >= 0 {
            let r = try doc.Rig(node: i)
            if skeleton == nil { skeleton = r.Skeleton }
            let slot = n.Extras?["slot"]?.String ?? n.Name
            var index: [string: int] = [:]
            for (k, t) in r.Targets.enumerated() { index[t.Name] = k }
            var hide: [uint32] = []
            if let h = r.Attributes["_HIDE"] {
                for x in h { hide.append(uint32(x)) }
            }
            let prim = doc.Meshes[n.Mesh].Primitives[0]
            let piece = Piece(Slot: slot, Id: n.Extras?["id"]?.String ?? slot, Label: n.Extras?["label"]?.String ?? n.Name,
                              Mesh: r.Mesh, Skin: r.Skin, Targets: r.Targets, TargetIndex: index, Material: r.Material,
                              Variants: prim.Variants, HideBit: int(n.Extras?["hideBit"]?.Int ?? -1), Hide: hide)
            if slot == "body" {
                body = piece
            } else {
                parts[slot + "." + piece.Id] = piece
            }
        }
        guard let b = body, let s = skeleton else { throw KitError(Message: "no skinned body") }
        Body = b
        Parts = parts
        Skeleton = s

        // Joint deltas are listed in the kit's bone order; the skeleton
        // may order bones differently.
        var names: [string] = []
        for x in meta["bones"]?.Array ?? [] { names.append(x.String ?? "") }
        var deltas: [string: [geom.Vec3]] = [:]
        if case .object(let o) = meta["jointDeltas"] ?? json.Value.null {
            for (t, v) in o.Members {
                var d = [geom.Vec3](repeating: geom.Vec3.Zero, count: s.Count)
                for (k, p) in (v.Array ?? []).enumerated() where k < names.count {
                    if let bi = s.Index(of: names[k]), let a = p.Array, a.count == 3 {
                        d[bi] = geom.Vec3(float32(a[0].Double ?? 0), float32(a[1].Double ?? 0), float32(a[2].Double ?? 0))
                    }
                }
                deltas[t] = d
            }
        }
        JointDeltas = deltas
        images = imageCache(doc)
    }

    /// Part is a part by slot and id.
    public func Part(_ slot: string, _ id: string) -> Piece? {
        return Parts[slot + "." + id]
    }

    /// Slot is a slot by id.
    public func FindSlot(_ id: string) -> Slot? {
        return Slots.first(where: { $0.Id == id })
    }

    /// Slider is a slider by id.
    public func FindSlider(_ id: string) -> Slider? {
        return Sliders.first(where: { $0.Id == id })
    }

    /// VariantIndex is a material variant's index, or -1.
    public func VariantIndex(_ name: string) -> int {
        return Document.Variants.firstIndex(of: name) ?? -1
    }

    /// Image is a decoded image (RGBA, straight alpha), decoded once and
    /// kept. nil when the index is out of range or the bytes don't decode.
    public func Image(_ index: int) -> image.RGBA? {
        return images.get(index)
    }

    /// Prefetch decodes images on `threads` threads and returns when all
    /// are done: what a program calls with what it's about to draw.
    public func Prefetch(_ indices: [int], threads: int = 6) {
        images.prefetch(indices, threads: threads)
    }

    /// PrefetchInBackground decodes images on a thread of its own and
    /// returns at once; Image waits for nothing it has already decoded.
    public func PrefetchInBackground(_ indices: [int], threads: int = 3) {
        let cache = images
        sync.Thread.spawn { cache.prefetch(indices, threads: threads) }.detach()
    }

    /// TextureImage is the image a texture shows, or -1.
    public func TextureImage(_ texture: int) -> int {
        if texture < 0 || texture >= Document.Textures.count { return -1 }
        return Document.Textures[texture].Image
    }
}

// imageCache decodes a document's images on demand, from any thread.
final class imageCache {
    let doc: gltf.Document
    let lock = sync.Mutex()
    var done: [int: image.RGBA] = [:]
    var failed: [int: bool] = [:]

    init(_ doc: gltf.Document) {
        self.doc = doc
    }

    func get(_ i: int) -> image.RGBA? {
        if i < 0 || i >= doc.Images.count { return nil }
        var hit: image.RGBA? = nil
        var bad = false
        lock.withLock {
            hit = done[i]
            bad = failed[i] ?? false
        }
        if let h = hit { return h }
        if bad { return nil }
        let decoded = try? png.Decode(doc.Images[i].Bytes)
        lock.withLock {
            if let d = decoded { done[i] = d } else { failed[i] = true }
        }
        return decoded
    }

    func prefetch(_ indices: [int], threads: int) {
        var todo: [int] = []
        lock.withLock {
            for i in indices where i >= 0 && i < doc.Images.count && done[i] == nil && failed[i] == nil && !todo.contains(i) {
                todo.append(i)
            }
        }
        if todo.isEmpty { return }
        let queue = workQueue(todo)
        var workers: [sync.Thread] = []
        for _ in 0..<max(1, min(threads, todo.count)) {
            workers.append(sync.Thread.spawn {
                while let i = queue.next() { _ = self.get(i) }
            })
        }
        for w in workers { w.join() }
    }
}

final class workQueue {
    let lock = sync.Mutex()
    var items: [int]
    var at = 0

    init(_ items: [int]) {
        self.items = items
    }

    func next() -> int? {
        var out: int? = nil
        lock.withLock {
            if at < items.count {
                out = items[at]
                at += 1
            }
        }
        return out
    }
}
