// Package motion is how a person moves: a rig (a humanoid skeleton's
// bones found by name, and a ragdoll fitted to them), procedural clips
// (idle, walk, run, sprint, jump, fall, land, crouch), and Character: a
// controller, the animation, the ragdoll, and the states between them
// (moving, in the air, limp, getting up), under a player's or a mind's
// Input. Any skeleton with the bone names below works: humanoid's kits,
// character-sim's metaball man.
//
// Until anim/graph and active ragdolls exist, the state machine lives
// here (proposed_graphics_v3.md §3.4). The model faces +Z with Y up
// (glTF's way); its left is +X.
package motion

import (
    "anim"
    "anim/skin"
    "fs"
    "math"
    "math/geom"
    "mesh"
    "physics"
    "physics/ragdoll"
    "scene/gltf"
)

let deg = float32(math.Pi) / 180

/// Side indexes the paired bones: 0 left, 1 right.
public let Left = 0
public let Right = 1

/// Rig is the man's mesh, skeleton and skin, with his bones found by name.
public final class Rig {
    public let Mesh: mesh.Mesh
    public let Skeleton: anim.Skeleton
    public let Skin: skin.Skin
    /// Joint positions in model space at rest.
    public let Rest: [geom.Vec3]

    public let Hips: int
    public let Spine: int
    public let Chest: int
    public let Neck: int
    public let Head: int
    public let Shoulder: [int]
    public let UpperArm: [int]
    public let Forearm: [int]
    public let Hand: [int]
    public let Thigh: [int]
    public let Shin: [int]
    public let Foot: [int]
    public let Toe: [int]

    /// Load reads a rigged GLB with the bone names tools/make_man.py gives.
    public static func Load(_ path: fs.Path) throws -> Rig {
        let doc = try gltf.Load(path)
        return try Rig(try doc.Rig())
    }

    public convenience init(_ r: gltf.Rigged) throws {
        try self.init(skeleton: r.Skeleton, surface: r.Mesh, binding: r.Skin)
    }

    /// A rig for a skeleton alone, with the bone names above: a humanoid
    /// figure's, which draws its own meshes.
    public init(skeleton: anim.Skeleton, surface: mesh.Mesh? = nil, binding: skin.Skin? = nil) throws {
        Mesh = surface ?? mesh.Mesh()
        Skeleton = skeleton
        Skin = binding ?? skin.Skin()
        Rest = skeleton.RestPositions()
        let s = skeleton
        func find(_ name: string) throws -> int {
            guard let i = s.Index(of: name) else { throw RigError(Message: "no bone named \(name)") }
            return i
        }
        func pair(_ name: string) throws -> [int] { return [try find(name + ".L"), try find(name + ".R")] }
        Hips = try find("hips")
        Spine = try find("spine")
        Chest = try find("chest")
        Neck = try find("neck")
        Head = try find("head")
        Shoulder = try pair("shoulder")
        UpperArm = try pair("upper_arm")
        Forearm = try pair("forearm")
        Hand = try pair("hand")
        Thigh = try pair("thigh")
        Shin = try pair("shin")
        Foot = try pair("foot")
        Toe = try pair("toe")
    }

    /// ArmDirection is the unit direction an upper arm points at rest.
    public func ArmDirection(_ side: int) -> geom.Vec3 {
        return (Rest[Forearm[side]] - Rest[UpperArm[side]]).Normalized()
    }

    /// ElbowBend is how far an elbow is already bent at rest, radians.
    public func ElbowBend(_ side: int) -> float32 {
        let up = ArmDirection(side)
        let fore = (Rest[Hand[side]] - Rest[Forearm[side]]).Normalized()
        return math.Acos(math.Clamp(up.Dot(fore), -1, 1))
    }

    /// ElbowAxis is the axis an elbow bends about, in the arm's rest
    /// space: square to the arm and to forward, so a positive turn brings
    /// the hand forward and up.
    public func ElbowAxis(_ side: int) -> geom.Vec3 {
        return ArmDirection(side).Cross(geom.Vec3.UnitZ).Normalized()
    }

    /// Parts is his ragdoll: fifteen bodies from the pelvis out, sized
    /// to the mesh, with joints limited to what a body can do.
    public func Parts() -> [ragdoll.Part] {
        let along = geom.AxisAngle(geom.Vec3.UnitZ, 90 * deg)   // a capsule lying along X
        var parts: [ragdoll.Part] = []
        parts.append(ragdoll.Part("hips", bone: Hips, parent: -1, shape: .capsule(radius: 0.12, halfHeight: 0.06), mass: 12,
                                  offset: geom.Transform(position: geom.Vec3(0, -0.035, 0.0), rotation: along)))
        parts.append(ragdoll.Part("spine", bone: Spine, parent: 0, shape: .capsule(radius: 0.11, halfHeight: 0.05), mass: 9,
                                  offset: geom.Transform(position: geom.Vec3(0, 0.08, 0), rotation: along),
                                  limits: physics.Limits(twistMin: -25 * deg, twistMax: 25 * deg, swingXMin: -20 * deg, swingXMax: 40 * deg,
                                                         swingZMin: -20 * deg, swingZMax: 20 * deg)))
        parts.append(ragdoll.Part("chest", bone: Chest, parent: 1, shape: .capsule(radius: 0.12, halfHeight: 0.065), mass: 14,
                                  offset: geom.Transform(position: geom.Vec3(0, 0.1, 0.0), rotation: along),
                                  limits: physics.Limits(twistMin: -20 * deg, twistMax: 20 * deg, swingXMin: -15 * deg, swingXMax: 30 * deg,
                                                         swingZMin: -15 * deg, swingZMax: 15 * deg)))
        parts.append(ragdoll.Part("neck", bone: Neck, parent: 2, shape: .capsule(radius: 0.05, halfHeight: 0.025), mass: 1.5,
                                  offset: geom.Transform(position: geom.Vec3(0, 0.05, 0)),
                                  limits: physics.Limits(twistMin: -40 * deg, twistMax: 40 * deg, swingXMin: -30 * deg, swingXMax: 40 * deg,
                                                         swingZMin: -25 * deg, swingZMax: 25 * deg)))
        parts.append(ragdoll.Part("head", bone: Head, parent: 3, shape: .sphere(radius: 0.1), mass: 5,
                                  offset: geom.Transform(position: geom.Vec3(0, 0.085, 0.015)),
                                  limits: physics.Limits(twistMin: -40 * deg, twistMax: 40 * deg, swingXMin: -30 * deg, swingXMax: 35 * deg,
                                                         swingZMin: -20 * deg, swingZMax: 20 * deg)))
        for side in [Left, Right] {
            let name = side == Left ? ".L" : ".R"
            // Upper arm, hanging from the chest at the shoulder.
            let d = ArmDirection(side)
            let frame = geom.FromTo(geom.Vec3.UnitY, d)
            let upper = (Rest[Forearm[side]] - Rest[UpperArm[side]]).Length()
            let ua = parts.count
            parts.append(ragdoll.Part("upper_arm" + name, bone: UpperArm[side], parent: 2,
                                      shape: .capsule(radius: 0.048, halfHeight: math.Max(0.02, upper / 2 - 0.048)), mass: 2.5,
                                      offset: geom.Transform(position: d * (upper / 2), rotation: frame), frame: frame,
                                      limits: physics.Limits(twistMin: -70 * deg, twistMax: 70 * deg, swingXMin: -50 * deg, swingXMax: 100 * deg,
                                                             swingZMin: side == Left ? -55 * deg : -85 * deg,
                                                             swingZMax: side == Left ? 85 * deg : 55 * deg)))
            // Forearm and hand as one, bending at the elbow. The hinge's
            // limits count from the rest pose, which may already be bent
            // (MakeHuman's is): straight is behind it, fully bent ahead.
            let fd = (Rest[Hand[side]] - Rest[Forearm[side]]).Normalized()
            let bent = math.Acos(math.Clamp(d.Dot(fd), -1, 1))
            let fore = (Rest[Hand[side]] - Rest[Forearm[side]]).Length() + 0.16
            let ffr = geom.FromTo(geom.Vec3.UnitY, fd)
            parts.append(ragdoll.Part("forearm" + name, bone: Forearm[side], parent: ua,
                                      shape: .capsule(radius: 0.042, halfHeight: math.Max(0.02, fore / 2 - 0.042)), mass: 2,
                                      offset: geom.Transform(position: fd * (fore / 2), rotation: ffr),
                                      joint: .hinge, frame: ffr, hingeMin: -bent, hingeMax: 145 * deg - bent))
        }
        for side in [Left, Right] {
            let name = side == Left ? ".L" : ".R"
            let thigh = Rest[Shin[side]] - Rest[Thigh[side]]
            let th = parts.count
            parts.append(ragdoll.Part("thigh" + name, bone: Thigh[side], parent: 0,
                                      shape: .capsule(radius: 0.075, halfHeight: thigh.Length() / 2 - 0.06), mass: 9,
                                      offset: geom.Transform(position: thigh * 0.5, rotation: geom.FromTo(geom.Vec3.UnitY, thigh)),
                                      limits: physics.Limits(twistMin: -35 * deg, twistMax: 35 * deg, swingXMin: -110 * deg, swingXMax: 25 * deg,
                                                             swingZMin: side == Left ? -15 * deg : -50 * deg,
                                                             swingZMax: side == Left ? 50 * deg : 15 * deg)))
            let shin = Rest[Foot[side]] - Rest[Shin[side]]
            let sh = parts.count
            parts.append(ragdoll.Part("shin" + name, bone: Shin[side], parent: th,
                                      shape: .capsule(radius: 0.055, halfHeight: shin.Length() / 2 - 0.05), mass: 4,
                                      offset: geom.Transform(position: shin * 0.5, rotation: geom.FromTo(geom.Vec3.UnitY, shin)),
                                      joint: .hinge, hingeMin: 0, hingeMax: 150 * deg))
            // The foot: a box from the heel to past the toes, sole on the
            // floor at rest, sized from where the ankle and the ball are.
            let ankle = Rest[Foot[side]], ball = Rest[Toe[side]]
            let heelZ = ankle.Z - 0.06, tipZ = ball.Z + 0.06
            let soleY = -ankle.Y, topY: float32 = 0.02
            let foot = geom.Vec3(0.045, (topY - soleY) / 2, (tipZ - heelZ) / 2)
            parts.append(ragdoll.Part("foot" + name, bone: Foot[side], parent: sh,
                                      shape: .box(halfExtents: foot), mass: 1.2,
                                      offset: geom.Transform(position: geom.Vec3(ball.X - ankle.X, (topY + soleY) / 2 + 0.003,
                                                                                 (tipZ + heelZ) / 2 - ankle.Z)),
                                      limits: physics.Limits(twistMin: -10 * deg, twistMax: 10 * deg, swingXMin: -30 * deg, swingXMax: 45 * deg,
                                                             swingZMin: -15 * deg, swingZMax: 15 * deg)))
        }
        return parts
    }
}

/// RigError is a mesh that isn't the man.
public struct RigError: Error, CustomStringConvertible {
    public let Message: string
    public var description: string { return "rig: \(Message)" }
}
