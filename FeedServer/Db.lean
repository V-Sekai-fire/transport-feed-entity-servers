import FeedServer.Record
import FeedServer.Json
import FeedServer.App
/-! Database logic, ported from reference/src/db.rs.
All SQLite access goes through the abstract `Cursors` record. The FFI binding to the unmodified
SQLite shim fills it in; tests fill it with an in-memory fake. Nothing here rewrites SQLite. -/
namespace FeedServer.Db
open Record

/-- Cursor slots, as in shim.c: 0 posts, 1 users, 2 posts_created_at_id_idx, 3 likes_post_id_idx. -/
def curPosts : Nat := 0
def curUsers : Nat := 1
def curFeed : Nat := 2
def curLikes : Nat := 3

def feedLen : Nat := 20
/-- Count likes with one index range walk when the feed's ids span at most this many ids. -/
def rangeSpan : Int := 512

structure Cursors where
  begin      : IO Bool
  commit     : IO Bool
  /-- table cursor to rowid: 1 found, 0 absent, -1 error -/
  seek       : Nat → Int → IO Int
  /-- index cursor to first entry with leading integer ≥ k: 1 entry, 0 none, -1 error -/
  seekGe     : Nat → Int → IO Int
  first      : Nat → IO Int
  next       : Nat → IO Int
  payload    : Nat → IO (Option ByteArray)
  /-- likes per post for lo ≤ post_id ≤ hi: status (0 ok, 1 unexpected cell, -1 error) and counts -/
  countLikes : Int → Int → IO (Int × Array Nat)
  insertPost : Int → ByteArray → IO (Option (Int × ByteArray))
  /-- 1 inserted, 0 already liked, -1 error -/
  insertLike : Int → Int → IO Int
  health     : IO (Except String Unit)
  /-- reference SQL feed, rows as (id, body, created_at, author, likes) -/
  feedSql    : IO (Option (List (Int × ByteArray × ByteArray × ByteArray × Int)))

structure Row where
  id : Int
  userId : Int := 0
  body : ByteArray := ByteArray.empty
  created : ByteArray := ByteArray.empty
  author : ByteArray := ByteArray.empty
  likes : Int := 0
deriving Inhabited

def dbErr {α : Type} : IO α := throw (IO.userError "db")

def payloadOf (c : Cursors) (i : Nat) : IO ByteArray := do
  match ← c.payload i with
  | some p => pure p
  | none => dbErr

def cols (rec : ByteArray) (n : Nat) : IO (List (UInt64 × ByteArray)) :=
  match columns rec n with
  | some cs => pure cs
  | none => dbErr

def intCol (col : UInt64 × ByteArray) : IO Int :=
  match intOf col.1 col.2 with
  | some v => pure v
  | none => dbErr

def textCol (col : UInt64 × ByteArray) : IO ByteArray :=
  match text col with
  | some v => pure v
  | none => dbErr

/-- Likes of one post, decoding each entry here (cells the range walk does not expect). -/
partial def slowLoop (c : Cursors) (id n r : Int) : IO Int := do
  if r == 1 then
    let p ← payloadOf c curLikes
    match ← cols p 1 with
    | [k] =>
      if (← intCol k) != id then pure n
      else slowLoop c id (n + 1) (← c.next curLikes)
    | _ => dbErr
  else if r < 0 then dbErr
  else pure n

def countLikesSlow (c : Cursors) (id : Int) : IO Int := do
  slowLoop c id 0 (← c.seekGe curLikes id)

def countLikes (c : Cursors) (id : Int) : IO Int := do
  let (st, cnt) ← c.countLikes id id
  if st == 0 then pure (Int.ofNat (cnt.getD 0 0))
  else if st == 1 then countLikesSlow c id
  else dbErr

/-- Username of `uid`; `none` if there is no such user. -/
def author (c : Cursors) (uid : Int) : IO (Option ByteArray) := do
  let r ← c.seek curUsers uid
  if r == 1 then
    match ← cols (← payloadOf c curUsers) 2 with
    | [_, n] => some <$> textCol n
    | _ => dbErr
  else if r == 0 then pure none
  else dbErr

def lit (s : String) : ByteArray := s.toUTF8

def rowJson (r : Row) : ByteArray :=
  lit "{\"id\":" ++ Json.intBytes r.id ++ lit ",\"body\":\"" ++ Json.escape r.body
    ++ lit "\",\"created_at\":\"" ++ Json.escape r.created ++ lit "\",\"author\":\""
    ++ Json.escape r.author ++ lit "\",\"like_count\":" ++ Json.intBytes r.likes ++ lit "}"

def feedJson (rows : Array Row) : ByteArray := Id.run do
  let mut out := lit "{\"posts\":["
  let mut first := true
  for r in rows do
    if !first then out := out.push 44
    first := false
    out := out ++ rowJson r
  return out ++ lit "]}"

def postJson (r : Row) : ByteArray := lit "{\"post\":" ++ rowJson r ++ lit "}"

/-- Step 1: the index, newest first. -/
partial def indexLoop (c : Cursors) (r : Int) (acc : Array Row) : IO (Array Row) := do
  if r == 1 && acc.size < feedLen then
    let p ← payloadOf c curFeed
    match ← cols p 3 with
    | [ca, id, _] =>
      let created ← textCol ca
      let i ← intCol id
      indexLoop c (← c.next curFeed) (acc.push { id := i, created := created })
    | _ => dbErr
  else if r < 0 then dbErr
  else pure acc

/-- The feed rows by B-tree plan; `none` if the plain SQL query should answer instead. -/
def feedRows (c : Cursors) : IO (Option (Array Row)) := do
  let mut rows ← indexLoop c (← c.first curFeed) #[]
  -- 2. the posts, in ascending id order
  let snap := rows
  let order := (List.range snap.size).toArray.qsort (fun a b => snap[a]!.id < snap[b]!.id)
  for i in order do
    if (← c.seek curPosts rows[i]!.id) != 1 then return none
    match ← cols (← payloadOf c curPosts) 3 with
    | [_, uid, body] =>
      let u ← intCol uid
      let bd ← textCol body
      rows := rows.modify i (fun r => { r with userId := u, body := bd })
    | _ => dbErr
  -- 3. authors
  for i in [0:rows.size] do
    match ← author c rows[i]!.userId with
    | none => return none
    | some n => rows := rows.modify i (fun r => { r with author := n })
  -- 4. like counts
  if rows.size > 0 then
    let ids := rows.map (·.id)
    let lo := ids.foldl min ids[0]!
    let hi := ids.foldl max ids[0]!
    if hi - lo ≤ rangeSpan then
      let (st, cnt) ← c.countLikes lo hi
      if st == 0 then
        rows := rows.map (fun r => { r with likes := Int.ofNat (cnt.getD (r.id - lo).toNat 0) })
      else if st == 1 then
        for i in [0:rows.size] do
          let n ← countLikesSlow c rows[i]!.id
          rows := rows.modify i (fun r => { r with likes := n })
      else dbErr
    else
      for i in [0:rows.size] do
        let n ← countLikes c rows[i]!.id
        rows := rows.modify i (fun r => { r with likes := n })
  return some rows

def beginTx (c : Cursors) : IO Unit := do
  if !(← c.begin) then dbErr

def attempt {α : Type} (act : IO α) : IO (Except String α) := do
  try
    pure (.ok (← act))
  catch e =>
    pure (.error (toString e))

def feedBody (c : Cursors) : IO ByteArray := do
  beginTx c
  match ← feedRows c with
  | some rows => pure (feedJson rows)
  | none =>
    match ← c.feedSql with
    | some rs =>
      pure (feedJson (rs.toArray.map fun (id, b, ca, a, l) =>
        { id := id, body := b, created := ca, author := a, likes := l }))
    | none => dbErr

def postBody (c : Cursors) (id : Int) : IO (Option ByteArray) := do
  beginTx c
  let r ← c.seek curPosts id
  if r == 0 then pure none
  else if r != 1 then dbErr
  else
    match ← cols (← payloadOf c curPosts) 4 with
    | [_, uid, body, created] =>
      let u ← intCol uid
      let bd ← textCol body
      let cr ← textCol created
      match ← author c u with
      | none => pure none
      | some a =>
        let n ← countLikes c id
        pure (some (postJson { id := id, userId := u, body := bd, created := cr, author := a, likes := n }))
    | _ => dbErr

/-- The app's `Store`, over the cursor interface. -/
def store (c : Cursors) : App.Store where
  feed := attempt (feedBody c)
  post := fun id => attempt (postBody c id)
  health := do
    if !(← c.begin) then pure (.error "cannot begin transaction") else c.health
  insertPost := fun uid body => attempt do
    beginTx c
    match ← c.insertPost uid body with
    | some r => pure r
    | none => dbErr
  postExists := fun id => attempt do
    beginTx c
    let r ← c.seek curPosts id
    if r == 1 then pure true else if r == 0 then pure false else dbErr
  insertLike := fun u p => attempt do
    beginTx c
    let r ← c.insertLike u p
    if r == 1 then pure true else if r == 0 then pure false else dbErr
  commit := c.commit

end FeedServer.Db
