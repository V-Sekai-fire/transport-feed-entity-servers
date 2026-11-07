/-! SQLite record decoding, ported from reference/src/db.rs
(`varint`, `varint_long`, `serial_len`, `int_of`, `columns`, `text`). Pure, over `ByteArray`. -/
namespace FeedServer.Record

/-- SQLite varint: up to 8 bytes of 7 bits (high bit = continue); a 9th byte contributes all 8 bits.
Returns the value and the index after it. `fuel` counts bytes still allowed. -/
def varintAux (p : ByteArray) (i k : Nat) (v : UInt64) : Nat → Option (UInt64 × Nat)
  | 0 => none
  | f + 1 =>
    if h : i < p.size then
      if k == 8 then some ((v <<< 8) ||| p[i].toUInt64, i + 1)
      else if p[i] &&& 0x80 == 0 then some ((v <<< 7) ||| (p[i] &&& 0x7f).toUInt64, i + 1)
      else varintAux p (i + 1) (k + 1) ((v <<< 7) ||| (p[i] &&& 0x7f).toUInt64) f
    else none

def varint (p : ByteArray) (i : Nat) : Option (UInt64 × Nat) := varintAux p i 0 0 9

theorem varintAux_spec (p : ByteArray) :
    ∀ (f i k : Nat) (v v' : UInt64) (j : Nat),
      varintAux p i k v f = some (v', j) → i < j ∧ j ≤ p.size ∧ j ≤ i + f := by
  intro f
  induction f with
  | zero => intro i k v v' j h; simp [varintAux] at h
  | succ f ih =>
    intro i k v v' j h
    unfold varintAux at h
    split at h
    · rename_i hi
      split at h
      · injection h with h1; injection h1 with _ h2; omega
      · split at h
        · injection h with h1; injection h1 with _ h2; omega
        · have := ih _ _ _ _ _ h
          omega
    · cases h

theorem varint_spec (p : ByteArray) (i : Nat) (v : UInt64) (j : Nat)
    (h : varint p i = some (v, j)) : i < j ∧ j ≤ p.size ∧ j ≤ i + 9 :=
  varintAux_spec p 9 i 0 0 v j h

/-- Body length of a serial type (db.rs `serial_len`). -/
def serialLen (t : UInt64) : Nat :=
  if t == 0 || t == 8 || t == 9 || t == 10 || t == 11 then 0
  else if t == 1 then 1 else if t == 2 then 2 else if t == 3 then 3
  else if t == 4 then 4 else if t == 5 then 6 else if t == 6 || t == 7 then 8
  else ((t - 12) / 2).toNat

/-- Column as an integer (serial types 1–6, 8, 9); two's complement big-endian. -/
def intOf (t : UInt64) (b : ByteArray) : Option Int :=
  if t == 8 then some 0
  else if t == 9 then some 1
  else if 1 ≤ t && t ≤ 6 then
    let n := serialLen t
    if b.size < n then none
    else
      let u : Nat := (b.extract 0 n).toList.foldl (fun a c => a * 256 + c.toNat) 0
      some (if u ≥ 2 ^ (8 * n - 1) then Int.ofNat u - Int.ofNat (2 ^ (8 * n)) else Int.ofNat u)
  else none

/-- Record header walk: serial types from `hdr` at `i`, bodies from `rec` at `body`. -/
def colsAux (rec hdr : ByteArray) (i body : Nat) : Nat → Option (List (UInt64 × ByteArray))
  | 0 => some []
  | k + 1 =>
    if i ≥ hdr.size then none
    else
      match varint hdr i with
      | none => none
      | some (t, i') =>
        if body + serialLen t ≤ rec.size then
          (colsAux rec hdr i' (body + serialLen t) k).map ((t, rec.extract body (body + serialLen t)) :: ·)
        else none

/-- The first `n` columns of a record: (serial type, bytes). -/
def columns (rec : ByteArray) (n : Nat) : Option (List (UInt64 × ByteArray)) :=
  match varint rec 0 with
  | none => none
  | some (h, i) =>
    if h.toNat > rec.size then none
    else colsAux rec (rec.extract 0 h.toNat) i h.toNat n

theorem colsAux_spec (rec hdr : ByteArray) :
    ∀ (k i body : Nat) (cs : List (UInt64 × ByteArray)),
      colsAux rec hdr i body k = some cs →
        cs.length = k ∧ ∀ c ∈ cs, c.2.size = serialLen c.1 := by
  intro k
  induction k with
  | zero => intro i body cs h; simp [colsAux] at h; subst h; simp
  | succ k ih =>
    intro i body cs h
    unfold colsAux at h
    split at h
    · cases h
    · split at h
      · cases h
      · rename_i t i' _
        split at h
        · rename_i hb
          cases hr : colsAux rec hdr i' (body + serialLen t) k with
          | none => simp [hr] at h
          | some rest =>
            simp [hr] at h
            subst h
            have := ih _ _ _ hr
            refine ⟨by simp [this.1], ?_⟩
            intro c hc
            simp at hc
            rcases hc with rfl | hc
            · simp [ByteArray.size_extract]; omega
            · exact this.2 c hc
        · cases h

theorem columns_spec (rec : ByteArray) (n : Nat) (cs : List (UInt64 × ByteArray))
    (h : columns rec n = some cs) :
    cs.length = n ∧ ∀ c ∈ cs, c.2.size = serialLen c.1 := by
  unfold columns at h
  split at h
  · cases h
  · split at h
    · cases h
    · exact colsAux_spec _ _ _ _ _ _ h

/-- Text column: serial type ≥ 13 and odd. -/
def text (c : UInt64 × ByteArray) : Option ByteArray :=
  if c.1 ≥ 13 && c.1 &&& 1 == 1 then some c.2 else none

end FeedServer.Record
