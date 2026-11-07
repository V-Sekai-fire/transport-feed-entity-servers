import EntityPacket
open EntityPacket

def next (s : UInt64) : UInt64 := s * 6364136223846793005 + 1442695040888963407

def unit (s : UInt64) : Float := (s >>> 11).toFloat / 9007199254740992.0 * 2.0 - 1.0

def randQuats (n : Nat) : Array Quat := Id.run do
  let mut s : UInt64 := 88172645463325252
  let mut out := #[]
  for _ in [0:n] do
    s := next s
    let a := unit s
    s := next s
    let b := unit s
    s := next s
    let c := unit s
    s := next s
    let d := unit s
    out := out.push (Quat.normalize ⟨a, b, c, d⟩)
  return out

def angErr (a b : Quat) : Float :=
  let d := Quat.mul a (Quat.conj b)
  2.0 * Float.atan2 (Float.sqrt (d.x * d.x + d.y * d.y + d.z * d.z)) (Float.abs d.w)

def axisAngle (ax ay az ang : Float) : Quat :=
  ⟨ax * Float.sin (ang / 2), ay * Float.sin (ang / 2), az * Float.sin (ang / 2), Float.cos (ang / 2)⟩

def special : Array Quat :=
  let h := PI / 2
  #[Quat.identity, axisAngle 1 0 0 h, axisAngle 1 0 0 (-h), axisAngle 0 1 0 h, axisAngle 0 1 0 (-h),
    axisAngle 0 0 1 h, axisAngle 0 0 1 (-h), axisAngle 1 0 0 PI, axisAngle 0 0 1 PI,
    axisAngle 0 1 0 PI, Quat.mul (axisAngle 1 0 0 PI) (axisAngle 0 1 0 1.0),
    Quat.mul (axisAngle 0 0 1 (PI - 1e-6)) (axisAngle 0 1 0 3.1),
    Quat.mul (axisAngle 1 0 0 1e-7) (axisAngle 0 1 0 (-PI + 1e-7))]

def maxErr (rt : Quat → Quat) (qs : Array Quat) : Float × Nat :=
  qs.foldl (fun (m, bad) q =>
    let e := angErr (rt q) q
    if e.isNaN then (m, bad + 1) else (if e > m then e else m, bad)) (0.0, 0)

def linearGap (a b : Int16) : Int := (a.toInt - b.toInt).natAbs

def circularGap (a b : Int16) : Int :=
  let d := (a.toInt - b.toInt) % 65536
  if d > 32768 then 65536 - d else d

def codeGap (a b : Int16 × Int16 × Int16) : Int :=
  max (linearGap a.1 b.1) (max (linearGap a.2.1 b.2.1) (circularGap a.2.2 b.2.2))

def BOUND : Float := 2e-4

def main : IO UInt32 := do
  let qs := randQuats 100000 ++ special
  let mut fails := 0
  let check (name : String) (ok : Bool) (detail : String) : IO Nat := do
    IO.println s!"{if ok then "PASS" else "FAIL"} {name}: {detail}"
    pure (if ok then 0 else 1)
  fails := fails + (← check "Float is binary64" ((1.0 : Float) + 2.220446049250313e-16 > 1.0 && (1.0 : Float) + 1.1102230246251565e-16 == 1.0) "1 + 2^-52 is above 1, 1 + 2^-53 is not")
  let (e, nan) := maxErr (fun q => decodeRot (encodeRot q)) qs
  fails := fails + (← check "round trip quat" (e < BOUND && nan == 0) s!"max error {e} rad over {qs.size}, bound {BOUND}, nan {nan}")
  let (eb, nanb) := maxErr (fun q => (decodeRotBasis (encodeRotBasis (Basis.ofQuat q))).toQuat) qs
  fails := fails + (← check "round trip basis" (eb < BOUND && nanb == 0) s!"max error {eb} rad, nan {nanb}")
  let gap := qs.foldl (fun m q => max m (codeGap (encodeRot q) (encodeRotBasis (Basis.ofQuat q)))) 0
  fails := fails + (← check "basis and quat codes agree" (gap <= 1) s!"max gap {gap} LSB")
  let gapNeg := qs.foldl (fun m q => max m (codeGap (encodeRot q) (encodeRot q.neg))) 0
  fails := fails + (← check "q and -q" (gapNeg <= 1) s!"max gap {gapNeg} LSB")
  let dev := qs.foldl (fun m q => let d := Float.abs ((decodeRot (encodeRot q)).norm - 1.0); if d > m then d else m) 0.0
  fails := fails + (← check "decode is unit" (dev < 1e-9) s!"max deviation {dev}")
  let id := encodeRot Quat.identity
  fails := fails + (← check "identity" (id == (0, 0, 0)) s!"{id.1} {id.2.1} {id.2.2}")
  let tw := encodeRot (axisAngle 0 1 0 (PI / 2))
  fails := fails + (← check "twist 90 about Y" (tw.1 == 0 && tw.2.1 == 0 && circularGap tw.2.2 16384 <= 1) s!"{tw.1} {tw.2.1} {tw.2.2}")
  let sx := encodeRot (axisAngle 1 0 0 (PI / 2))
  fails := fails + (← check "swing 90 about X" (linearGap sx.1 16384 <= 1 && sx.2.1 == 0 && sx.2.2 == 0) s!"{sx.1} {sx.2.1} {sx.2.2}")
  let sz := encodeRot (axisAngle 0 0 1 (PI / 2))
  fails := fails + (← check "swing 90 about Z" (sz.1 == 0 && linearGap sz.2.1 16384 <= 1 && sz.2.2 == 0) s!"{sz.1} {sz.2.1} {sz.2.2}")
  let (e1, _) := maxErr (fun q => let c := encodeRot q; Quat.mul (twistFromCode c.2.2) (swingFromCodes c.1 c.2.1)) qs
  fails := fails + (← check "planted: swing and twist swapped is caught" (e1 > BOUND) s!"max error {e1}")
  let (e2, _) := maxErr (fun q => let c := encodeRot q; decodeRot (c.1, c.2.1, 0)) qs
  fails := fails + (← check "planted: twist dropped is caught" (e2 > BOUND) s!"max error {e2}")
  let (e3, _) := maxErr (fun q => decodeRot (encodeRot (Quat.mul (axisAngle 1 0 0 1e-3) q))) qs
  fails := fails + (← check "planted: 1 mrad offset is caught" (e3 > BOUND) s!"max error {e3}")
  let apply (b : Basis) (v : Float × Float × Float) : Float × Float × Float :=
    (b.cx.1 * v.1 + b.cy.1 * v.2.1 + b.cz.1 * v.2.2,
     b.cx.2.1 * v.1 + b.cy.2.1 * v.2.1 + b.cz.2.1 * v.2.2,
     b.cx.2.2 * v.1 + b.cy.2.2 * v.2.1 + b.cz.2.2 * v.2.2)
  let vdiff (a b : Float × Float × Float) : Float :=
    max (Float.abs (a.1 - b.1)) (max (Float.abs (a.2.1 - b.2.1)) (Float.abs (a.2.2 - b.2.2)))
  let noDet (f : Frame) (q : Quat) : Quat := let v := f.vecToWire (q.x, q.y, q.z); ⟨v.1, v.2.1, v.2.2, q.w⟩
  let frames : Array (String × Frame × (Float × Float × Float) × (Float × Float × Float)) :=
    #[("godot", Frame.godot, (0, 1, 0), (0, 0, -1)), ("unity", Frame.unity, (0, 1, 0), (0, 0, 1)),
      ("unreal", Frame.unreal, (0, 0, 1), (1, 0, 0)), ("blender", Frame.blender, (0, 0, 1), (0, 1, 0))]
  let v0 : Float × Float × Float := (0.3, -0.5, 0.8)
  let sub := qs.extract 0 20000
  for (name, f, up, fwd) in frames do
    fails := fails + (← check s!"{name}: valid signed permutation" f.valid s!"det {f.det}")
    let u := f.vecToWire up
    let w := f.vecToWire fwd
    fails := fails + (← check s!"{name}: up is wire +Y, forward is wire -Z" (vdiff u (0, 1, 0) < 1e-12 && vdiff w (0, 0, -1) < 1e-12) s!"up {u.1} {u.2.1} {u.2.2}, forward {w.1} {w.2.1} {w.2.2}")
    let gap := sub.foldl (fun m q => max m (codeGap (encodeRotIn f (f.quatFromWire q)) (encodeRot q))) 0
    fails := fails + (← check s!"{name}: same physical rotation, same codes" (gap == 0) s!"max gap {gap} LSB")
    let vd := sub.foldl (fun m q =>
      let qe := f.quatFromWire q
      max m (vdiff (f.vecToWire (apply (Basis.ofQuat qe) v0)) (apply (Basis.ofQuat q) (f.vecToWire v0)))) 0.0
    fails := fails + (← check s!"{name}: rotating a vector agrees across frames" (vd < 1e-9) s!"max difference {vd}")
    let (er, _) := maxErr (fun q => decodeRotIn f (encodeRotIn f q)) sub
    fails := fails + (← check s!"{name}: round trip in the engine frame" (er < BOUND) s!"max error {er} rad")
    let (eb, _) := maxErr (fun q => (decodeRotBasisIn f (encodeRotBasisIn f (Basis.ofQuat q))).toQuat) sub
    fails := fails + (← check s!"{name}: Basis round trip in the engine frame" (eb < BOUND) s!"max error {eb} rad")
    if f.det < 0 then
      let vdBad := sub.foldl (fun m q =>
        let qe := f.quatFromWire q
        max m (vdiff (f.vecToWire (apply (Basis.ofQuat qe) v0)) (apply (Basis.ofQuat (noDet f qe)) (f.vecToWire v0)))) 0.0
      fails := fails + (← check s!"planted: {name} without the det sign is caught" (vdBad > 1e-3) s!"max difference {vdBad}")
  let u := Frame.unity.quatToWire ⟨0.1, 0.2, 0.3, 0.4⟩
  fails := fails + (← check "godot to unity flips x and y" (u.x == -0.1 && u.y == -0.2 && u.z == 0.3 && u.w == 0.4) s!"{u.x} {u.y} {u.z} {u.w}")
  let gapWrong := sub.foldl (fun m q => max m (codeGap (encodeRotIn Frame.unreal (Frame.unity.quatFromWire q)) (encodeRot q))) 0
  fails := fails + (← check "planted: the wrong frame is caught" (gapWrong > 1) s!"max gap {gapWrong} LSB")
  IO.println s!"rot check: {fails} failing"
  pure (if fails == 0 then 0 else 1)
