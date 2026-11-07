import FeedServer.Json
import FeedServer.Sha256
/-! HS256 JWT verification, ported from datasources/reference/src/jwt.rs. -/
namespace FeedServer.Jwt

inductive AuthError | missing | invalid | payload

structure Claims where
  userId : Int
  username : ByteArray

def b64val (c : UInt8) : Option UInt32 :=
  if 65 ≤ c && c ≤ 90 then some (c - 65).toUInt32
  else if 97 ≤ c && c ≤ 122 then some (c - 97 + 26).toUInt32
  else if 48 ≤ c && c ≤ 57 then some (c - 48 + 52).toUInt32
  else if c == 45 then some 62 else if c == 95 then some 63 else none

/-- Unpadded base64url, canonical encodings only (unused low bits must be zero). -/
def b64urlDecode (s : ByteArray) : Option ByteArray := Id.run do
  if s.size % 4 == 1 then return none
  let mut out := ByteArray.empty
  let full := s.size / 4
  for i in [0:full] do
    let mut v : UInt32 := 0
    for j in [0:4] do
      match b64val (s.get! (4*i + j)) with
      | none => return none
      | some x => v := (v <<< 6) ||| x
    out := out.push (v >>> 16).toUInt8 |>.push (v >>> 8).toUInt8 |>.push v.toUInt8
  let r := s.size % 4
  if r != 0 then
    let mut v : UInt32 := 0
    for j in [0:r] do
      match b64val (s.get! (4*full + j)) with
      | none => return none
      | some x => v := v ||| (x <<< (18 - 6 * j.toUInt32))
    let unused := if r == 2 then v &&& 0xffff else v &&& 0xff
    if unused != 0 then return none
    out := out.push (v >>> 16).toUInt8
    if r == 3 then out := out.push (v >>> 8).toUInt8
  return some out

def b64urlEncode (b : ByteArray) : ByteArray := Id.run do
  let tbl := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toUTF8
  let mut out := ByteArray.empty
  let mut i := 0
  while i + 3 ≤ b.size do
    let v := (b.get! i).toUInt32 <<< 16 ||| (b.get! (i+1)).toUInt32 <<< 8 ||| (b.get! (i+2)).toUInt32
    for sh in [18, 12, 6, 0] do out := out.push (tbl.get! ((v >>> sh.toUInt32) &&& 63).toNat)
    i := i + 3
  let r := b.size - i
  if r == 1 then
    let v := (b.get! i).toUInt32 <<< 16
    for sh in [18, 12] do out := out.push (tbl.get! ((v >>> sh.toUInt32) &&& 63).toNat)
  else if r == 2 then
    let v := (b.get! i).toUInt32 <<< 16 ||| (b.get! (i+1)).toUInt32 <<< 8
    for sh in [18, 12, 6] do out := out.push (tbl.get! ((v >>> sh.toUInt32) &&& 63).toNat)
  return out

/-- Positive decimal, no sign/spaces/leading zeros, ≤ 18 digits. -/
def parsePositive (s : ByteArray) : Option Int :=
  if s.size == 0 || s.size > 18 || s.get! 0 == 48 || !s.toList.all (fun c => 48 ≤ c && c ≤ 57) then none
  else some (Int.ofNat (s.toList.foldl (fun a c => a * 10 + (c.toNat - 48)) 0))

def strOf : Json.Val → Option ByteArray
  | .str r e => some (if e then Json.unescape r else r)
  | _ => none

def lastMember (ms : List Json.Member) (key : String) : Option Json.Val :=
  ms.foldl (fun acc m => if m.key == key.toUTF8 then some m.val else acc) none

def splitDots (b : ByteArray) : List ByteArray :=
  let rec go (cur : Array UInt8) (acc : List ByteArray) : List UInt8 → List ByteArray
    | [] => (acc ++ [⟨cur⟩])
    | c :: cs => if c == 46 then go #[] (acc ++ [⟨cur⟩]) cs else go (cur.push c) acc cs
  go #[] [] b.toList

def ctEq (a b : ByteArray) : Bool :=
  a.size == b.size && (a.toList.zip b.toList).foldl (fun d (x, y) => d ||| (x ^^^ y)) 0 == 0

/-- `header` is the Authorization value; `now` Unix seconds. -/
def verify (secret : ByteArray) (header : Option ByteArray) (now : Float) : Except AuthError Claims := do
  let token ← match header with
    | some h => if h.size ≥ 7 && h.extract 0 7 == "Bearer ".toUTF8 then pure (h.extract 7 h.size) else throw .missing
    | none => throw .missing
  let (h, p, s) ← match splitDots token with
    | [h, p, s] => pure (h, p, s)
    | _ => throw .invalid
  let sig ← match b64urlDecode s with | some x => pure x | none => throw .invalid
  if sig.size != 32 then throw .invalid
  let signed := token.extract 0 (h.size + 1 + p.size)
  if !ctEq (Sha256.hmac secret signed) sig then throw .invalid
  let hdr ← match b64urlDecode h with | some x => pure x | none => throw .invalid
  let (isObj, hm) ← match Json.parseObject hdr with | some r => pure r | none => throw .invalid
  let algOk := match lastMember hm "alg" >>= strOf with | some a => a == "HS256".toUTF8 | none => false
  if !isObj || !algOk then throw .invalid
  let pay ← match b64urlDecode p with | some x => pure x | none => throw .invalid
  let (isObj2, pm) ← match Json.parseObject pay with | some r => pure r | none => throw .invalid
  if !isObj2 then throw .invalid
  let exp := match lastMember pm "exp" with | some (.num n) => some n | _ => none
  match exp with
  | some e => if now < e then pure () else throw .invalid
  | none => throw .invalid
  let uid ← match lastMember pm "sub" >>= strOf with
    | some t => match parsePositive t with | some u => pure u | none => throw .payload
    | none => throw .payload
  let name ← match lastMember pm "username" >>= strOf with | some n => pure n | none => throw .payload
  return ⟨uid, name⟩

end FeedServer.Jwt
