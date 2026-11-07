import FeedServer.App
/-! Per-connection policy, ported from reference/src/main.rs (`serve`, `mark`, `end_batch`).
No syscalls here: the io_uring glue only moves bytes. -/
namespace FeedServer.Conn
open Http

structure Conn where
  closeAfter : Bool := false
  /-- A write waits out a checkpoint hold. -/
  held       : Bool := false
  inBatch    : Bool := false
  answered   : Bool := false
  batchMark  : Nat := 0
  /-- Responses not yet handed to the kernel. -/
  out        : ByteArray := ByteArray.empty
  /-- An incomplete request. -/
  pending    : ByteArray := ByteArray.empty
deriving Inhabited

/-- Port of `mark`: remember where this batch's output starts. -/
def mark (c : Conn) : Conn :=
  if c.inBatch then c else { c with inBatch := true, batchMark := c.out.size }

def post : ByteArray := "POST".toUTF8

/-- Answer every complete request in `buf` from `off`; `fuel` bounds the request count. -/
def serveLoop (env : App.Env) (writesHeld : IO Bool) (buf : ByteArray) :
    Nat → Nat → Conn → IO (Nat × Conn)
  | 0, off, c => pure (off, c)
  | f + 1, off, c =>
    match parse (buf.extract off buf.size) with
    | .done req used => do
      if req.method == post && (← writesHeld) then
        pure (off, { c with held := true })
      else
        let c := mark c
        let resp ← App.handle env req
        let c := { c with answered := true, out := c.out ++ resp }
        let off := off + used
        if off == buf.size then pure (off, c) else serveLoop env writesHeld buf f off c
    | .incomplete => pure (off, c)
    | .bad =>
      let c := mark c
      pure (buf.size, { c with answered := true, closeAfter := true,
                               out := c.out ++ App.errorResp 400 "bad request" })

/-- Port of `serve`: earlier partial bytes first, leftovers stay on the connection. -/
def serve (env : App.Env) (writesHeld : IO Bool) (c : Conn) (data : ByteArray) : IO Conn := do
  if c.closeAfter then return c
  let buf := c.pending ++ data
  let (off, c) ← serveLoop env writesHeld buf (buf.size + 1) 0 { c with pending := ByteArray.empty }
  return { c with pending := buf.extract off buf.size }

/-- Port of the per-connection part of `end_batch`. A rolled-back batch must not leave a
success on the wire: its responses become one 500 and the connection closes. -/
def endBatch (committed : Bool) (c : Conn) : Conn :=
  if !committed && c.answered then
    { c with out := c.out.extract 0 c.batchMark ++ App.rolledBack, closeAfter := true,
             inBatch := false, answered := false }
  else { c with inBatch := false, answered := false }

theorem endBatch_committed (c : Conn) :
    endBatch true c = { c with inBatch := false, answered := false } := by
  simp [endBatch]

theorem endBatch_rollback_closes (c : Conn) (h : c.answered = true) :
    (endBatch false c).closeAfter = true ∧ (endBatch false c).answered = false := by
  simp [endBatch, h]

end FeedServer.Conn
