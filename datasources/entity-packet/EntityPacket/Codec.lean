namespace EntityPacket

/-- The 100-byte fabric entity packet, modelled exactly as the C++
    (`XRGridEntityPacket`). Every field is integral — the wire has no floats.
    This Lean spec is the source of truth the C++ must match; Plausible
    roundtrip properties find codec gaps without an engine rebuild. -/

def SIZE : Nat := 100
def PAYLOAD_OFFSET : Nat := 58
def PAYLOAD_LEN : Nat := SIZE - PAYLOAD_OFFSET   -- 42

/-- Where each field sits. Named rather than written into `encode` and `decode` as literals,
    because a third reader wants them: `Emit.lean` emits a C header for the plane and the edge
    that speak this wire, and an emitter that retyped the numbers could disagree with the spec
    it claims to come from. Here they are typed once and read three times. -/
def OFF_GID : Nat := 0
def OFF_POS : Nat := 4          -- three Int64, 8 apart
def OFF_VEL : Nat := 28         -- three Int16, 2 apart
def OFF_HLC : Nat := 40
def OFF_CLASS_OWNER : Nat := 44
def OFF_SUB_INDEX : Nat := 48
def OFF_ROT : Nat := 52         -- three Int16, 2 apart

/-- The i16 velocity scale, in micrometres per tick. It belongs to the predictive BVH
    (`PBVH_V_MAX_PHYSICAL_DEFAULT` in `lean-spatial-oracle`) and is repeated here because the
    packet cannot be decoded without it: a velocity field is meaningless without the scale it
    was divided by, and a consumer that guessed would be wrong quietly. -/
def V_MAX_UM_PER_TICK : Nat := 500000

abbrev Bytes := Array UInt8

/-- little-endian put/get for the widths the packet uses. -/
def putU32 (b : Bytes) (off : Nat) (v : UInt32) : Bytes := Id.run do
  let mut b := b
  for i in [0:4] do
    b := b.set! (off + i) (((v >>> (UInt32.ofNat (i*8))) &&& 0xFF).toUInt8)
  return b
def getU32 (b : Bytes) (off : Nat) : UInt32 := Id.run do
  let mut v : UInt32 := 0
  for i in [0:4] do
    v := v ||| ((b[off+i]!).toUInt32 <<< (UInt32.ofNat (i*8)))
  return v

def putI64 (b : Bytes) (off : Nat) (v : Int64) : Bytes := Id.run do
  let u : UInt64 := v.toUInt64
  let mut b := b
  for i in [0:8] do
    b := b.set! (off + i) (((u >>> (UInt64.ofNat (i*8))) &&& 0xFF).toUInt8)
  return b
def getI64 (b : Bytes) (off : Nat) : Int64 := Id.run do
  let mut u : UInt64 := 0
  for i in [0:8] do
    u := u ||| ((b[off+i]!).toUInt64 <<< (UInt64.ofNat (i*8)))
  return u.toInt64

def putI16 (b : Bytes) (off : Nat) (v : Int16) : Bytes := Id.run do
  let u : UInt16 := v.toUInt16
  let b := b.set! off ((u &&& 0xFF).toUInt8)
  b.set! (off+1) (((u >>> 8) &&& 0xFF).toUInt8)
def getI16 (b : Bytes) (off : Nat) : Int16 :=
  (((b[off]!).toUInt16) ||| ((b[off+1]!).toUInt16 <<< 8)).toInt16

/-- An entity envelope's integral fields (position already in μm). -/
structure Packet where
  gid       : UInt32
  posUm     : Int64 × Int64 × Int64   -- absolute micrometers
  vel       : Int16 × Int16 × Int16   -- PBVH-scaled i16
  hlc       : UInt32
  classOwner: UInt32                   -- (class<<24)|owner
  subIndex  : UInt32
  rot       : Int16 × Int16 × Int16    -- swing-twist
  payload   : Bytes                    -- 42 bytes
  deriving Repr

def encode (p : Packet) : Bytes := Id.run do
  let mut b : Bytes := Array.replicate SIZE 0
  b := putU32 b OFF_GID p.gid
  b := putI64 b OFF_POS p.posUm.1
  b := putI64 b (OFF_POS + 8) p.posUm.2.1
  b := putI64 b (OFF_POS + 16) p.posUm.2.2
  b := putI16 b OFF_VEL p.vel.1
  b := putI16 b (OFF_VEL + 2) p.vel.2.1
  b := putI16 b (OFF_VEL + 4) p.vel.2.2
  b := putU32 b OFF_HLC p.hlc
  b := putU32 b OFF_CLASS_OWNER p.classOwner
  b := putU32 b OFF_SUB_INDEX p.subIndex
  b := putI16 b OFF_ROT p.rot.1
  b := putI16 b (OFF_ROT + 2) p.rot.2.1
  b := putI16 b (OFF_ROT + 4) p.rot.2.2
  for i in [0:PAYLOAD_LEN] do
    if h : i < p.payload.size then
      b := b.set! (PAYLOAD_OFFSET + i) (p.payload[i]!)
  return b

def decode (b : Bytes) : Packet :=
  { gid := getU32 b OFF_GID
    posUm := (getI64 b OFF_POS, getI64 b (OFF_POS + 8), getI64 b (OFF_POS + 16))
    vel := (getI16 b OFF_VEL, getI16 b (OFF_VEL + 2), getI16 b (OFF_VEL + 4))
    hlc := getU32 b OFF_HLC
    classOwner := getU32 b OFF_CLASS_OWNER
    subIndex := getU32 b OFF_SUB_INDEX
    rot := (getI16 b OFF_ROT, getI16 b (OFF_ROT + 2), getI16 b (OFF_ROT + 4))
    payload := (Array.range PAYLOAD_LEN).map (fun i => b[PAYLOAD_OFFSET + i]!) }

def PI : Float := 3.141592653589793

/-- Swing codes count half-turns of the rotation vector: a swing of pi is 32767. -/
def SWING_LSB_PER_RAD : Float := 32767.0 / PI

/-- The twist code is circular: a full turn is 65536, so pi and -pi are the same code. -/
def TWIST_LSB_PER_RAD : Float := 65536.0 / (2.0 * PI)

/-- A rotation as a unit quaternion, in Godot's `Quaternion` component order. -/
structure Quat where
  x : Float
  y : Float
  z : Float
  w : Float
  deriving Repr

/-- A rotation as Godot's `Basis`: `cx`, `cy` and `cz` are `Basis.x`, `Basis.y` and `Basis.z`,
    the images of the three axes. -/
structure Basis where
  cx : Float × Float × Float
  cy : Float × Float × Float
  cz : Float × Float × Float
  deriving Repr

namespace Quat

def identity : Quat := ⟨0, 0, 0, 1⟩

def conj (q : Quat) : Quat := ⟨-q.x, -q.y, -q.z, q.w⟩

/-- `q` and `neg q` are the same rotation. -/
def neg (q : Quat) : Quat := ⟨-q.x, -q.y, -q.z, -q.w⟩

/-- `mul a b` applies `b` first, then `a`, as Godot's `a * b`. -/
def mul (a b : Quat) : Quat :=
  ⟨a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
   a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
   a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
   a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z⟩

def norm (q : Quat) : Float :=
  Float.sqrt (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)

def normalize (q : Quat) : Quat :=
  let n := q.norm
  if n < 1e-12 then identity else ⟨q.x / n, q.y / n, q.z / n, q.w / n⟩

end Quat

/-- Encode step 1. The twist of `q`: its turn about +Y, found by keeping only the Y and W
    components. If both vanish the twist is the identity. -/
def twistOf (q : Quat) : Quat := Quat.normalize ⟨0, q.y, 0, q.w⟩

/-- Encode step 2. The swing of `q`: what is left once the twist is divided out, so that
    `q = swing * twist`. Its axis lies in the XZ plane. A swing of exactly pi has two names, `s`
    and `neg s`; the one with `w > 0` is taken, and at `w = 0` the one with `x > 0`, then `z > 0`. -/
def swingOf (q : Quat) : Quat :=
  let s := Quat.mul q (Quat.conj (twistOf q))
  if s.w < 0.0 || (s.w == 0.0 && (s.x < 0.0 || (s.x == 0.0 && s.z < 0.0))) then s.neg else s

/-- Encode step 3. The twist angle in radians, in (-pi, pi]. -/
def twistAngle (q : Quat) : Float :=
  let t := twistOf q
  2.0 * Float.atan2 t.y t.w

/-- Encode step 4. The swing as a rotation vector `(angle * axis.x, angle * axis.z)`, with the
    angle in [0, pi]. -/
def swingVector (s : Quat) : Float × Float :=
  let m := Float.sqrt (s.x * s.x + s.z * s.z)
  let k := if m < 1e-9 then 2.0 else 2.0 * Float.atan2 m s.w / m
  (k * s.x, k * s.z)

/-- Encode step 5. A rotation vector component, in radians, to its Int16 code. -/
def swingCode (v : Float) : Int16 := Float.toInt16 (Float.round (v * SWING_LSB_PER_RAD))

/-- Encode step 6. A twist angle, in radians, to its Int16 code, wrapped so that the angle pi
    and the angle -pi give one code. -/
def twistCode (theta : Float) : Int16 :=
  let k : Int := (Float.round (theta * TWIST_LSB_PER_RAD)).toInt64.toInt
  Int16.ofInt (((k + 32768) % 65536) - 32768)

/-- The three Int16 of `Packet.rot`, in order: swing rotation vector X, swing rotation vector
    Z, twist about Y. -/
def encodeRot (q : Quat) : Int16 × Int16 × Int16 :=
  let (rx, rz) := swingVector (swingOf q)
  (swingCode rx, swingCode rz, twistCode (twistAngle q))

/-- Decode step 1. The swing quaternion from its two rotation vector codes. -/
def swingFromCodes (cx cz : Int16) : Quat :=
  let rx := Float.ofInt cx.toInt / SWING_LSB_PER_RAD
  let rz := Float.ofInt cz.toInt / SWING_LSB_PER_RAD
  let phi := Float.sqrt (rx * rx + rz * rz)
  let k := if phi < 1e-9 then 0.5 else Float.sin (phi / 2.0) / phi
  ⟨k * rx, 0, k * rz, Float.cos (phi / 2.0)⟩

/-- Decode step 2. The twist quaternion from its code. -/
def twistFromCode (c : Int16) : Quat :=
  let theta := Float.ofInt c.toInt / TWIST_LSB_PER_RAD
  ⟨0, Float.sin (theta / 2.0), 0, Float.cos (theta / 2.0)⟩

/-- Decode step 3. `swing * twist`: the twist is applied first. -/
def decodeRot (c : Int16 × Int16 × Int16) : Quat :=
  Quat.mul (swingFromCodes c.1 c.2.1) (twistFromCode c.2.2)

/-- The `Basis` of a unit quaternion, as Godot's `Basis(Quaternion)`. -/
def Basis.ofQuat (q : Quat) : Basis :=
  let xx := q.x * q.x
  let yy := q.y * q.y
  let zz := q.z * q.z
  { cx := (1 - 2 * (yy + zz), 2 * (q.x * q.y + q.z * q.w), 2 * (q.x * q.z - q.y * q.w))
    cy := (2 * (q.x * q.y - q.z * q.w), 1 - 2 * (xx + zz), 2 * (q.y * q.z + q.x * q.w))
    cz := (2 * (q.x * q.z + q.y * q.w), 2 * (q.y * q.z - q.x * q.w), 1 - 2 * (xx + yy)) }

/-- The unit quaternion of an orthonormal `Basis` with determinant +1. It branches on the
    largest of the trace and the three diagonal entries, so the divisor never approaches zero.
    The sign of the result is not fixed, and `encodeRot` does not depend on it. -/
def Basis.toQuat (b : Basis) : Quat :=
  let m00 := b.cx.1
  let m10 := b.cx.2.1
  let m20 := b.cx.2.2
  let m01 := b.cy.1
  let m11 := b.cy.2.1
  let m21 := b.cy.2.2
  let m02 := b.cz.1
  let m12 := b.cz.2.1
  let m22 := b.cz.2.2
  let tr := m00 + m11 + m22
  if tr > 0 then
    let s := Float.sqrt (tr + 1) * 2
    ⟨(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, s / 4⟩
  else if m00 > m11 && m00 > m22 then
    let s := Float.sqrt (1 + m00 - m11 - m22) * 2
    ⟨s / 4, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s⟩
  else if m11 > m22 then
    let s := Float.sqrt (1 + m11 - m00 - m22) * 2
    ⟨(m01 + m10) / s, s / 4, (m12 + m21) / s, (m02 - m20) / s⟩
  else
    let s := Float.sqrt (1 + m22 - m00 - m11) * 2
    ⟨(m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s⟩

def encodeRotBasis (b : Basis) : Int16 × Int16 × Int16 := encodeRot b.toQuat

def decodeRotBasis (c : Int16 × Int16 × Int16) : Basis := Basis.ofQuat (decodeRot c)

/-- An engine's coordinate frame, as a signed permutation onto the wire frame. Each field says
    where one wire axis comes from: wire axis = sign * engine component `idx`. The wire frame
    is Godot's: X right, Y up, -Z forward, right-handed. The slot names `rot_x`, `rot_y` and
    `rot_z` are positions in the wire, not axes. -/
structure Frame where
  x : Nat × Int
  y : Nat × Int
  z : Nat × Int

namespace Frame

def godot : Frame := ⟨(0, 1), (1, 1), (2, 1)⟩

/-- Y up, +Z forward, left-handed. -/
def unity : Frame := ⟨(0, 1), (1, 1), (2, -1)⟩

/-- X forward, Y right, Z up, left-handed. -/
def unreal : Frame := ⟨(1, 1), (2, 1), (0, -1)⟩

/-- X right, Y forward, Z up, right-handed. -/
def blender : Frame := ⟨(0, 1), (2, 1), (1, -1)⟩

def valid (f : Frame) : Bool :=
  let idx := [f.x.1, f.y.1, f.z.1]
  idx.all (· < 3) && f.x.1 != f.y.1 && f.x.1 != f.z.1 && f.y.1 != f.z.1
    && [f.x.2, f.y.2, f.z.2].all (fun s => s == 1 || s == -1)

/-- +1 for a right-handed engine frame and -1 for a left-handed one. -/
def det (f : Frame) : Float :=
  let parity : Int := match (f.x.1, f.y.1, f.z.1) with
    | (0, 1, 2) | (1, 2, 0) | (2, 0, 1) => 1
    | _ => -1
  Float.ofInt (f.x.2 * f.y.2 * f.z.2 * parity)

private def pick (v : Float × Float × Float) : Nat → Float
  | 0 => v.1
  | 1 => v.2.1
  | _ => v.2.2

def vecToWire (f : Frame) (v : Float × Float × Float) : Float × Float × Float :=
  (Float.ofInt f.x.2 * pick v f.x.1, Float.ofInt f.y.2 * pick v f.y.1, Float.ofInt f.z.2 * pick v f.z.1)

def vecFromWire (f : Frame) (w : Float × Float × Float) : Float × Float × Float :=
  let comp (j : Nat) : Float :=
    if f.x.1 == j then Float.ofInt f.x.2 * w.1
    else if f.y.1 == j then Float.ofInt f.y.2 * w.2.1
    else Float.ofInt f.z.2 * w.2.2
  (comp 0, comp 1, comp 2)

/-- A rotation vector is an axial vector: a left-handed frame flips its sign, so the vector part
    of the quaternion carries `det` and `w` does not. -/
def quatToWire (f : Frame) (q : Quat) : Quat :=
  let v := f.vecToWire (q.x, q.y, q.z)
  ⟨f.det * v.1, f.det * v.2.1, f.det * v.2.2, q.w⟩

def quatFromWire (f : Frame) (q : Quat) : Quat :=
  let v := f.vecFromWire (f.det * q.x, f.det * q.y, f.det * q.z)
  ⟨v.1, v.2.1, v.2.2, q.w⟩

end Frame

def encodeRotIn (f : Frame) (q : Quat) : Int16 × Int16 × Int16 := encodeRot (f.quatToWire q)

def decodeRotIn (f : Frame) (c : Int16 × Int16 × Int16) : Quat := f.quatFromWire (decodeRot c)

def encodeRotBasisIn (f : Frame) (b : Basis) : Int16 × Int16 × Int16 := encodeRotIn f b.toQuat

def decodeRotBasisIn (f : Frame) (c : Int16 × Int16 × Int16) : Basis := Basis.ofQuat (decodeRotIn f c)

end EntityPacket
