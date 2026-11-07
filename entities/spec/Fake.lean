import FeedServer.All
/-! In-memory stand-in for the SQLite B-tree cursors: tables are arrays of encoded records. -/
open FeedServer

namespace Fake

def b (s : String) : ByteArray := s.toUTF8
def txt (s : String) : UInt64 × ByteArray := ((13 + 2 * s.utf8ByteSize).toUInt64, b s)
def int8 (n : Nat) : UInt64 × ByteArray := (1, ByteArray.mk #[n.toUInt8])
def nul : UInt64 × ByteArray := (0, ByteArray.empty)

/-- A record with one-byte header varints (fine for short fixtures). -/
def mkRec (cs : List (UInt64 × ByteArray)) : ByteArray :=
  let hdr : ByteArray := ByteArray.mk ((1 + cs.length).toUInt8 :: cs.map (fun c => c.1.toUInt8)).toArray
  hdr ++ cs.foldl (fun a c => a ++ c.2) ByteArray.empty

def ts (n : Nat) : String := s!"2026-01-01T00:00:0{n}.000Z"

def posts : Array (Int × ByteArray) := #[
  (1, mkRec [nul, int8 1, txt "a", txt (ts 1)]),
  (2, mkRec [nul, int8 2, txt "b\"q", txt (ts 2)]),
  (3, mkRec [nul, int8 1, txt "c", txt (ts 3)])]
def users : Array (Int × ByteArray) := #[
  (1, mkRec [nul, txt "ann", txt (ts 0)]),
  (2, mkRec [nul, txt "bob", txt (ts 0)])]
/-- posts_created_at_id_idx, newest first: (created_at, id, rowid). -/
def feedIdx : Array ByteArray := #[
  mkRec [txt (ts 3), int8 3, int8 3], mkRec [txt (ts 2), int8 2, int8 2], mkRec [txt (ts 1), int8 1, int8 1]]
/-- likes_post_id_idx: post ids, sorted. -/
def likesIdx : Array Int := #[1, 2, 2]

def cursors (fast : Bool) : IO Db.Cursors := do
  let pos ← IO.mkRef (#[0, 0, 0, 0] : Array Nat)
  let cur ← IO.mkRef (#[none, none, none, none] : Array (Option ByteArray))
  let setCur := fun (i : Nat) (p : Option ByteArray) => cur.modify (·.set! i p)
  let likeRec := fun (v : Int) => mkRec [int8 v.toNat, int8 0]
  let loadAt := fun (i p : Nat) => do
    let rec' : Option ByteArray := if i == 2 then feedIdx[p]? else (likesIdx[p]?).map likeRec
    setCur i rec'
    pure (if rec'.isSome then (1 : Int) else 0)
  pure {
    begin := pure true
    commit := pure true
    seek := fun i id => do
      let tbl := if i == 0 then posts else users
      match tbl.find? (·.1 == id) with
      | some (_, p) => setCur i (some p); pure 1
      | none => pure 0
    seekGe := fun i k => do
      match (List.range likesIdx.size).find? (fun p => likesIdx[p]! ≥ k) with
      | some p => pos.modify (·.set! i p); loadAt i p
      | none => pure 0
    first := fun i => do pos.modify (·.set! i 0); loadAt i 0
    next := fun i => do
      let p := (← pos.get)[i]! + 1
      pos.modify (·.set! i p)
      loadAt i p
    payload := fun i => do pure (← cur.get)[i]!
    countLikes := fun lo hi => do
      let n := (hi - lo + 1).toNat
      let counts := likesIdx.foldl (fun (a : Array Nat) v =>
        if lo ≤ v && v ≤ hi then a.modify (v - lo).toNat (· + 1) else a) (Array.replicate n 0)
      pure ((if fast then 0 else 1), counts)
    insertPost := fun _ _ => pure (some (4, b (ts 4)))
    insertLike := fun _ _ => pure 1
    health := pure (.ok ())
    feedSql := pure none }

end Fake
