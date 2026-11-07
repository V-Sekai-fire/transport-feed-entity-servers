import FeedServer
open FeedServer

/-- Control against a real SQLite file: `sqlite-check path.db`. -/
def main (args : List String) : IO UInt32 := do
  let some path := args.head? | IO.eprintln "usage: sqlite-check DB"; return 2
  let err ← Sqlite.openDb path
  if err != "" then IO.eprintln s!"open: {err}"; return 1
  let st := Db.store Sqlite.cursors
  let show' := fun (x : Except String ByteArray) => match x with
    | .ok b => String.fromUTF8! b | .error e => s!"ERR {e}"
  IO.println s!"health: {repr (← st.health |>.map (·.isOk))}"
  IO.println s!"feed:   {show' (← st.feed)}"
  match ← st.post 2 with
  | .ok (some b) => IO.println s!"post2:  {String.fromUTF8! b}"
  | .ok none => IO.println "post2:  missing"
  | .error e => IO.println s!"post2:  ERR {e}"
  match ← st.post 99 with
  | .ok none => IO.println "post99: missing"
  | _ => IO.println "post99: unexpected"
  IO.println s!"like(2,1) new: {repr (← st.insertLike 2 1)}"
  IO.println s!"like(1,2) again: {repr (← st.insertLike 2 1)}"
  match ← st.insertPost 2 "from lean".toUTF8 with
  | .ok (id, ts) => IO.println s!"insert: id={id} created={String.fromUTF8! ts}"
  | .error e => IO.println s!"insert: ERR {e}"
  IO.println s!"commit: {← st.commit}"
  IO.println s!"feed2:  {show' (← st.feed)}"
  IO.println s!"commit: {← st.commit}"
  pure 0
