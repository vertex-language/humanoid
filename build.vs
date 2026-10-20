package humanoid

import (
    "anim"
    "anim/skin"
    "math"
    "math/geom"
    "mesh"
)

/// Layer is one drawable mesh of a built character: the body, or a part.
public struct Layer {
    public var Slot: string
    public var Id: string
    /// At rest, sliders applied; the body without what clothes cover.
    public var Mesh: mesh.Mesh
    /// Bound to the figure's Skeleton.
    public var Skin: skin.Skin
    /// The glTF material it shows.
    public var Material: int
    /// A second material whose base color blends over the first by Mix:
    /// the body between two skin textures. -1 for none.
    public var Blend: int
    public var Mix: float32
    /// Multiplies the base color (linear RGB).
    public var Tint: geom.Vec3
    /// Hair and brows: the texture's lightness carries Tint as a dye,
    /// rather than multiplying a brown.
    public var Dye: bool
    /// Bumps when Mesh changes, so a renderer knows to upload it again.
    public var Revision: int
}

/// Figure is a character built from a kit and a recipe.
public final class Figure {
    public let Kit: Kit
    public private(set) var Recipe: Recipe
    /// The skeleton at rest for this recipe's shape: joints moved with
    /// the body (taller, broader).
    public private(set) var Skeleton: anim.Skeleton
    public private(set) var Layers: [Layer] = []
    var revision = 0

    public init(_ kit: Kit, _ recipe: Recipe) {
        Kit = kit
        Recipe = recipe
        Skeleton = kit.Skeleton
        rebuild()
    }

    /// Set changes the recipe, rebuilding meshes only when the shape or
    /// the parts changed (colors and skin tone are cheap).
    public func Set(_ recipe: Recipe) {
        let old = Recipe
        Recipe = recipe
        if old.Shape != recipe.Shape || old.Parts != recipe.Parts {
            rebuild()
        } else {
            for i in 0..<Layers.count { look(&Layers[i]) }
        }
    }

    /// Images is the images the layers' materials show: what to Prefetch.
    public func Images() -> [int] {
        var out: [int] = []
        for l in Layers {
            for m in [l.Material, l.Blend] where m >= 0 && m < Kit.Document.Materials.count {
                let mat = Kit.Document.Materials[m]
                for t in [mat.BaseColorTexture, mat.NormalTexture] {
                    let i = Kit.TextureImage(t)
                    if i >= 0 && !out.contains(i) { out.append(i) }
                }
            }
        }
        return out
    }

    /// Height is how tall the figure stands, in meters: the top of the
    /// body mesh.
    public var Height: float32 {
        for l in Layers where l.Slot == "body" { return l.Mesh.Bounds().Max.Y }
        return 0
    }

    // rebuild morphs every piece and moves the joints.
    func rebuild() {
        let weights = targetWeights()
        // Joints.
        var rest = Kit.Skeleton.RestPositions()
        for (t, w) in weights {
            guard let d = Kit.JointDeltas[t] else { continue }
            for i in 0..<rest.count { rest[i] += d[i] * w }
        }
        var names: [string] = []
        var parents: [int] = []
        for b in Kit.Skeleton.Bones {
            names.append(b.Name)
            parents.append(b.Parent)
        }
        Skeleton = anim.Skeleton(names, parents: parents, at: rest)
        let binds = skin.InverseBind(Skeleton)

        // Which body vertices clothes cover.
        var mask: uint32 = 0
        for (slot, id) in Recipe.Parts where id != "" {
            if let p = Kit.Part(slot, id), p.HideBit >= 0 { mask |= uint32(1) << uint32(p.HideBit) }
        }
        revision += 1
        var layers: [Layer] = []
        layers.append(layer(Kit.Body, weights, binds, hide: mask))
        for slot in Kit.Slots {
            var id = Recipe.Parts[slot.Id] ?? ""
            if id == "" && !slot.Optional, let first = slot.Parts.first { id = first }
            if id == "" { continue }
            guard let p = Kit.Part(slot.Id, id) else { continue }
            layers.append(layer(p, weights, binds, hide: 0))
        }
        clipUnderHat(&layers)
        stand(&layers, rest)
        Layers = layers
    }

    // stand puts the soles on the floor: the shape's morphs move the whole
    // body (a woman's targets bring her feet ~11 cm below Y = 0), and the
    // game, the floor and motion's grounding all take Y = 0 as where the
    // feet are at rest. The joints and every layer move up together.
    func stand(_ layers: inout [Layer], _ rest: [geom.Vec3]) {
        guard let body = layers.first(where: { $0.Slot == "body" }) else { return }
        let lift = -body.Mesh.Bounds().Min.Y
        if math.Abs(lift) < 0.0005 { return }
        var raised = rest
        for i in 0..<raised.count { raised[i].Y += lift }
        var names: [string] = []
        var parents: [int] = []
        for b in Kit.Skeleton.Bones {
            names.append(b.Name)
            parents.append(b.Parent)
        }
        Skeleton = anim.Skeleton(names, parents: parents, at: raised)
        let binds = skin.InverseBind(Skeleton)
        for i in 0..<layers.count {
            var m = layers[i].Mesh
            for k in 0..<m.Positions.count { m.Positions[k].Y += lift }
            layers[i].Mesh = m
            layers[i].Skin.InverseBind = binds
        }
    }

    // clipUnderHat drops the hair a hat's crown would hold: triangles
    // above the brim and within the hat's footprint.
    func clipUnderHat(_ layers: inout [Layer]) {
        guard let hat = layers.first(where: { $0.Slot == "hat" }), let hi = layers.firstIndex(where: { $0.Slot == "hair" }) else { return }
        let b = hat.Mesh.Bounds()
        // The brim is the hat's widest part; the crown sits above it.
        let floor = b.Min.Y + (b.Max.Y - b.Min.Y) * 0.18
        let inset: float32 = 0.012
        let lo = b.Min + geom.Vec3(inset, 0, inset), up = b.Max - geom.Vec3(inset, 0, inset)
        var m = layers[hi].Mesh
        func inside(_ v: uint32) -> bool {
            let p = m.Positions[int(v)]
            return p.Y > floor && p.X > lo.X && p.X < up.X && p.Z > lo.Z && p.Z < up.Z
        }
        var kept: [uint32] = []
        var i = 0
        while i + 2 < m.Indices.count {
            let a = m.Indices[i], c = m.Indices[i + 1], d = m.Indices[i + 2]
            if !(inside(a) && inside(c) && inside(d)) { kept += [a, c, d] }
            i += 3
        }
        m.Indices = kept
        layers[hi].Mesh = m
    }

    func layer(_ p: Piece, _ weights: [string: float32], _ binds: [geom.Mat4], hide: uint32) -> Layer {
        var w = [float32](repeating: 0, count: p.Targets.count)
        for (t, x) in weights {
            if let k = p.TargetIndex[t] { w[k] = x }
        }
        var m = skin.Morphed(p.Mesh, p.Targets, w)
        if hide != 0 && !p.Hide.isEmpty {
            var kept: [uint32] = []
            kept.reserveCapacity(m.Indices.count)
            var i = 0
            while i + 2 < m.Indices.count {
                let a = m.Indices[i], b = m.Indices[i + 1], c = m.Indices[i + 2]
                let covered = (p.Hide[int(a)] & hide) != 0 && (p.Hide[int(b)] & hide) != 0 && (p.Hide[int(c)] & hide) != 0
                if !covered { kept += [a, b, c] }
                i += 3
            }
            m.Indices = kept
        }
        var sk = p.Skin
        sk.InverseBind = binds
        var l = Layer(Slot: p.Slot, Id: p.Id, Mesh: m, Skin: sk, Material: p.Material, Blend: -1, Mix: 0,
                      Tint: geom.Vec3.One, Dye: false, Revision: revision)
        look(&l)
        return l
    }

    // look sets a layer's materials and colors from the recipe.
    func look(_ l: inout Layer) {
        guard let p = l.Slot == "body" ? Kit.Body : Kit.Part(l.Slot, l.Id) else { return }
        l.Tint = Recipe.Colors[l.Slot] ?? geom.Vec3.One
        l.Dye = false
        l.Blend = -1
        l.Mix = 0
        switch l.Slot {
        case "body":
            let (a, b, f) = skins()
            l.Material = material(p, a)
            l.Blend = b != "" ? material(p, b) : -1
            l.Mix = f
            l.Tint = Recipe.SkinTint
        case "eyes":
            l.Material = material(p, Recipe.Eyes)
        case "hair", "brows":
            l.Tint = Recipe.HairColor
            l.Dye = true
        case "lashes":
            l.Tint = Recipe.HairColor * 0.45
            l.Dye = true
        default:
            break
        }
    }

    func material(_ p: Piece, _ variant: string) -> int {
        let v = Kit.VariantIndex(variant)
        return v >= 0 ? (p.Variants[v] ?? p.Material) : p.Material
    }

    // skins picks the two skin textures nearest the recipe's tone at the
    // age its shape says, and how far between them.
    func skins() -> (string, string, float32) {
        // The age slider runs from 18 (-1) through 25 (0) to 90 (+1).
        let a = Recipe.Value("age")
        let age: float32 = a < 0.2 ? 0 : (a < 0.6 ? 0.5 : 1)
        var ofAge = Kit.Skins.filter { math.Abs($0.Age - age) < 0.01 }
        if ofAge.isEmpty { ofAge = Kit.Skins }
        if ofAge.isEmpty { return ("", "", 0) }
        ofAge.sort { $0.Tone < $1.Tone }
        let t = Recipe.SkinTone
        if t <= ofAge[0].Tone { return (ofAge[0].Variant, "", 0) }
        for k in 1..<ofAge.count where t <= ofAge[k].Tone {
            let lo = ofAge[k - 1], hi = ofAge[k]
            let f = (t - lo.Tone) / math.Max(hi.Tone - lo.Tone, 1e-6)
            return (lo.Variant, hi.Variant, f)
        }
        return (ofAge[ofAge.count - 1].Variant, "", 0)
    }

    // targetWeights is each morph target's weight for the recipe's shape.
    func targetWeights() -> [string: float32] {
        var out: [string: float32] = [:]
        for s in Kit.Sliders {
            let v = math.Clamp(Recipe.Value(s.Id), -1, 1)
            if v < 0 && s.Minus != "" { out[s.Minus] = -v }
            if v > 0 && s.Plus != "" { out[s.Plus] = v }
        }
        return out
    }
}
