/-! JSON reader and writer, ported from datasources/reference/src/json.rs. -/
namespace FeedServer.Json

def _root_.ByteArray.get? (b : ByteArray) (i : Nat) : Option UInt8 :=
  if h : i < b.size then some b[i] else none

inductive Val where
  | str (raw : ByteArray) (esc : Bool)
  | num (n : Float)
  | other

structure Member where
  key : ByteArray
  val : Val

def maxDepth : Nat := 64

def isWsB (c : UInt8) : Bool := c == 32 || c == 10 || c == 13 || c == 9

def skipWs (s : ByteArray) (i : Nat) : Nat → Nat
  | 0 => i
  | f + 1 => if h : i < s.size then (if isWsB s[i] then skipWs s (i + 1) f else i) else i

def isHex (c : UInt8) : Bool := (48 ≤ c && c ≤ 57) || (65 ≤ c && c ≤ 70) || (97 ≤ c && c ≤ 102)

def hexVal (c : UInt8) : Nat :=
  if 48 ≤ c && c ≤ 57 then c.toNat - 48
  else if 97 ≤ c && c ≤ 102 then c.toNat - 87
  else if 65 ≤ c && c ≤ 70 then c.toNat - 55 else 0

/-- After the opening quote at `i`. Returns raw contents, escape flag, index after the closing quote. -/
def scanString (s : ByteArray) (start : Nat) : Nat → Nat → Bool → Option (ByteArray × Bool × Nat)
  | 0, _, _ => none
  | f + 1, i, esc =>
    if h : i < s.size then
      let c := s[i]
      if c == 34 then some (s.extract start i, esc, i + 1)
      else if c == 92 then
        if h2 : i + 1 < s.size then
          let e := s[i + 1]
          if e == 34 || e == 92 || e == 47 || e == 98 || e == 102 || e == 110 || e == 114 || e == 116 then
            scanString s start f (i + 2) true
          else if e == 117 then
            if i + 6 ≤ s.size && isHex (s.get! (i+2)) && isHex (s.get! (i+3)) && isHex (s.get! (i+4)) && isHex (s.get! (i+5))
            then scanString s start f (i + 6) true else none
          else none
        else none
      else if c < 0x20 then none
      else scanString s start f (i + 1) esc
    else none

def isDigit (c : UInt8) : Bool := 48 ≤ c && c ≤ 57

def digitsEnd (s : ByteArray) (i : Nat) : Nat → Nat
  | 0 => i
  | f + 1 => if h : i < s.size then (if isDigit s[i] then digitsEnd s (i + 1) f else i) else i

def natOf (s : ByteArray) (a b : Nat) : Nat :=
  (s.extract a b).toList.foldl (fun acc c => acc * 10 + (c.toNat - 48)) 0

/-- JSON number grammar; value as a Float. -/
def scanNumber (s : ByteArray) (i0 : Nat) : Option (Float × Nat) :=
  let neg := s.get? i0 == some 45
  let i1 := if neg then i0 + 1 else i0
  match s.get? i1 with
  | some 48 => fin i1 (i1 + 1) neg
  | some c => if 49 ≤ c && c ≤ 57 then fin i1 (digitsEnd s i1 s.size) neg else none
  | none => none
where
  fin (intStart intEnd : Nat) (neg : Bool) : Option (Float × Nat) :=
    let ip := natOf s intStart intEnd
    -- fraction
    let frac : Option (Nat × Nat × Nat) :=  -- (digits as Nat, count, end)
      if s.get? intEnd == some 46 then
        let e := digitsEnd s (intEnd + 1) s.size
        if e == intEnd + 1 then none else some (natOf s (intEnd + 1) e, e - intEnd - 1, e)
      else some (0, 0, intEnd)
    match frac with
    | none => none
    | some (fd, fc, fe) =>
      let ex : Option (Int × Nat) :=
        if s.get? fe == some 101 || s.get? fe == some 69 then
          let j := fe + 1
          let sg := s.get? j
          let j' := if sg == some 43 || sg == some 45 then j + 1 else j
          let e := digitsEnd s j' s.size
          if e == j' then none
          else
            let v : Int := Int.ofNat (natOf s j' e)
            some (if sg == some 45 then -v else v, e)
        else some (0, fe)
      match ex with
      | none => none
      | some (ev, ee) =>
        let mant : Nat := ip * 10 ^ fc + fd
        let e10 : Int := ev - Int.ofNat fc
        let f :=
          if e10 ≥ 0 then Float.ofScientific mant false e10.toNat
          else Float.ofScientific mant true (-e10).toNat
        some (if neg then -f else f, ee)

def lit (s : ByteArray) (i : Nat) (w : String) : Bool :=
  let wb := w.toUTF8
  i + wb.size ≤ s.size && (s.extract i (i + wb.size)).toList == wb.toList

/-- UTF-8 encode a code point; invalid scalars become U+FFFD. -/
def encodeCp (u : Nat) : List UInt8 :=
  let u := if (0xD800 ≤ u && u < 0xE000) || u ≥ 0x110000 then 0xFFFD else u
  if u < 0x80 then [u.toUInt8]
  else if u < 0x800 then [(0xC0 ||| (u >>> 6)).toUInt8, (0x80 ||| (u &&& 0x3F)).toUInt8]
  else if u < 0x10000 then [(0xE0 ||| (u >>> 12)).toUInt8, (0x80 ||| ((u >>> 6) &&& 0x3F)).toUInt8, (0x80 ||| (u &&& 0x3F)).toUInt8]
  else [(0xF0 ||| (u >>> 18)).toUInt8, (0x80 ||| ((u >>> 12) &&& 0x3F)).toUInt8, (0x80 ||| ((u >>> 6) &&& 0x3F)).toUInt8, (0x80 ||| (u &&& 0x3F)).toUInt8]

def hex4 (r : ByteArray) (i : Nat) : Nat :=
  (List.range 4).foldl (fun a k => a * 16 + hexVal (r.get! (i + k))) 0

/-- Decode a validated string's raw contents. Lone surrogates become U+FFFD. -/
def unescapeAux (r : ByteArray) (acc : Array UInt8) : Nat → Nat → Array UInt8
  | 0, _ => acc
  | f + 1, i =>
    if i < r.size then
      let c := r.get! i
      if c != 92 then unescapeAux r (acc.push c) f (i + 1)
      else
        let e := r.get! (i + 1)
        if e == 117 then
          let u := hex4 r (i + 2)
          if 0xD800 ≤ u && u < 0xDC00 && r.size ≥ i + 12 && r.get! (i + 6) == 92 && r.get! (i + 7) == 117 then
            let lo := hex4 r (i + 8)
            if 0xDC00 ≤ lo && lo < 0xE000 then
              unescapeAux r (acc ++ (encodeCp (0x10000 + ((u - 0xD800) <<< 10) + (lo - 0xDC00))).toArray) f (i + 12)
            else unescapeAux r (acc ++ (encodeCp u).toArray) f (i + 6)
          else unescapeAux r (acc ++ (encodeCp u).toArray) f (i + 6)
        else
          let ch : Nat := if e == 98 then 8 else if e == 102 then 12 else if e == 110 then 10
            else if e == 114 then 13 else if e == 116 then 9 else e.toNat
          unescapeAux r (acc ++ (encodeCp ch).toArray) f (i + 2)
    else acc

def unescape (r : ByteArray) : ByteArray := ⟨unescapeAux r #[] r.size 0⟩

mutual
  def value (s : ByteArray) : Nat → Nat → Nat → Option (Val × Nat)
    | 0, _, _ => none
    | f + 1, depth, i0 =>
      if depth > maxDepth then none else
      let i := skipWs s i0 s.size
      match s.get? i with
      | none => none
      | some 34 => (scanString s (i + 1) s.size (i + 1) false).map fun (r, e, j) => (Val.str r e, j)
      | some 123 => (object s f depth i).map fun (_, j) => (Val.other, j)
      | some 91 =>
        let j := skipWs s (i + 1) s.size
        if s.get? j == some 93 then some (Val.other, j + 1)
        else (items s f depth j).map fun j' => (Val.other, j')
      | some 116 => if lit s i "true" then some (Val.other, i + 4) else none
      | some 102 => if lit s i "false" then some (Val.other, i + 5) else none
      | some 110 => if lit s i "null" then some (Val.other, i + 4) else none
      | some _ => (scanNumber s i).map fun (n, j) => (Val.num n, j)

  def items (s : ByteArray) : Nat → Nat → Nat → Option Nat
    | 0, _, _ => none
    | f + 1, depth, i =>
      match value s f (depth + 1) i with
      | none => none
      | some (_, j) =>
        let k := skipWs s j s.size
        match s.get? k with
        | some 44 => items s f depth (k + 1)
        | some 93 => some (k + 1)
        | _ => none

  /-- `i` is at '{'. Members in source order. -/
  def object (s : ByteArray) : Nat → Nat → Nat → Option (List Member × Nat)
    | 0, _, _ => none
    | f + 1, depth, i =>
      let j := skipWs s (i + 1) s.size
      if s.get? j == some 125 then some ([], j + 1)
      else members s f depth j
  
  def members (s : ByteArray) : Nat → Nat → Nat → Option (List Member × Nat)
    | 0, _, _ => none
    | f + 1, depth, i0 =>
      let i := skipWs s i0 s.size
      if s.get? i != some 34 then none else
      match scanString s (i + 1) s.size (i + 1) false with
      | none => none
      | some (k, kesc, j) =>
        let j := skipWs s j s.size
        if s.get? j != some 58 then none else
        match value s f (depth + 1) (j + 1) with
        | none => none
        | some (v, j2) =>
          let k' := if kesc then unescape k else k
          let j3 := skipWs s j2 s.size
          match s.get? j3 with
          | some 44 => (members s f depth (j3 + 1)).map fun (ms, e) => (⟨k', v⟩ :: ms, e)
          | some 125 => some ([⟨k', v⟩], j3 + 1)
          | _ => none
end

/-- Top-level parse: `none` if malformed, `some (isObject, members)` otherwise. Port of `parse_object`. -/
def parseObject (s : ByteArray) : Option (Bool × List Member) :=
  if (String.fromUTF8? s).isNone then none else
  let i := skipWs s 0 s.size
  let isObj := s.get? i == some 123
  let res : Option (List Member × Nat) :=
    if isObj then object s s.size 0 i
    else (value s s.size 0 i).map fun (_, j) => ([], j)
  match res with
  | none => none
  | some (ms, j) => if skipWs s j s.size == s.size then some (isObj, ms) else none

/-- Bytes that must be escaped in output: control chars, quote, backslash. -/
def needsEscape (c : UInt8) : Bool := c < 0x20 || c == 34 || c == 92

def hexDigit (n : Nat) : UInt8 := if n < 10 then (48 + n).toUInt8 else (87 + n).toUInt8

def escByte (c : UInt8) : List UInt8 :=
  if !needsEscape c then [c]
  else if c == 34 then [92, 34]
  else if c == 92 then [92, 92]
  else if c == 10 then [92, 110]
  else if c == 13 then [92, 114]
  else if c == 9 then [92, 116]
  else if c == 8 then [92, 98]
  else if c == 12 then [92, 102]
  else [92, 117, 48, 48, hexDigit (c.toNat / 16), hexDigit (c.toNat % 16)]

/-- Port of `escape_into`: JSON string body, non-ASCII passes through. -/
def escape (s : ByteArray) : ByteArray := ⟨(s.toList.flatMap escByte).toArray⟩

theorem escByte_clean (c : UInt8) (h : needsEscape c = false) : escByte c = [c] := by
  simp [escByte, h]

/-- Port of `push_int`. -/
def intBytes (v : Int) : ByteArray := (toString v).toUTF8

end FeedServer.Json
