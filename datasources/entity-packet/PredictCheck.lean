import EntityPacket.Predict
open EntityPacket

def clampI (x cap : Int) : Int := if x > cap then cap else if x < -cap then -cap else x

/-- `lake exe predict_check` must pass. `lake exe predict_check plant` swaps in the floor-division
    kernel and must fail on the odd-symmetry check. -/
def main (args : List String) : IO UInt32 := do
  let plant := args.contains "plant"
  let disp := if plant then dispUmFloor else dispUm
  let vs := predictVectors 20000
  let mut fails : Array String := #[]
  -- constant velocity: Makima passes through constants, so the displacement is lag * v * vmax / 32767, rounded
  let mut constBad := 0
  for lag in [1:256] do
    for v in ([-32767, -1234, -1, 0, 1, 7, 1234, 32767] : List Int) do
      for vm in ([500000, 166667, 1000000] : List Int) do
        let l : Int := Int.ofNat lag
        if disp v v v v l vm != clampI (rdiv (l * v * vm) 32767) (vm * l) then constBad := constBad + 1
  if constBad > 0 then fails := fails.push s!"constant velocity: {constBad} mismatches"
  -- zero velocity, and lag 1 reduces to the rounded product
  let mut zeroBad := 0
  let mut lag1Bad := 0
  for (a, b, c, d, l, vm) in vs do
    if disp 0 0 0 0 (Int.ofNat l) vm != 0 then zeroBad := zeroBad + 1
    if disp a b c d 1 vm != clampI (rdiv (d * vm) 32767) vm then lag1Bad := lag1Bad + 1
  if zeroBad > 0 then fails := fails.push s!"zero velocity: {zeroBad} mismatches"
  if lag1Bad > 0 then fails := fails.push s!"lag 1: {lag1Bad} mismatches"
  -- odd symmetry: negating every velocity negates the displacement (catches floor-rounding bias)
  let mut oddBad := 0
  for (a, b, c, d, l, vm) in vs do
    let l' := Int.ofNat l
    if disp (-a) (-b) (-c) (-d) l' vm != -(disp a b c d l' vm) then oddBad := oddBad + 1
  if oddBad > 0 then fails := fails.push s!"odd symmetry: {oddBad} of {vs.size} vectors"
  -- the displacement never exceeds vmax * lag
  let mut capBad := 0
  for (a, b, c, d, l, vm) in vs do
    let l' := Int.ofNat l
    if absI (disp a b c d l' vm) > vm * l' then capBad := capBad + 1
  if capBad > 0 then fails := fails.push s!"cap: {capBad} mismatches"
  -- the closed-form sums equal the loop sums for every lag a byte can hold
  let mut sumBad := 0
  for lag in [1:256] do
    let l : Int := Int.ofNat lag
    let mut a : Int := 0
    let mut b : Int := 0
    let mut c : Int := 0
    let mut d : Int := 0
    for k in [1:lag + 1] do
      let k : Int := Int.ofNat k
      a := a + (2 * k * k * k - 3 * k * k * l + l * l * l)
      b := b + (k * k * k - 2 * k * k * l + k * l * l)
      c := c + (-2 * k * k * k + 3 * k * k * l)
      d := d + (k * k * k - k * k * l)
    if coeffs l != (a, b, c, d) then sumBad := sumBad + 1
  if sumBad > 0 then fails := fails.push s!"closed-form sums: {sumBad} lags differ"
  -- saturation at the Int64 edges
  if predictPosUm (I64_MAX - 5) 0 0 32767 32767 6 500000 != I64_MAX then fails := fails.push "saturation at Int64 max"
  if predictPosUm (I64_MIN + 5) 0 0 (-32767) (-32767) 6 500000 != I64_MIN then fails := fails.push "saturation at Int64 min"
  -- distance from the Float reference, in micrometres
  let mut worst : Float := 0.0
  for (a, b, c, d, l, vm) in vs do
    let f := dispFloatUm (Float.ofInt a) (Float.ofInt b) (Float.ofInt c) (Float.ofInt d) l (Float.ofInt vm)
    let cap := Float.ofInt vm * Float.ofNat l
    let f := if f > cap then cap else if f < -cap then -cap else f
    let e := (f - Float.ofInt (disp a b c d (Int.ofNat l) vm)).abs
    if e > worst then worst := e
  IO.println s!"max |integer - Float reference|: {worst} um over {vs.size} vectors"
  if worst > 1.0 then fails := fails.push s!"float distance {worst} um exceeds 1.0 um"
  if fails.isEmpty then
    IO.println "predict_check: PASS"
    return 0
  for f in fails do IO.println s!"predict_check FAIL {f}"
  return 1
