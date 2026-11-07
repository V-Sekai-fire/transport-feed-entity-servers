import FeedServer.Conn
import FeedServer.Sqlite
/-! Event loop policy. The C socket glue (transports/csrc/poll_glue.c) moves bytes; everything else is here:
connection slots with generations, drain-then-COMMIT-then-send batches, send resumption,
held writes. Port of the `Server` part of datasources/reference/src/main.rs, over poll(2): a single listener,
one receive armed per connection, one send in flight per connection (no provided-buffer rings, no spill rings: simpler, slower). -/
namespace FeedServer.Server

@[extern "lean_net_start"] opaque ringStart (host : @& String) (port : UInt32) : IO String
@[extern "lean_net_arm_accept"] opaque armAccept : IO Nat
@[extern "lean_net_arm_recv"] opaque armRecv (slot tag : UInt32) : IO Nat
@[extern "lean_net_send"] opaque ringSend (slot tag : UInt32) (data : @& ByteArray) (off : USize) : IO Nat
@[extern "lean_net_close"] opaque ringClose (slot : UInt32) : IO Unit
@[extern "lean_net_wait"] opaque ringWait (timeoutNs : UInt64) : IO ByteArray
/-- Wait up to `ms` milliseconds for a completion. The C side splits the nanoseconds into
`tv_sec` and `tv_nsec`, so any `ms` whose nanoseconds fit in `UInt64` is valid (up to
18,446,744,073,709 ms). The kernel timespec needs ns, so `ringWait` stays the ns primitive. -/
def ringWaitMs (ms : UInt64) : IO ByteArray := ringWait (ms * 1000000)
@[extern "lean_net_wall_ms"] opaque wallMs : IO UInt64

structure Slot where
  gen     : UInt32 := 0
  open_   : Bool := false
  conn    : Conn.Conn := {}
  sending : Bool := false
  /-- bytes of `wire` already sent -/
  sent    : Nat := 0
  wire    : ByteArray := ByteArray.empty
deriving Inhabited

structure State where
  slots   : Array Slot
  touched : Array Nat := #[]
  held    : Array Nat := #[]

def opAccept : Nat := 1
def opRecv : Nat := 2
def opSend : Nat := 3

def sInt32 (n : Nat) : Int := if n ≥ 2 ^ 31 then Int.ofNat n - 2 ^ 32 else Int.ofNat n

def touch (st : State) (i : Nat) : State :=
  if st.touched.contains i then st else { st with touched := st.touched.push i }

/-- Serve bytes on slot `i` (empty data = retry what the connection already holds). -/
def serveSlot (env : App.Env) (st : State) (i : Nat) (data : ByteArray) : IO State := do
  let s := st.slots[i]!
  let c ← Conn.serve env Sqlite.writesHeld s.conn data
  let st := { st with slots := st.slots.set! i { s with conn := c } }
  let st := if c.inBatch then touch st i else st
  pure (if c.held && !st.held.contains i then { st with held := st.held.push i } else st)

/-- Start (or continue) the one send in flight, or close once output is drained. -/
def flush (st : State) (i : Nat) : IO State := do
  let s := st.slots[i]!
  if !s.open_ || s.sending then return st
  if s.conn.out.size > 0 then
    let wire := s.conn.out
    let n ← ringSend i.toUInt32 s.gen wire 0
    if n == 1 then
      return { st with slots := st.slots.set! i { s with sending := true, sent := 0, wire, conn := { s.conn with out := ByteArray.empty } } }
    else
      ringClose i.toUInt32
      return { st with slots := st.slots.set! i {} }
  else if s.conn.closeAfter then
    ringClose i.toUInt32
    return { st with slots := st.slots.set! i { gen := s.gen } }
  else return st

/-- A completion record: ud u64, res i32, len u32, cqe flags u32, then `len` data bytes. -/
def recHeader : Nat := 20
def cqeFMore : Nat := 2
def enobufs : Int := -105

def handleEntry (env : App.Env) (st : State) (u : Nat) (res : Int) (flags : Nat) (data : ByteArray) : IO State := do
  let op := u / 2 ^ 56
  let tag := ((u / 2 ^ 32) % 2 ^ 24)
  let slot := u % 2 ^ 32
  if op == opAccept then
    let _ ← armAccept
    if res < 0 then return st
    let i := res.toNat
    let st := if i < st.slots.size then st else { st with slots := st.slots ++ Array.replicate (i + 1 - st.slots.size) {} }
    let g := st.slots[i]!.gen + 1
    let _ ← armRecv i.toUInt32 g
    return { st with slots := st.slots.set! i { gen := g, open_ := true } }
  else
    let s := st.slots[slot]!
    if slot ≥ st.slots.size || s.gen.toNat % 2 ^ 24 != tag || !s.open_ then return st
    if op == opRecv then
      -- main.rs OP_RECV: the multishot receive re-arms itself while IORING_CQE_F_MORE is set
      let more := (flags / cqeFMore) % 2 == 1
      if res > 0 then
        let st ← serveSlot env st slot data
        if !more then
          let _ ← armRecv slot.toUInt32 s.gen
        return st
      else if res == enobufs then
        -- a burst emptied the buffer ring; the receive ended, so arm it again
        let _ ← armRecv slot.toUInt32 s.gen
        return st
      else
        -- EOF or error: finish what was asked, then close
        let st := { st with slots := st.slots.modify slot fun s => { s with conn := { s.conn with closeAfter := true } } }
        return touch st slot
    else if op == opSend then
      if res < 0 then
        ringClose slot.toUInt32
        return { st with slots := st.slots.set! slot { gen := s.gen } }
      let sent := s.sent + res.toNat
      if sent < s.wire.size then
        let _ ← ringSend slot.toUInt32 s.gen s.wire sent.toUSize
        return { st with slots := st.slots.set! slot { s with sent } }
      else
        let st := { st with slots := st.slots.set! slot { s with sending := false, wire := ByteArray.empty, sent := 0 } }
        return touch st slot
    else return st

partial def decode (env : App.Env) (st : State) (b : ByteArray) (o : Nat) : IO State := do
  if o + recHeader > b.size then return st
  let u := Sqlite.le b o 8
  let res := sInt32 (Sqlite.le b (o + 8) 4)
  let dl := Sqlite.le b (o + 12) 4
  let fl := Sqlite.le b (o + 16) 4
  let st ← handleEntry env st u res fl (b.extract (o + recHeader) (o + recHeader + dl))
  decode env st b (o + recHeader + dl)

/-- One pass's end: COMMIT, then answer/close every touched connection. -/
def endBatch (env : App.Env) (st : State) : IO State := do
  let committed ← App.endBatch env
  Sqlite.tick
  let mut st := st
  for i in st.touched do
    let s := st.slots[i]!
    st := { st with slots := st.slots.set! i { s with conn := Conn.endBatch committed s.conn } }
    st ← flush st i
  pure { st with touched := #[] }

partial def loop (env : App.Env) (st : State) : IO Unit := do
  let b ← ringWaitMs 1  -- 1 ms, a quarter of a 4 ms tick
  let st ← decode env st b 0
  -- held writes: retry once the checkpoint hold has ended
  let st ←
    if !st.held.isEmpty && !(← Sqlite.writesHeld) then
      let hs := st.held
      let mut st := { st with held := #[] }
      for i in hs do
        let s := st.slots[i]!
        if s.open_ then
          st := { st with slots := st.slots.modify i fun s => { s with conn := { s.conn with held := false } } }
          st ← serveSlot env st i ByteArray.empty
      pure st
    else pure st
  let st ← endBatch env st
  loop env st

def run (path secret host : String) (port : UInt32) : IO UInt32 := do
  let err ← Sqlite.openDb path
  if err != "" then IO.eprintln s!"database: {err}"; return 1
  let e ← ringStart host port
  if e != "" then IO.eprintln s!"listen: {e}"; return 1
  let wrote ← IO.mkRef false
  let t0 ← IO.monoMsNow
  let env : App.Env := {
    store := Db.store Sqlite.cursors, wrote, secret := secret.toUTF8,
    nowSecs := do pure (Float.ofNat (← wallMs).toNat / 1000.0),
    uptimeS := do pure (((← IO.monoMsNow) - t0) / 1000) }
  let _ ← armAccept
  IO.eprintln s!"listening on {host}:{port}; poll (Lean event loop)"
  loop env { slots := #[] }
  return 0

end FeedServer.Server
