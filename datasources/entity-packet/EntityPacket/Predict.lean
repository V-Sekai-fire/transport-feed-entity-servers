namespace EntityPacket

/-! # Makima dead reckoning in whole numbers

A decoder that holds the acked snapshot at tick L, and the packet's own `vel` at tick L + lag,
predicts the position at L + lag. Both ends must compute the same prediction, so this is
integer arithmetic with every rounding written down. The curve is the one in Godot's
`Animation::makima_interpolate_in_time` (modified Akima), through the velocity samples at
L - 2, L - 1, L and L + lag. The two samples after L + lag do not exist; they take Akima's edge
rule (`2 * edge - next`), as the knots coincide.

Units: `vel` codes are Int16 with `vmax` micrometres per tick at 32767, so a displacement in
micrometres is `sum over k = 1..lag of v(L + k) * vmax / 32767`.

Rounding: every division except the last is truncation toward zero (`Int.tdiv`, which is C `/`).
The last one rounds half away from zero (`rdiv`). Lean's `/` on `Int` floors, and C's truncates,
so neither is used for anything the C header repeats.

Cost: three acked snapshots of `vel` per entity per client. -/

/-- Velocity scale for the tangents: raw codes are multiplied by this before any slope is taken,
    so a truncated tangent is off by well under a micrometre. -/
def PQ : Int := 65536
def RAW_MAX : Int := 32767

def absI (x : Int) : Int := if x < 0 then -x else x

def tang (p0 p1 p2 p3 : Int) : Int :=
  let w1 := 2 * absI (p3 - p2) + absI (p3 + p2)
  let w2 := 2 * absI (p1 - p0) + absI (p1 + p0)
  let s := w1 + w2
  if s == 0 then Int.tdiv (p1 + p2) 2 else Int.tdiv (w1 * p1 + w2 * p2) s

/-- Round half away from zero; `d > 0`. -/
def rdiv (n d : Int) : Int :=
  if n >= 0 then Int.tdiv (2 * n + d) (2 * d) else -(Int.tdiv (-2 * n + d) (2 * d))

/-- The four sums over k = 1..lag of the cubic Hermite numerators, in closed form. -/
def coeffs (lag : Int) : Int × Int × Int × Int :=
  let s1 := Int.tdiv (lag * (lag + 1)) 2
  let s2 := Int.tdiv (lag * (lag + 1) * (2 * lag + 1)) 6
  let s3 := s1 * s1
  (2 * s3 - 3 * lag * s2 + lag * lag * lag * lag, s3 - 2 * lag * s2 + lag * lag * s1,
   -2 * s3 + 3 * lag * s2, s3 - lag * s2)

def dispWith (rd : Int → Int → Int) (vpp vp vf vt lag vmax : Int) : Int :=
  if lag <= 0 then 0 else
  let aFrom := (vt - vf) * PQ
  let aPre := lag * (vf - vp) * PQ
  let aPP := lag * (vp - vpp) * PQ
  let aPost := 2 * aFrom - aPre
  let aPost2 := 2 * aPost - aFrom
  let tf := tang aPP aPre aFrom aPost
  let tt := tang aPre aFrom aPost aPost2
  let (ca, cb, cc, cd) := coeffs lag
  let n := ca * vf * PQ + cb * tf + cc * vt * PQ + cd * tt
  let d := rd (n * vmax) (RAW_MAX * PQ * lag * lag * lag)
  let cap := vmax * lag
  if d > cap then cap else if d < -cap then -cap else d

/-- Predicted displacement in micrometres of one axis, clamped to +-(vmax * lag). -/
def dispUm (vpp vp vf vt lag vmax : Int) : Int := dispWith rdiv vpp vp vf vt lag vmax

/-- Planted defect: floor division in the last step. The odd-symmetry check must fail on it. -/
def dispUmFloor (vpp vp vf vt lag vmax : Int) : Int := dispWith (fun n d => Int.fdiv n d) vpp vp vf vt lag vmax

def I64_MAX : Int := 9223372036854775807
def I64_MIN : Int := -9223372036854775808

/-- Position at L + lag, saturated to Int64. -/
def predictPosUm (base vpp vp vf vt lag vmax : Int) : Int :=
  let p := base + dispUm vpp vp vf vt lag vmax
  if p > I64_MAX then I64_MAX else if p < I64_MIN then I64_MIN else p

/-! The same curve in `Float`, summed one tick at a time. It is the reference the integer kernel
    is measured against, never part of the wire. -/
def tangF (p0 p1 p2 p3 : Float) : Float :=
  let w1 := (p3 - p2).abs + (p3 + p2).abs * 0.5
  let w2 := (p1 - p0).abs + (p1 + p0).abs * 0.5
  if w1 + w2 == 0.0 then (p1 + p2) * 0.5 else (w1 * p1 + w2 * p2) / (w1 + w2)

def dispFloatUm (vpp vp vf vt : Float) (lag : Nat) (vmax : Float) : Float := Id.run do
  let l := Float.ofNat lag
  let mFrom := (vt - vf) / l
  let mPre := vf - vp
  let mPost := 2.0 * mFrom - mPre
  let mPrePre := vp - vpp
  let mPostPost := 2.0 * mPost - mFrom
  let tF := tangF mPrePre mPre mFrom mPost
  let tT := tangF mPre mFrom mPost mPostPost
  let mut s := 0.0
  for k in [1:lag + 1] do
    let w := Float.ofNat k / l
    let w2 := w * w
    let w3 := w2 * w
    s := s + (2.0 * w3 - 3.0 * w2 + 1.0) * vf + (w3 - 2.0 * w2 + w) * l * tF
         + (-2.0 * w3 + 3.0 * w2) * vt + (w3 - w2) * l * tT
  return s * vmax / 32767.0

/-- Deterministic test inputs: (vpp, vp, vf, vt, lag, vmax). The same list is written as the golden
    CSV and read by the property executable. -/
def predictVectors (count : Nat) : Array (Int × Int × Int × Int × Nat × Int) := Id.run do
  let mut x : UInt64 := 0x9E3779B97F4A7C15
  let lags : Array Nat := #[1, 2, 6, 30, 255, 7, 100]
  let vmaxs : Array Int := #[500000, 166667, 1000000, 333333]
  let mut out := #[]
  for i in [0:count] do
    let mut v : Array Int := #[]
    for _ in [0:4] do
      x := x * 6364136223846793005 + 1442695040888963407
      let r := ((x >>> 33) % 65535).toNat
      let raw : Int := Int.ofNat r - 32767
      let pick := (x >>> 20) % 16
      v := v.push (if pick == 0 then 32767 else if pick == 1 then -32767 else if pick == 2 then 0 else raw)
    out := out.push (v[0]!, v[1]!, v[2]!, v[3]!, lags[i % lags.size]!, vmaxs[(i / 7) % vmaxs.size]!)
  return out

end EntityPacket
