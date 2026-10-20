package humanoid

import (
    "encoding/json"
    "math"
    "math/geom"
    "math/rand"
)

/// Recipe is a character: everything that makes one person out of a kit.
/// It's small, plain data, saved as JSON (Encode, DecodeRecipe), so a game
/// can keep thousands and a character screen can hand one to the game.
public struct Recipe {
    public var Name: string = ""
    /// Slider values by slider id, -1…1; missing ones are 0.
    public var Shape: [string: float32] = [:]
    /// The part in each slot, by slot id; "" or missing for none.
    public var Parts: [string: string] = [:]
    /// Skin: 0 light … 1 dark, picking and blending the kit's skins.
    public var SkinTone: float32 = 0.15
    /// Multiplies the skin's color (linear RGB): a subtle cast.
    public var SkinTint = geom.Vec3(1, 1, 1)
    /// Hair, brows' and beard's color (linear RGB).
    public var HairColor = geom.Vec3(0.09, 0.055, 0.035)
    /// The eye color's variant name ("" for the kit's first).
    public var Eyes: string = ""
    /// Clothes' color multipliers by slot (linear RGB); missing is white.
    public var Colors: [string: geom.Vec3] = [:]

    public init() {}

    /// Value is a slider's value.
    public func Value(_ slider: string) -> float32 {
        return Shape[slider] ?? 0
    }
}

extension Recipe {
    /// Encode writes the recipe as JSON.
    public func Encode() -> string {
        var o = json.Object()
        o["version"] = .number("1")
        o["name"] = .string(Name)
        var shape = json.Object()
        for k in Shape.keys.sorted() where Shape[k]! != 0 { shape[k] = num(Shape[k]!) }
        o["shape"] = .object(shape)
        var parts = json.Object()
        for k in Parts.keys.sorted() { parts[k] = .string(Parts[k]!) }
        o["parts"] = .object(parts)
        var skin = json.Object()
        skin["tone"] = num(SkinTone)
        skin["tint"] = color(SkinTint)
        o["skin"] = .object(skin)
        o["hair"] = color(HairColor)
        o["eyes"] = .string(Eyes)
        var colors = json.Object()
        for k in Colors.keys.sorted() { colors[k] = color(Colors[k]!) }
        o["colors"] = .object(colors)
        return json.Encode(.object(o), indent: "  ")
    }
}

/// DecodeRecipe reads a recipe written by Encode (or by hand).
public func DecodeRecipe(_ text: string) throws -> Recipe {
    let v = try json.Parse(text)
    var r = Recipe()
    r.Name = v["name"]?.String ?? ""
    if case .object(let o) = v["shape"] ?? json.Value.null {
        for (k, x) in o.Members { r.Shape[k] = math.Clamp(float32(x.Double ?? 0), -1, 1) }
    }
    if case .object(let o) = v["parts"] ?? json.Value.null {
        for (k, x) in o.Members { r.Parts[k] = x.String ?? "" }
    }
    r.SkinTone = math.Clamp(float32(v["skin"]?["tone"]?.Double ?? 0.15), 0, 1)
    if let t = vec(v["skin"]?["tint"]) { r.SkinTint = t }
    if let h = vec(v["hair"]) { r.HairColor = h }
    r.Eyes = v["eyes"]?.String ?? ""
    if case .object(let o) = v["colors"] ?? json.Value.null {
        for (k, x) in o.Members { if let c = vec(x) { r.Colors[k] = c } }
    }
    return r
}

func num(_ x: float32) -> json.Value {
    return .number("\(Double(Int((x * 10000).rounded())) / 10000)")
}

func color(_ c: geom.Vec3) -> json.Value {
    return .array([num(c.X), num(c.Y), num(c.Z)])
}

func vec(_ v: json.Value?) -> geom.Vec3? {
    guard let a = v?.Array, a.count == 3 else { return nil }
    return geom.Vec3(float32(a[0].Double ?? 0), float32(a[1].Double ?? 0), float32(a[2].Double ?? 0))
}

// ---- rolling ----

/// Roll is how a random character is made: which sliders move and how
/// far, what may be left out.
public struct Roll {
    /// The largest any face slider goes (0…1).
    public var Face: float32 = 0.55
    /// The largest any body slider goes.
    public var Body: float32 = 0.6
    /// Keep the body masculine (gender slider near 0).
    public var Masculine = true
    /// Ages from 18 (-1) to 90 (+1): the range to roll in.
    public var AgeMin: float32 = -1
    public var AgeMax: float32 = 0.35
    /// Chance of going without a hat.
    public var NoHat: float32 = 0.8
    /// Chance of no hair (shaved).
    public var Bald: float32 = 0.08

    public init() {}
}

/// Hair colors people have, linear RGB: black, browns, blonde, red, grey.
public let HairColors: [geom.Vec3] = [
    geom.Vec3(0.012, 0.010, 0.009), geom.Vec3(0.035, 0.022, 0.014), geom.Vec3(0.09, 0.055, 0.035),
    geom.Vec3(0.20, 0.13, 0.07), geom.Vec3(0.45, 0.33, 0.17), geom.Vec3(0.62, 0.50, 0.30),
    geom.Vec3(0.30, 0.09, 0.03), geom.Vec3(0.42, 0.42, 0.42), geom.Vec3(0.75, 0.74, 0.72),
]

/// Random rolls a character from the kit: every slider somewhere
/// plausible (most near the middle, a few far out), a part in every slot
/// that needs one, colors people have.
public func Random(_ kit: Kit, seed: uint64, roll: Roll = Roll()) -> Recipe {
    var g = rand.Xorshift128Plus(seed: seed)
    func unit() -> float32 { return float32(g.Float64()) }
    // Mostly small, now and then large: the sum of two uniforms, cubed in.
    func spread(_ limit: float32) -> float32 {
        let x = unit() + unit() - 1
        return math.Clamp(x * math.Abs(x) * 1.6, -1, 1) * limit
    }
    func pick(_ n: int) -> int { return int(g.Below(uint64(max(1, n)))) }

    var r = Recipe()
    r.Name = "Rolled #\(seed % 100000)"
    for s in kit.Sliders {
        switch s.Group {
        case "Body":
            r.Shape[s.Id] = spread(roll.Body)
        case "Heritage":
            r.Shape[s.Id] = 0
        default:
            r.Shape[s.Id] = spread(roll.Face)
        }
    }
    r.Shape["gender"] = roll.Masculine ? 0 : math.Clamp(0.6 + unit() * 0.4, 0, 1)
    r.Shape["age"] = roll.AgeMin + (roll.AgeMax - roll.AgeMin) * unit() * unit()
    r.Shape["height"] = spread(0.7)
    // Heritage: one of three, sometimes a mix.
    let heritage = pick(3)
    let amount = 0.6 + unit() * 0.4
    if heritage == 1 { r.Shape["african"] = amount }
    if heritage == 2 { r.Shape["asian"] = amount }
    r.SkinTone = math.Clamp([float32(0.08), 0.85, 0.45][heritage] + (unit() - 0.5) * 0.3, 0, 1)
    r.SkinTint = geom.Vec3(1 + (unit() - 0.5) * 0.06, 1, 1 + (unit() - 0.5) * 0.06)

    for slot in kit.Slots {
        if slot.Parts.isEmpty { continue }
        var id = slot.Parts[pick(slot.Parts.count)]
        if slot.Id == "hat" && unit() < roll.NoHat { id = "" }
        if slot.Id == "hair" && unit() < roll.Bald { id = "" }
        if slot.Id == "outfit" && roll.Masculine {
            let men = slot.Parts.filter { !$0.hasPrefix("female") }
            if !men.isEmpty { id = men[pick(men.count)] }
        }
        if slot.Id == "hair" && roll.Masculine && id != "" {
            let short = slot.Parts.filter { $0.hasPrefix("short") || $0 == "afro01" }
            if !short.isEmpty && unit() < 0.8 { id = short[pick(short.count)] }
        }
        r.Parts[slot.Id] = id
    }
    // Dark hair for darker skins more often, grey for the old.
    var hc = pick(HairColors.count)
    if r.SkinTone > 0.5 && unit() < 0.85 { hc = pick(3) }
    if r.Value("age") > 0.3 && unit() < 0.7 { hc = 7 + pick(2) }
    r.HairColor = HairColors[hc]
    if !kit.Eyes.isEmpty {
        var e = pick(kit.Eyes.count)
        // "brown" in MakeHuman's set is a red-brown: rarely.
        if kit.Eyes[e].Variant == "eyes:brown" && unit() < 0.8 { e = 1 % kit.Eyes.count }
        r.Eyes = kit.Eyes[e].Variant
    }
    return r
}
