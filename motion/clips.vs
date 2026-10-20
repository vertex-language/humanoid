package motion

import (
    "anim"
    "math"
    "math/geom"
)

/// Clips is the man's animations, made from keyframes here rather than
/// read from a file: each a few numbers per joint per beat, in degrees.
///
/// Rotations are in the model's axes (the rig's bones all have them): a
/// positive turn about X tips an upright bone forward and swings a
/// hanging one back; a knee bends with a positive X, a foot points its
/// toes down with one. Arms are lowered from the mesh's A-pose to the
/// sides first, then swung.
public final class Clips {
    public let Idle: anim.Clip
    public let Walk: anim.Clip
    public let Run: anim.Clip
    public let Sprint: anim.Clip
    public let Jump: anim.Clip
    public let Fall: anim.Clip
    public let Land: anim.Clip
    public let Crouch: anim.Clip
    /// The right arm holding a staff upright in front (an overlay: only
    /// the arm's keys).
    public let Hold: anim.Clip
    /// Casting with it: raise, thrust, back to holding, the left hand
    /// following; the upper body only. Its "release" event is the thrust.
    public let Cast: anim.Clip

    public init(_ r: Rig) {
        Idle = idle(r)
        Walk = cycle(r, "walk", duration: 1.05, gait: walkGait)
        Run = cycle(r, "run", duration: 0.68, gait: runGait)
        Sprint = cycle(r, "sprint", duration: 0.6, gait: sprintGait)
        Jump = still(r, "jump", jumpPose)
        Fall = flail(r)
        Land = still(r, "land", landPose)
        Crouch = still(r, "crouch", crouchPose)
        Hold = hold(r)
        Cast = cast(r)
    }
}

// ---- building blocks ----

// builder collects keys bone by bone.
final class builder {
    var tracks: [int: [anim.Key]] = [:]

    func key(_ bone: int, _ t: float32, _ q: geom.Quat, _ offset: geom.Vec3 = geom.Vec3.Zero) {
        var ks = tracks[bone] ?? []
        ks.append(anim.Key(t, q, offset: offset))
        tracks[bone] = ks
    }

    func clip(_ name: string, duration: float32, looping: bool) -> anim.Clip {
        var out: [anim.Track] = []
        for bone in tracks.keys.sorted() { out.append(anim.Track(bone: bone, keys: tracks[bone]!)) }
        return anim.Clip(name, duration: duration, looping: looping, tracks: out)
    }
}

func ax(_ d: float32) -> geom.Quat { return geom.AxisAngle(geom.Vec3.UnitX, d * deg) }
func ay(_ d: float32) -> geom.Quat { return geom.AxisAngle(geom.Vec3.UnitY, d * deg) }
func az(_ d: float32) -> geom.Quat { return geom.AxisAngle(geom.Vec3.UnitZ, d * deg) }

/// Beat is one moment of a pose, in degrees.
struct beat {
    // Torso: forward lean of the spine and chest, twist of the hips and
    // chest about Y, a side lean.
    var spine: float32 = 0
    var chest: float32 = 0
    var hipsTwist: float32 = 0
    var chestTwist: float32 = 0
    var lean: float32 = 0
    var head: float32 = 0
    var headTurn: float32 = 0
    // Per side (left, right): hip swing (negative forward), hip spread
    // (outward), knee bend, ankle (toes down).
    var hip: [float32] = [0, 0]
    var spread: [float32] = [3, 3]
    var knee: [float32] = [3, 3]
    var ankle: [float32] = [0, 0]
    // Per side: how far the arm comes down from the A-pose, its swing
    // forward, the elbow's bend.
    var lower: [float32] = [38, 38]
    var swing: [float32] = [4, 4]
    var elbow: [float32] = [14, 14]
}

// write puts a beat's rotations for every bone it moves into b at time t.
func write(_ r: Rig, _ b: builder, _ t: float32, _ p: beat) {
    b.key(r.Hips, t, ay(p.hipsTwist) * az(p.lean * 0.5))
    b.key(r.Spine, t, ax(p.spine) * az(p.lean * 0.5))
    b.key(r.Chest, t, ax(p.chest) * ay(p.chestTwist - p.hipsTwist))
    b.key(r.Neck, t, ax(p.head * 0.5) * ay(p.headTurn * 0.4 - p.chestTwist * 0.5))
    b.key(r.Head, t, ax(p.head * 0.5) * ay(p.headTurn * 0.6))
    for side in [Left, Right] {
        let out: float32 = side == Left ? 1 : -1
        // Counter the torso's lean so the legs hang from the hips upright.
        b.key(r.Thigh[side], t, ax(p.hip[side]) * az(out * p.spread[side]))
        b.key(r.Shin[side], t, ax(p.knee[side]))
        b.key(r.Foot[side], t, ax(p.ankle[side]))
        b.key(r.UpperArm[side], t, ax(-p.swing[side]) * az(-out * p.lower[side]))
        // Elbows are written as bends from straight; the rig's rest pose
        // may already be bent.
        b.key(r.Forearm[side], t, geom.AxisAngle(r.ElbowAxis(side), p.elbow[side] * deg - r.ElbowBend(side)))
    }
}

func still(_ r: Rig, _ name: string, _ pose: (Rig) -> beat) -> anim.Clip {
    let b = builder()
    write(r, b, 0, pose(r))
    return b.clip(name, duration: 1, looping: false)
}

// ---- gaits ----

/// gait is a locomotion cycle: eight beats from the left foot's contact,
/// for the left side; the right side runs half a cycle behind.
struct gait {
    var hip: [float32]
    var knee: [float32]
    var ankle: [float32]
    var swing: [float32]
    var elbow: [float32]
    var spine: float32
    var chest: float32
    var twist: float32
    var lower: float32
    var spread: float32
}

let walkGait = gait(hip: [-24, -14, -4, 6, 14, 0, -22, -28],
                    knee: [4, 16, 8, 6, 32, 58, 42, 10],
                    ankle: [-6, 6, 0, -6, 20, 10, -8, -8],
                    swing: [-14, -8, 0, 8, 14, 8, 0, -8],
                    elbow: [12, 13, 15, 20, 24, 20, 15, 13],
                    spine: 3, chest: 1, twist: 5, lower: 38, spread: 2)

let runGait = gait(hip: [-32, -12, 8, 22, 12, -20, -48, -45],
                   knee: [18, 38, 22, 20, 75, 105, 72, 30],
                   ankle: [-4, -8, 10, 30, 20, 0, -12, -10],
                   swing: [-32, -20, 0, 20, 32, 20, 0, -20],
                   elbow: [78, 80, 85, 92, 95, 92, 85, 80],
                   spine: 8, chest: 4, twist: 9, lower: 34, spread: 1)

let sprintGait = gait(hip: [-38, -14, 10, 28, 16, -24, -60, -55],
                      knee: [22, 42, 24, 22, 88, 120, 84, 34],
                      ankle: [-4, -10, 12, 34, 22, 0, -14, -12],
                      swing: [-45, -30, 0, 30, 48, 30, 0, -30],
                      elbow: [80, 82, 88, 95, 100, 95, 88, 82],
                      spine: 14, chest: 5, twist: 11, lower: 32, spread: 1)

let twistBeats: [float32] = [1, 0.7, 0, -0.7, -1, -0.7, 0, 0.7]

func cycle(_ r: Rig, _ name: string, duration: float32, gait g: gait) -> anim.Clip {
    let b = builder()
    for i in 0...8 {
        let k = i % 8, o = (i + 4) % 8
        var p = beat()
        p.spine = g.spine
        p.chest = g.chest
        // The hips turn with the forward leg; the chest the other way.
        let s = twistBeats[k]
        p.hipsTwist = -g.twist * s
        p.chestTwist = g.twist * 0.8 * s
        p.hip = [g.hip[k], g.hip[o]]
        p.knee = [g.knee[k], g.knee[o]]
        p.ankle = [g.ankle[k], g.ankle[o]]
        p.spread = [g.spread, g.spread]
        // Each arm swings with the opposite leg.
        p.swing = [g.swing[k], g.swing[o]]
        p.elbow = [g.elbow[k], g.elbow[o]]
        p.lower = [g.lower, g.lower]
        p.head = -g.spine * 0.6
        write(r, b, duration * float32(i) / 8, p)
    }
    return b.clip(name, duration: duration, looping: true)
}

// ---- poses ----

func idle(_ r: Rig) -> anim.Clip {
    // Breathing, a slow shift of weight and a glance about.
    let b = builder()
    let d: float32 = 4
    let shift: [float32] = [0, 1, 0, -1, 0]
    let breath: [float32] = [0, 1.8, 0, 1.8, 0]
    let glance: [float32] = [0, 6, 2, -5, 0]
    for i in 0...4 {
        var p = beat()
        let w = shift[i]
        p.chest = breath[i]
        p.spine = 1
        p.lean = w * 1.2
        p.headTurn = glance[i]
        p.hip = [-2 + w, -2 - w]
        p.spread = [4, 4]
        p.knee = [4 + 2 * math.Max(0, -w), 4 + 2 * math.Max(0, w)]
        p.ankle = [-2, -2]
        p.lower = [37 + p.chest * 0.5, 37 + p.chest * 0.5]
        p.swing = [5, 5]
        p.elbow = [16, 16]
        write(r, b, d * float32(i) / 4, p)
    }
    return b.clip("idle", duration: d, looping: true)
}

func jumpPose(_ r: Rig) -> beat {
    var p = beat()
    p.spine = 6
    p.hip = [-45, -12]
    p.knee = [70, 25]
    p.ankle = [25, 30]
    p.lower = [5, 10]
    p.swing = [40, 25]
    p.elbow = [45, 40]
    p.head = 4
    return p
}

func landPose(_ r: Rig) -> beat {
    var p = beat()
    p.spine = 24
    p.chest = 10
    p.head = -14
    p.hip = [-62, -58]
    p.spread = [8, 8]
    p.knee = [100, 96]
    p.ankle = [-38, -38]
    p.lower = [26, 26]
    p.swing = [28, 24]
    p.elbow = [40, 40]
    return p
}

func crouchPose(_ r: Rig) -> beat {
    var p = beat()
    p.spine = 34
    p.chest = 12
    p.head = -20
    p.hip = [-92, -70]
    p.spread = [10, 10]
    p.knee = [130, 110]
    p.ankle = [-30, -38]
    p.lower = [30, 30]
    p.swing = [36, 30]
    p.elbow = [55, 55]
    return p
}

func flail(_ r: Rig) -> anim.Clip {
    // Arms up and windmilling, legs pedalling.
    let b = builder()
    let d: float32 = 0.9
    for i in 0...4 {
        let k = i % 4
        var p = beat()
        p.spine = -8
        p.head = 8
        let sines: [float32] = [1, 0, -1, 0], cosines: [float32] = [0, 1, 0, -1]
        let s = sines[k], c = cosines[k]
        p.lower = [-25 + 10 * c, -25 - 10 * c]
        p.swing = [20 + 30 * s, 20 - 30 * s]
        p.elbow = [35 + 15 * c, 35 - 15 * c]
        p.hip = [-35 + 25 * s, -35 - 25 * s]
        p.knee = [55 - 30 * s, 55 + 30 * s]
        p.ankle = [20, 20]
        p.spread = [6, 6]
        write(r, b, d * float32(i) / 4, p)
    }
    return b.clip("fall", duration: d, looping: true)
}

// ---- arms over the body ----

// armBeat is one arm's pose: down from the A-pose, swung forward, the
// elbow's bend, and the wrist tipped forward (positive) or back.
struct armBeat {
    var lower: float32
    var swing: float32
    var elbow: float32
    var wrist: float32 = 0
}

// writeArm keys one arm.
func writeArm(_ r: Rig, _ b: builder, _ t: float32, _ side: int, _ a: armBeat) {
    let out: float32 = side == Left ? 1 : -1
    b.key(r.UpperArm[side], t, ax(-a.swing) * az(-out * a.lower))
    b.key(r.Forearm[side], t, geom.AxisAngle(r.ElbowAxis(side), a.elbow * deg - r.ElbowBend(side)))
    b.key(r.Hand[side], t, ax(a.wrist))
}

// Holding a staff: the upper arm at the side a little forward, the
// forearm forward, the fist at the hip's height in front.
let holdArm = armBeat(lower: 32, swing: 14, elbow: 82)

func hold(_ r: Rig) -> anim.Clip {
    let b = builder()
    writeArm(r, b, 0, Right, holdArm)
    return b.clip("hold", duration: 1, looping: false)
}

func cast(_ r: Rig) -> anim.Clip {
    let b = builder()
    let d: float32 = 0.8
    // (time, right arm, left arm, chest lean forward, spine lean)
    let beats: [(float32, armBeat, armBeat, float32, float32)] = [
        (0, holdArm, armBeat(lower: 38, swing: 4, elbow: 16), 1, 1),
        // Raise it high, lean back a little, the left hand comes up.
        (0.24, armBeat(lower: 20, swing: 105, elbow: 60, wrist: 80), armBeat(lower: 30, swing: 35, elbow: 70), -6, -2),
        // Thrust: the arm out in front, the staff's head tipped toward the
        // target, the left palm pushing after it, leaning in.
        (0.36, armBeat(lower: 12, swing: 78, elbow: 12, wrist: 38), armBeat(lower: 18, swing: 62, elbow: 22), 10, 4),
        (0.5, armBeat(lower: 14, swing: 72, elbow: 18, wrist: 30), armBeat(lower: 22, swing: 50, elbow: 30), 8, 3),
        (d, holdArm, armBeat(lower: 38, swing: 4, elbow: 16), 1, 1),
    ]
    for (t, right, left, chest, spine) in beats {
        writeArm(r, b, t, Right, right)
        writeArm(r, b, t, Left, left)
        b.key(r.Chest, t, ax(chest))
        b.key(r.Spine, t, ax(spine))
    }
    var c = b.clip("cast", duration: d, looping: false)
    c.Events = [anim.Event("release", at: 0.36)]
    return c
}
