package motion

import (
    "anim"
    "math"
    "math/geom"
    "physics"
    "physics/character"
    "physics/collide"
    "physics/ragdoll"
)

/// State is what the man is doing.
public enum State {
    /// On his feet: standing, walking, running.
    case moving
    /// Jumping or falling, still in control.
    case air
    /// Limp: physics has him.
    case ragdoll
    /// Picking himself up off the ground.
    case gettingUp
}

/// Input is what a player or a mind asks of a character this tick.
public struct Input {
    /// Stick or keys: X right, Y forward, each -1…1, relative to the camera.
    public var Move = geom.Vec2.Zero
    /// The camera's heading: radians about Y, 0 looking down +Z.
    public var CameraYaw: float32 = 0
    /// Where to go in the world (X and Z; its length, up to 1, how fast),
    /// in place of Move: what a mind steering by the world gives.
    public var Direction: geom.Vec3? = nil
    public var Sprint = false
    public var Walk = false
    public var Jump = false

    public init() {}
}

/// Speeds, m/s.
public let WalkSpeed: float32 = 1.5
public let RunSpeed: float32 = 3.8
public let SprintSpeed: float32 = 6.8

/// Character is a person in the world: a capsule moved by a player or a
/// mind, an animated skeleton on it, and a ragdoll that takes over when
/// they fall too hard, are hit, or are told to go limp.
///
/// On its own (Update) it steps a physics world of its own. Many
/// characters share one world (init's `world:`) and a schedule runs each
/// tick's parts: Control at the fixed step, the world's Step, Settle,
/// then Animate once a frame.
public final class Character {
    public let Rig: Rig
    public let Clips: Clips
    public let Controller: character.Controller
    public let Physics: physics.World
    public let Ragdoll: ragdoll.Ragdoll
    public private(set) var Doing = State.moving
    /// Which way he faces: radians about Y, 0 facing +Z.
    public var Yaw: float32 = 0
    /// Every bone's placement in the world, for drawing.
    public private(set) var Bones: [geom.Transform]
    /// Seconds in the current state.
    public private(set) var StateTime: float32 = 0
    /// Why he last went limp, for the HUD.
    public private(set) var Reason = ""
    /// Colliders the capsule moves through: the floor.
    public var Colliders: [collide.Collider] = [collide.Collider(.plane)]

    var previous: [geom.Transform]
    var phase: float32 = 0
    var idleTime: float32 = 0
    var fallTime: float32 = 0
    var airWeight: float32 = 0
    var landWeight: float32 = 0
    var landStrength: float32 = 0
    var turnRate: float32 = 0
    var lastDt: float32 = 1.0 / 60
    var accumulator: float32 = 0
    var getUpFrom = anim.Pose(rest: 0)
    var restHeel: [geom.Vec3] = []
    var restToe: [geom.Vec3] = []

    /// Whether it steps its own physics world (made with none given).
    public let OwnsPhysics: bool

    /// Whether the right hand holds something (a staff): the arm keeps
    /// the hold pose over whatever the legs do.
    public var Holding = false
    /// Where the chest turns while acting: a direction in the world (nil:
    /// straight ahead).
    public var Aim: geom.Vec3? = nil
    /// The events the action layer passed in the last Animate (Play's
    /// clip's: "release"). TakeEvents reads and clears them.
    public private(set) var Events: [string] = []
    var action: anim.Layer? = nil
    var holdWeight: float32 = 0
    var upper: anim.Mask
    var rightArm: anim.Mask
    // Which way is up a held thing, in the right hand's own frame: up in
    // the hold pose.
    var heldAxis = geom.Vec3.UnitY

    public init(_ rig: Rig, at position: geom.Vec3, world: physics.World? = nil, clips: Clips? = nil) {
        Rig = rig
        Clips = clips ?? motion.Clips(rig)
        OwnsPhysics = world == nil
        Controller = character.Controller(at: position)
        Controller.Radius = 0.28
        Controller.Height = 1.8
        Controller.JumpSpeed = 5.2
        if let w = world {
            Physics = w
        } else {
            Physics = physics.World()
            Physics.Add(physics.Body(.fixed, .plane, name: "floor"))
        }
        // The ragdoll is built around the bones at rest, at the origin.
        var rest: [geom.Transform] = []
        for p in rig.Skeleton.Transforms(anim.Pose(rest: rig.Skeleton.Count)) { rest.append(p) }
        Ragdoll = ragdoll.Ragdoll(Physics, parts: rig.Parts(), rest: rest)
        Bones = rest
        previous = rest
        // The upper body: arms whole, the torso and head partly, so the
        // walk still shows through.
        let sk = rig.Skeleton
        upper = anim.Mask(count: sk.Count)
        upper.Set(sk, from: rig.Spine, 1)
        upper.Weights[rig.Spine] = 0.45
        upper.Weights[rig.Chest] = 0.75
        upper.Weights[rig.Neck] = 0.25
        upper.Weights[rig.Head] = 0.2
        rightArm = anim.Mask(count: sk.Count)
        rightArm.Set(sk, from: rig.UpperArm[Right], 1)
        // Where the soles are, for standing feet on the floor: under the
        // heel and under the toes, in the foot's and the toe's space.
        for side in [Left, Right] {
            let ankle = rig.Rest[rig.Foot[side]], toe = rig.Rest[rig.Toe[side]]
            restHeel.append(geom.Vec3(0, -ankle.Y, -0.035))
            restToe.append(geom.Vec3(0, -toe.Y, 0.07))
        }
        pose(0)
        // The hold pose's hand, to know which way is up a held staff.
        var hp = anim.Pose(rest: sk.Count)
        self.Clips.Idle.Sample(0, into: &hp)
        self.Clips.Hold.Sample(0, into: &hp)
        let hand = sk.Transforms(hp)[rig.Hand[Right]]
        heldAxis = hand.Rotation.Conjugate().Rotate(geom.Vec3.UnitY).Normalized()
    }

    /// Play plays a clip over the upper body (casting, waving, a swing),
    /// the legs still walking; it ends by itself. Not while limp.
    public func Play(_ clip: anim.Clip) {
        if Doing == .ragdoll || Doing == .gettingUp { return }
        action = anim.Layer(clip)
    }

    /// Acting is whether a clip from Play is playing, and how far in.
    public var Acting: bool { return action != nil }
    public var ActionTime: float32 { return action?.Time ?? 0 }

    /// TakeEvents is the action events since it was last asked, cleared.
    public func TakeEvents() -> [string] {
        let e = Events
        Events = []
        return e
    }

    /// Speed is how fast he's moving over the ground, m/s.
    public var Speed: float32 {
        if Doing == .ragdoll { return Ragdoll.Root.Velocity.Length() }
        return geom.Vec3(Controller.Velocity.X, 0, Controller.Velocity.Z).Length()
    }

    /// Focus is what a camera following him looks at: his chest.
    public var Focus: geom.Vec3 {
        return Bones[Rig.Chest].Position + geom.Vec3(0, 0.12, 0)
    }

    /// Socket is where a held thing goes, in the world: a staff, a sword,
    /// a lantern. Its +Y is along the held thing, its origin in the grip.
    /// In the right hand, up the thing is up in the hold pose (Holding);
    /// in the left, it runs up the arm's line, like a walking stick.
    public func Socket(_ side: int) -> geom.Transform {
        let hand = Bones[Rig.Hand[side]]
        let arm = Rig.ArmDirection(side)
        // In the hand's own (rest) frame: a little down the hand, in front
        // of the palm; the held thing runs back up the arm's line.
        let grip = arm * 0.075 + geom.Vec3(0, -0.02, 0.035)
        let along = side == Right ? heldAxis : -arm
        return hand * geom.Transform(position: grip, rotation: geom.FromTo(geom.Vec3.UnitY, along))
    }

    /// Placement is where he stands and which way he faces.
    public var Placement: geom.Transform {
        return geom.Transform(position: Controller.Position, rotation: geom.AxisAngle(geom.Vec3.UnitY, Yaw))
    }

    /// Update advances him by dt seconds, stepping his own physics world:
    /// a character on its own.
    public func Update(_ dt: float32, _ input: Input) {
        let h = math.Clamp(dt, 0.0001, 0.1)
        Control(h, input)
        if Doing == .ragdoll && OwnsPhysics {
            accumulator += h
            let step: float32 = 1.0 / 60
            while accumulator >= step {
                Physics.Step(step)
                accumulator -= step
            }
        }
        Settle(h)
        Animate(h)
    }

    /// Control is a fixed step's work before physics: moving under the
    /// input, and the states' clocks.
    public func Control(_ dt: float32, _ input: Input) {
        StateTime += dt
        switch Doing {
        case .moving, .air:
            control(dt, input)
        case .ragdoll:
            break
        case .gettingUp:
            if StateTime > 1.3 { set(.moving) }
        }
    }

    /// Settle is a fixed step's work after physics: limp, the bones come
    /// from the ragdoll, and once it has lain still he gets up.
    public func Settle(_ dt: float32) {
        if Doing != .ragdoll { return }
        simulate(dt)
        if (Ragdoll.StillFor > 0.6 && StateTime > 1.2) || StateTime > 8 { getUp() }
    }

    /// Animate is a frame's work: the pose, from the state (not while
    /// limp: the ragdoll has the bones).
    public func Animate(_ dt: float32) {
        let h = math.Clamp(dt, 0.0001, 0.1)
        if Doing != .ragdoll { pose(h) }
        lastDt = h
    }

    /// Hit knocks him down: limp, with an impulse (kg·m/s) at a point.
    /// Already limp, the impulse goes to the part nearest it.
    public func Hit(_ impulse: geom.Vec3, at point: geom.Vec3, reason: string = "hit") {
        if Doing == .ragdoll {
            Ragdoll.Push(impulse, at: point)
            StateTime = math.Min(StateTime, 0.5)
            return
        }
        GoLimp(reason, push: impulse, at: point)
    }

    /// GoLimp hands him to physics, moving as he was, with an extra kick
    /// (kg·m/s) at a point if given.
    public func GoLimp(_ reason: string, push: geom.Vec3 = geom.Vec3.Zero, at point: geom.Vec3? = nil) {
        if Doing == .ragdoll { return }
        action = nil
        Ragdoll.Activate(Bones, previous: previous, dt: lastDt)
        if push.LengthSquared() > 0 { Ragdoll.Push(push, at: point ?? Focus) }
        Reason = reason
        accumulator = 0
        set(.ragdoll)
    }

    /// Launch throws him: limp, and flying at `velocity` (each part keeps
    /// how it was moving relative to his hips, so limbs keep swinging).
    public func Launch(_ velocity: geom.Vec3) {
        if Doing != .ragdoll { GoLimp("launched") }
        let root = Ragdoll.Root.Velocity
        for b in Ragdoll.Bodies { b.Velocity = velocity + (b.Velocity - root) }
        // Some spin, so he tumbles.
        Ragdoll.Root.AngularVelocity += geom.Vec3(4, 0, 1.5)
    }

    /// Recover gets him up now, from wherever the ragdoll lies.
    public func Recover() {
        if Doing == .ragdoll { getUp() }
    }

    /// Respawn stands him at a place, facing a way.
    public func Respawn(_ at: geom.Vec3, yaw: float32) {
        Ragdoll.Deactivate()
        Controller.Place(at)
        Yaw = yaw
        set(at.Y > 0.01 ? .air : .moving)
        pose(0)
        previous = Bones
    }

    func set(_ s: State) {
        Doing = s
        StateTime = 0
    }

    // ---- in control ----

    func control(_ dt: float32, _ input: Input) {
        // What the stick asks for, in the world.
        var move = input.Move
        let len = move.Length()
        if len > 1 { move = move / len }
        let fwd = geom.Vec3(math.Sin(input.CameraYaw), 0, math.Cos(input.CameraYaw))
        let right = geom.Vec3(-fwd.Z, 0, fwd.X)
        var dir = fwd * move.Y + right * move.X
        if let d = input.Direction { dir = geom.Vec3(d.X, 0, d.Z) }
        let amount = math.Min(1, dir.Length())
        let top = input.Sprint ? SprintSpeed : (input.Walk ? WalkSpeed : RunSpeed)
        var wish = geom.Vec3.Zero
        if amount > 0.01 {
            dir = dir.Normalized()
            wish = dir * (top * amount)
            // Turn to face the way he's going; faster on foot than in the air.
            let target = math.Atan2(dir.X, dir.Z)
            let diff = wrap(target - Yaw)
            let rate: float32 = Doing == .air ? 3 : 11
            let step = math.Clamp(diff, -rate * dt, rate * dt)
            Yaw = wrap(Yaw + step)
            turnRate += (step / dt - turnRate) * math.Min(1, dt * 8)
        } else {
            turnRate += (0 - turnRate) * math.Min(1, dt * 8)
        }
        Controller.Move(dt, wish: wish, jump: input.Jump && Doing == .moving, colliders: Colliders)

        if Controller.Grounded {
            if Doing == .air {
                let hit = Controller.Landed
                if hit > 9.5 {
                    GoLimp("landed at \(Int(hit)) m/s")
                    return
                }
                landStrength = math.Clamp((hit - 2) / 5, 0.15, 1)
                landWeight = landStrength
                set(.moving)
            }
        } else if Doing == .moving && (Controller.Jumped || Controller.AirTime > 0.15) {
            set(.air)
            fallTime = 0
        }
        if Doing == .air && Controller.Velocity.Y < -13 {
            GoLimp("fell \(Int(Controller.Apex - Controller.Position.Y)) m")
        }
    }

    // ---- limp ----

    func simulate(_ dt: float32) {
        previous = Bones
        Ragdoll.Update(dt)
        Ragdoll.Bones(&Bones)
        // Bones without a body of their own ride on their parent.
        let simulated = Set(Ragdoll.Parts.map { $0.Bone })
        for (i, b) in Rig.Skeleton.Bones.enumerated() where !simulated.contains(i) && b.Parent >= 0 {
            Bones[i] = Bones[b.Parent] * geom.Transform(position: b.Pivot)
        }
        // The capsule follows along, so the camera and a later get-up
        // start from the right place.
        let hips = Bones[Rig.Hips].Position
        Controller.Place(geom.Vec3(hips.X, Ground(hips.X, hips.Z, below: hips.Y), hips.Z))
    }

    /// Ground is the height of the ground under (x, z), the first of the
    /// colliders met looking down from `below` (plus a little); 0 when
    /// there's nothing there.
    public func Ground(_ x: float32, _ z: float32, below y: float32) -> float32 {
        let from = geom.Vec3(x, y + 1, z)
        var best: float32 = -1
        for c in Colliders {
            if let h = collide.Raycast(c.Shape, c.Transform, origin: from, direction: geom.Vec3(0, -1, 0), maxDistance: 200) {
                if best < 0 || h.distance < best { best = h.distance }
            }
        }
        return best < 0 ? 0 : from.Y - best
    }

    func getUp() {
        let hips = Bones[Rig.Hips], head = Bones[Rig.Head]
        // Face down if his front points at the floor: he pushes up and
        // faces where his head was. Face up he sits up, facing his feet.
        let faceDown = hips.Rotation.Rotate(geom.Vec3.UnitZ).Y < 0
        var d = head.Position - hips.Position
        d.Y = 0
        if !faceDown { d = -d }
        if d.LengthSquared() > 1e-6 { Yaw = math.Atan2(d.X, d.Z) }
        Controller.Place(geom.Vec3(hips.Position.X, Ground(hips.Position.X, hips.Position.Z, below: hips.Position.Y), hips.Position.Z))
        // The ragdoll's pose, seen from where he'll stand.
        let inv = Placement.Inverse()
        var rotations: [geom.Quat] = []
        for b in Bones { rotations.append((inv * b).Rotation) }
        getUpFrom = Rig.Skeleton.PoseFrom(rotations: rotations, roots: [(inv * hips).Position])
        Ragdoll.Deactivate()
        landWeight = 0
        airWeight = 0
        set(.gettingUp)
    }

    // ---- animation ----

    // pose samples the animation for the current state into Bones.
    func pose(_ dt: float32) {
        previous = Bones
        let s = Rig.Skeleton
        var p: anim.Pose
        if Doing == .gettingUp {
            // Ragdoll → crouch, then crouch → standing.
            let crouch = grounded(sample(Clips.Crouch, 0))
            let stand = grounded(locomotion(dt))
            let t = StateTime
            if t < 0.55 {
                p = anim.Blend(getUpFrom, crouch, smooth(t / 0.55))
            } else {
                p = anim.Blend(crouch, stand, smooth(math.Min(1, (t - 0.55) / 0.75)))
            }
            // Blending a lying pose into a crouch can swing a foot through
            // the floor: lift him out, never pull him down.
            p = grounded(p, liftOnly: true)
        } else {
            let target: float32 = Doing == .air ? 1 : 0
            airWeight += (target - airWeight) * math.Min(1, dt * (target > airWeight ? 10 : 14))
            p = locomotion(dt)
            if airWeight > 0.001 {
                fallTime += dt
                let vy = Controller.Velocity.Y
                let falling = math.Clamp((-vy + 1) / 6, 0, 1)
                let air = anim.Blend(sample(Clips.Jump, 0), sample(Clips.Fall, fallTime), falling)
                p = anim.Blend(p, air, airWeight)
            }
            if landWeight > 0.001 {
                p = anim.Blend(p, sample(Clips.Land, 0), landWeight)
                landWeight = math.Max(0, landWeight - dt * (1.2 + 2.5 * (1 - landStrength)))
            }
            p = grounded(p, weight: 1 - airWeight)
            // Lean into turns.
            let bank = math.Clamp(-turnRate * Speed * 0.025, -0.3, 0.3)
            p.Rotations[Rig.Hips] = (geom.AxisAngle(geom.Vec3.UnitZ, bank) * p.Rotations[Rig.Hips]).Normalized()
        }
        p = overlay(p, dt)
        let place = Placement
        let model = s.Transforms(p)
        for i in 0..<model.count { Bones[i] = place * model[i] }
    }

    // overlay lays what the arms are doing over the legs': the hold pose
    // on the right arm, an action on the upper body, the chest turned
    // toward the aim.
    func overlay(_ pose: anim.Pose, _ dt: float32) -> anim.Pose {
        var p = pose
        let wantHold: float32 = Holding && Doing != .gettingUp ? 1 : 0
        holdWeight += (wantHold - holdWeight) * math.Min(1, dt * 8)
        if holdWeight > 0.001 {
            var hp = p
            Clips.Hold.Sample(0, into: &hp)
            p = anim.Blend(p, hp, holdWeight, mask: rightArm)
        }
        if var a = action {
            let t0 = a.Time
            a.Advance(dt)
            Events += a.Clip.Crossed(from: t0, to: a.Time)
            var ap = p
            a.Clip.Sample(a.Time, into: &ap)
            p = anim.Blend(p, ap, 1, mask: upper)
            // Turn the chest toward the aim: most of it in the chest, some
            // in the spine, as far as a body twists.
            if let aim = Aim, aim.LengthSquared() > 1e-6 {
                let d = aim.Normalized()
                let yaw = math.Clamp(wrap(math.Atan2(d.X, d.Z) - Yaw), -1.1, 1.1)
                let pitch = math.Clamp(math.Asin(math.Clamp(d.Y, -1, 1)), -0.7, 0.7)
                p.Rotations[Rig.Spine] = (geom.AxisAngle(geom.Vec3.UnitY, yaw * 0.4) * p.Rotations[Rig.Spine]).Normalized()
                p.Rotations[Rig.Chest] = (geom.AxisAngle(geom.Vec3.UnitY, yaw * 0.6) * geom.AxisAngle(geom.Vec3.UnitX, -pitch * 0.6) * p.Rotations[Rig.Chest]).Normalized()
            }
            action = a.Finished ? nil : a
        }
        return p
    }

    // locomotion is idle, walk, run and sprint blended by speed, their
    // cycles kept in step.
    func locomotion(_ dt: float32) -> anim.Pose {
        let v = Speed
        let speeds: [float32] = [0, WalkSpeed, RunSpeed, SprintSpeed]
        let strides: [float32] = [1.4, WalkSpeed * Clips.Walk.Duration, RunSpeed * Clips.Run.Duration, SprintSpeed * Clips.Sprint.Duration]
        var k = 0
        while k < 2 && v > speeds[k + 1] { k += 1 }
        let f = math.Clamp((v - speeds[k]) / (speeds[k + 1] - speeds[k]), 0, 1)
        let stride = strides[k] + (strides[k + 1] - strides[k]) * f
        phase = math.FloorMod(phase + v * dt / stride, 1)
        idleTime += dt
        let clips = [Clips.Idle, Clips.Walk, Clips.Run, Clips.Sprint]
        func at(_ i: int) -> anim.Pose {
            return i == 0 ? sample(Clips.Idle, idleTime) : sample(clips[i], phase * clips[i].Duration)
        }
        if v < 0.05 { return at(0) }
        return anim.Blend(at(k), at(k + 1), f)
    }

    func sample(_ c: anim.Clip, _ t: float32) -> anim.Pose {
        var p = anim.Pose(rest: Rig.Skeleton.Count)
        c.Sample(t, into: &p)
        return p
    }

    // grounded moves the hips down (or up) so the lower foot stands on
    // the floor: animations are made without caring how high the hips
    // end up.
    func grounded(_ pose: anim.Pose, weight: float32 = 1, liftOnly: bool = false) -> anim.Pose {
        var p = pose
        if weight <= 0 { return p }
        let t = Rig.Skeleton.Transforms(p)
        var low: float32 = 1e9
        for side in [Left, Right] {
            low = math.Min(low, t[Rig.Foot[side]].Point(restHeel[side]).Y)
            low = math.Min(low, t[Rig.Toe[side]].Point(restToe[side]).Y)
        }
        if liftOnly && low >= 0 { return p }
        p.Offsets[Rig.Hips].Y -= low * weight
        return p
    }
}

func wrap(_ a: float32) -> float32 {
    return math.Atan2(math.Sin(a), math.Cos(a))
}

func smooth(_ t: float32) -> float32 {
    let x = math.Clamp(t, 0, 1)
    return x * x * (3 - 2 * x)
}
