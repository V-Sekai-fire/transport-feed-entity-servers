/-! HTTP/1.1 request framing, ported from reference/src/http.rs.
Only the request line, Authorization and Content-Length are looked at. -/
namespace FeedServer.Http

structure Request where
  method : ByteArray
  path   : ByteArray
  auth   : Option ByteArray
  body   : ByteArray

inductive Parsed where
  | done (r : Request) (n : Nat)
  | incomplete
  | bad

def maxHead : Nat := 16 * 1024
def maxBody : Nat := 1024 * 1024

/-- First index `≥ i` holding byte `c`. -/
def findFrom (b : ByteArray) (c : UInt8) (i : Nat) : Option Nat :=
  if h : i < b.size then
    if b[i] == c then some i else findFrom b c (i + 1)
  else none
termination_by b.size - i

theorem findFrom_spec (b : ByteArray) (c : UInt8) (i r : Nat)
    (h : findFrom b c i = some r) : i ≤ r ∧ r < b.size := by
  unfold findFrom at h
  split at h
  · rename_i hi
    split at h
    · cases h; exact ⟨Nat.le_refl _, hi⟩
    · have := findFrom_spec b c (i+1) r h
      exact ⟨by omega, this.2⟩
  · cases h
termination_by b.size - i

def isWs (c : UInt8) : Bool := c == 32 || c == 9

/-- Strip spaces and tabs from both ends. -/
def trim (s : ByteArray) : ByteArray :=
  let rec lo (i : Nat) (fuel : Nat) : Nat :=
    match fuel with
    | 0 => i
    | f + 1 => if h : i < s.size then (if isWs s[i] then lo (i + 1) f else i) else i
  let rec hi (j : Nat) (st : Nat) (fuel : Nat) : Nat :=
    match fuel with
    | 0 => j
    | f + 1 => if st < j then (if h : j - 1 < s.size then (if isWs s[j - 1] then hi (j - 1) st f else j) else j) else j
  let a := lo 0 s.size
  let b := hi s.size a s.size
  s.extract a b

def lower (c : UInt8) : UInt8 := if 65 ≤ c && c ≤ 90 then c + 32 else c

/-- ASCII case-insensitive equality against an already-lowercase name. -/
def eqIgnoreCase (a lowerName : ByteArray) : Bool :=
  a.size == lowerName.size && (a.toList.map lower) == lowerName.toList

def startsWith (b w : ByteArray) : Bool := (b.extract 0 w.size).toList == w.toList

def stripCR (b : ByteArray) : ByteArray :=
  if b.size > 0 && b.get! (b.size - 1) == 13 then b.extract 0 (b.size - 1) else b

def allDigits (b : ByteArray) : Bool := b.toList.all (fun c => 48 ≤ c && c ≤ 57)

def digitsVal (b : ByteArray) : Nat :=
  b.toList.foldl (fun a c => a * 10 + (c.toNat - 48)) 0

inductive Head where
  | incomplete
  | bad
  | ok (auth : Option ByteArray) (len pos : Nat)

def authName : ByteArray := "authorization".toUTF8
def clName : ByteArray := "content-length".toUTF8
def teName : ByteArray := "transfer-encoding".toUTF8

/-- Header lines from `pos` to the empty line. `fuel` bounds the line count. -/
def headers (buf : ByteArray) : Nat → Nat → Option ByteArray → Nat → Head
  | 0, _, _, _ => .bad
  | f + 1, pos, auth, len =>
    match findFrom buf 10 pos with
    | none => .incomplete
    | some e =>
      let l := stripCR (buf.extract pos e)
      let pos' := e + 1
      if l.size == 0 then .ok auth len pos'
      else
        match findFrom l 58 0 with
        | none => headers buf f pos' auth len
        | some colon =>
          let name := l.extract 0 colon
          let value := trim (l.extract (colon + 1) l.size)
          if name.size == 13 && eqIgnoreCase name authName then headers buf f pos' (some value) len
          else if name.size == 14 && eqIgnoreCase name clName then
            if value.size == 0 || value.size > 9 || !allDigits value then .bad
            else
              let n := digitsVal value
              if n > maxBody then .bad else headers buf f pos' auth n
          else if name.size == 17 && eqIgnoreCase name teName then .bad
          else headers buf f pos' auth len

theorem headers_pos_le (buf : ByteArray) :
    ∀ (f pos : Nat) (auth : Option ByteArray) (len : Nat) (a : Option ByteArray) (l p : Nat),
      headers buf f pos auth len = Head.ok a l p → p ≤ buf.size := by
  intro f
  induction f with
  | zero => intro pos auth len a l p h; simp [headers] at h
  | succ f ih =>
    intro pos auth len a l p h
    simp only [headers] at h
    split at h
    · cases h
    · rename_i e he
      have hs := findFrom_spec buf 10 pos e he
      split at h
      · cases h; omega
      · split at h
        · exact ih _ _ _ _ _ _ h
        · split at h
          · exact ih _ _ _ _ _ _ h
          · split at h
            · split at h
              · cases h
              · split at h
                · cases h
                · exact ih _ _ _ _ _ _ h
            · split at h
              · cases h
              · exact ih _ _ _ _ _ _ h

def httpPrefix : ByteArray := "HTTP/1.".toUTF8

/-- Final step of `parse`: wait for the body, then hand back the request. -/
def finish (buf : ByteArray) (tooBig : Bool) (method path : ByteArray) : Head → Parsed
  | .incomplete => if tooBig then .bad else .incomplete
  | .bad => .bad
  | .ok auth len pos =>
    if buf.size < pos + len then .incomplete
    else .done { method, path, auth, body := buf.extract pos (pos + len) } (pos + len)

theorem finish_done_le (buf : ByteArray) (tb : Bool) (m p : ByteArray) (hd : Head)
    (r : Request) (n : Nat) (h : finish buf tb m p hd = .done r n) : n ≤ buf.size := by
  cases hd with
  | incomplete => cases tb <;> simp [finish] at h
  | bad => simp [finish] at h
  | ok a l q =>
    simp only [finish] at h
    split at h
    · cases h
    · injection h with _ h2; subst h2; omega

def pathOf (target : ByteArray) : ByteArray :=
  match findFrom target 63 0 with
  | some q => target.extract 0 q
  | none => target

/-- Request-line validation, then the header/body step. -/
def parseTail (buf : ByteArray) (method target afterTarget : ByteArray) (hd : Head) : Parsed :=
  if !(startsWith afterTarget httpPrefix) || method.size == 0 || target.size == 0 then .bad
  else finish buf (decide (buf.size > maxHead)) method (pathOf target) hd

theorem parseTail_done_le (buf m t a : ByteArray) (hd : Head) (r : Request) (n : Nat)
    (h : parseTail buf m t a hd = .done r n) : n ≤ buf.size := by
  unfold parseTail at h
  split at h
  · cases h
  · exact finish_done_le _ _ _ _ _ _ _ h

/-- Port of `http::parse`. -/
def parse (buf : ByteArray) : Parsed :=
  match findFrom buf 10 0 with
  | none => if buf.size > maxHead then .bad else .incomplete
  | some nl =>
    match findFrom (stripCR (buf.extract 0 nl)) 32 0 with
    | none => .bad
    | some sp1 =>
      match findFrom ((stripCR (buf.extract 0 nl)).extract (sp1 + 1) (stripCR (buf.extract 0 nl)).size) 32 0 with
      | none => .bad
      | some sp2 =>
        parseTail buf ((stripCR (buf.extract 0 nl)).extract 0 sp1)
          (((stripCR (buf.extract 0 nl)).extract (sp1 + 1) (stripCR (buf.extract 0 nl)).size).extract 0 sp2)
          (((stripCR (buf.extract 0 nl)).extract (sp1 + 1) (stripCR (buf.extract 0 nl)).size).extract (sp2 + 1) (((stripCR (buf.extract 0 nl)).extract (sp1 + 1) (stripCR (buf.extract 0 nl)).size).size))
          (headers buf buf.size (nl + 1) none 0)

theorem parse_done_le (buf : ByteArray) (r : Request) (n : Nat) :
    parse buf = .done r n → n ≤ buf.size := by
  intro h
  unfold parse at h
  repeat' split at h
  all_goals first
    | (exfalso; simp at h; done)
    | exact parseTail_done_le _ _ _ _ _ _ _ h

end FeedServer.Http
