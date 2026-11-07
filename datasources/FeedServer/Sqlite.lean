import FeedServer.Db
/-! Binding to the unmodified SQLite shim (datasources/csrc/shim.c) through datasources/csrc/lean_glue.c.
Nothing here reimplements SQLite. Statuses from the glue are the shim result + 1. -/
namespace FeedServer.Sqlite

@[extern "lean_td_open"] opaque openDb (path : @& String) : IO String
@[extern "lean_td_begin"] opaque begin : IO Bool
@[extern "lean_td_commit"] opaque commit : IO Bool
@[extern "lean_td_tick"] opaque tick : IO Unit
@[extern "lean_td_writes_held"] opaque writesHeld : IO Bool
@[extern "lean_td_seek"] opaque seek (cur : UInt32) (id : UInt64) : IO Nat
@[extern "lean_td_seek_ge"] opaque seekGe (cur : UInt32) (k : UInt64) : IO Nat
@[extern "lean_td_first"] opaque first (cur : UInt32) : IO Nat
@[extern "lean_td_next"] opaque next (cur : UInt32) : IO Nat
@[extern "lean_td_payload"] opaque payload (cur : UInt32) : IO ByteArray
@[extern "lean_td_count_likes"] opaque countLikesRaw (cur : UInt32) (lo hi : UInt64) : IO ByteArray
@[extern "lean_td_insert_post"] opaque insertPostRaw (uid : UInt64) (body : @& ByteArray) : IO ByteArray
@[extern "lean_td_insert_like"] opaque insertLikeRaw (uid pid : UInt64) : IO Nat
@[extern "lean_td_health"] opaque healthRaw : IO String
@[extern "lean_td_feed_sql"] opaque feedSqlRaw : IO ByteArray

def st (n : Nat) : Int := Int.ofNat n - 1
def u64 (i : Int) : UInt64 := (Int.toNat (i % 18446744073709551616)).toUInt64

def le (b : ByteArray) (o n : Nat) : Nat :=
  (List.range n).foldl (fun a k => a + (b.get! (o + k)).toNat * 256 ^ k) 0

/-- Rows from the reference SQL feed: id u64, likes u64, then body/created/author as u32-length strings. -/
partial def feedRows (b : ByteArray) (o : Nat) (acc : Array (Int × ByteArray × ByteArray × ByteArray × Int)) :
    Array (Int × ByteArray × ByteArray × ByteArray × Int) :=
  if o + 16 > b.size then acc else
  let id := Int.ofNat (le b o 8)
  let likes := Int.ofNat (le b (o + 8) 8)
  let l1 := le b (o + 16) 4
  let body := b.extract (o + 20) (o + 20 + l1)
  let o2 := o + 20 + l1
  let l2 := le b o2 4
  let cr := b.extract (o2 + 4) (o2 + 4 + l2)
  let o3 := o2 + 4 + l2
  let l3 := le b o3 4
  let au := b.extract (o3 + 4) (o3 + 4 + l3)
  feedRows b (o3 + 4 + l3) (acc.push (id, body, cr, au, likes))

def cursors : Db.Cursors where
  begin := begin
  commit := commit
  seek := fun i id => do pure (st (← seek i.toUInt32 (u64 id)))
  seekGe := fun i k => do pure (st (← seekGe i.toUInt32 (u64 k)))
  first := fun i => do pure (st (← first i.toUInt32))
  next := fun i => do pure (st (← next i.toUInt32))
  payload := fun i => do
    let p ← payload i.toUInt32
    pure (if p.size == 0 then none else some (p.extract 1 p.size))
  countLikes := fun lo hi => do
    let r ← countLikesRaw Db.curLikes.toUInt32 (u64 lo) (u64 hi)
    if r.size == 0 then pure (-1, #[]) else
    let s := st (r.get! 0).toNat
    pure (s, (Array.range ((r.size - 1) / 4)).map fun i => le r (1 + 4 * i) 4)
  insertPost := fun uid body => do
    let r ← insertPostRaw (u64 uid) body
    if r.size < 9 then pure none else pure (some (Int.ofNat (le r 1 8), r.extract 9 r.size))
  insertLike := fun u p => do pure (st (← insertLikeRaw (u64 u) (u64 p)))
  health := do
    let e ← healthRaw
    pure (if e.isEmpty then .ok () else .error e)
  feedSql := do
    let r ← feedSqlRaw
    pure (if r.size == 0 then none else some (feedRows r 1 #[]).toList)

end FeedServer.Sqlite
