import FeedServer.Http
import FeedServer.Json
import FeedServer.Jwt
/-! Routing and handlers, ported from reference/src/app.rs.
Storage is abstract (`Store`): SQLite is bound over FFI elsewhere, never rewritten here. -/
namespace FeedServer.App
open Http

structure Store where
  feed        : IO (Except String ByteArray)
  post        : Int → IO (Except String (Option ByteArray))
  health      : IO (Except String Unit)
  insertPost  : Int → ByteArray → IO (Except String (Int × ByteArray))
  postExists  : Int → IO (Except String Bool)
  insertLike  : Int → Int → IO (Except String Bool)
  /-- COMMIT the batch's transaction; false if it was rolled back. -/
  commit      : IO Bool

structure Env where
  store    : Store
  /-- Set when the batch wrote: its responses must wait for COMMIT. -/
  wrote    : IO.Ref Bool
  secret   : ByteArray
  nowSecs  : IO Float
  uptimeS  : IO Nat

def maxBodyChars : Nat := 500

def reason : Nat → String
  | 200 => "200 OK" | 201 => "201 Created" | 400 => "400 Bad Request"
  | 401 => "401 Unauthorized" | 404 => "404 Not Found"
  | 503 => "503 Service Unavailable" | _ => "500 Internal Server Error"

def header (status : Nat) (bodyLen : Nat) : ByteArray :=
  s!"HTTP/1.1 {reason status}\r\nContent-Type: application/json\r\nContent-Length: {bodyLen}\r\n\r\n".toUTF8

/-- One complete response. Replaces the Rust `start`/`finish` 4-digit slot fix-up. -/
def response (status : Nat) (body : ByteArray) : ByteArray := header status body.size ++ body

theorem response_size (s : Nat) (b : ByteArray) : (response s b).size = (header s b.size).size + b.size := by
  simp [response, ByteArray.size_append]

/-- The bytes after the header are exactly the body, and the header names their length. -/
theorem response_body (s : Nat) (b : ByteArray) :
    (response s b).extract (header s b.size).size ((header s b.size).size + b.size) = b :=
  ByteArray.extract_append_eq_right rfl rfl

def errorResp (status : Nat) (msg : String) : ByteArray :=
  response status s!"\{\"error\":\"{msg}\"}".toUTF8

/-- JavaScript `String.prototype.trim` whitespace: Unicode White_Space without NEL, plus BOM. -/
def isJsSpace (c : Char) : Bool :=
  let n := c.toNat
  (9 ≤ n && n ≤ 13) || n == 32 || n == 0xA0 || n == 0x1680 || (0x2000 ≤ n && n ≤ 0x200A)
    || n == 0x2028 || n == 0x2029 || n == 0x202F || n == 0x205F || n == 0x3000 || n == 0xFEFF

def jsTrim (s : String) : String :=
  String.ofList ((s.toList.dropWhile isJsSpace).reverse.dropWhile isJsSpace).reverse

def postId (s : ByteArray) : Option Int := Jwt.parsePositive s

def strip (b pre : ByteArray) : Option ByteArray :=
  if b.size ≥ pre.size && b.extract 0 pre.size == pre then some (b.extract pre.size b.size) else none

def stripSuffix (b suf : ByteArray) : Option ByteArray :=
  if b.size ≥ suf.size && b.extract (b.size - suf.size) b.size == suf then some (b.extract 0 (b.size - suf.size)) else none

def noSlash (b : ByteArray) : Bool := !b.toList.contains 47

def esc (b : ByteArray) : ByteArray := Json.escape b
def lit (s : String) : ByteArray := s.toUTF8

def auth (env : Env) (req : Request) : IO (Except ByteArray (Int × ByteArray)) := do
  let now ← env.nowSecs
  match Jwt.verify env.secret req.auth now with
  | .ok c => pure (.ok (c.userId, c.username))
  | .error .missing => pure (.error (errorResp 401 "missing bearer token"))
  | .error .invalid => pure (.error (errorResp 401 "invalid or expired token"))
  | .error .payload => pure (.error (errorResp 401 "invalid token payload"))

def internal : ByteArray := errorResp 500 "internal server error"

def health (env : Env) : IO ByteArray := do
  match ← env.store.health with
  | .ok () =>
    let up ← env.uptimeS
    pure (response 200 (lit s!"\{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":{up}}"))
  | .error e =>
    pure (response 503 (lit "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"" ++ esc e.toUTF8 ++ lit "\"}"))

def create (env : Env) (req : Request) : IO ByteArray := do
  match ← auth env req with
  | .error r => pure r
  | .ok (uid, username) =>
    match Json.parseObject req.body with
    | none => pure (errorResp 400 "malformed JSON body")
    | some (false, _) => pure (errorResp 400 "body is required")
    | some (true, ms) =>
      match Jwt.lastMember ms "body" with
      | some (.str raw e) =>
        let text := if e then Json.unescape raw else raw
        let s := jsTrim ((String.fromUTF8? text).getD "")
        if s.isEmpty then pure (errorResp 400 "body is required")
        else if s.length > maxBodyChars then pure (errorResp 400 "body must be at most 500 characters")
        else
          match ← env.store.insertPost uid s.toUTF8 with
          | .error _ => pure internal
          | .ok (id, created) =>
            env.wrote.set true
            pure (response 201 (lit s!"\{\"post\":\{\"id\":{id},\"body\":\"" ++ esc s.toUTF8
              ++ lit "\",\"created_at\":\"" ++ esc created ++ lit "\",\"author\":\"" ++ esc username
              ++ lit "\",\"like_count\":0}}"))
      | _ => pure (errorResp 400 "body is required")

def like (env : Env) (req : Request) (idBytes : ByteArray) : IO ByteArray := do
  match ← auth env req with
  | .error r => pure r
  | .ok (uid, _) =>
    match postId idBytes with
    | none => pure (errorResp 400 "invalid post id")
    | some id =>
      match ← env.store.postExists id with
      | .error _ => pure internal
      | .ok false => pure (errorResp 404 "post not found")
      | .ok true =>
        match ← env.store.insertLike uid id with
        | .error _ => pure internal
        | .ok isNew =>
          if isNew then env.wrote.set true
          pure (response (if isNew then 201 else 200)
            (lit s!"\{\"liked\":true,\"already_liked\":{!isNew},\"post_id\":{id}}"))

/-- Handles one request; returns the complete response bytes. -/
def handle (env : Env) (req : Request) : IO ByteArray := do
  let p := req.path
  if req.method == lit "GET" then
    if p == lit "/feed" then
      match ← env.store.feed with
      | .ok body => pure (response 200 body)
      | .error _ => pure internal
    else if let some idb := (strip p (lit "/posts/")).filter noSlash then
      match postId idb with
      | none => pure (errorResp 400 "invalid post id")
      | some id =>
        match ← env.store.post id with
        | .ok (some body) => pure (response 200 body)
        | .ok none => pure (errorResp 404 "post not found")
        | .error _ => pure internal
    else if p == lit "/health" then health env
    else pure (errorResp 404 "not found")
  else if req.method == lit "POST" then
    if p == lit "/posts" then create env req
    else if let some idb := ((strip p (lit "/posts/")).bind (stripSuffix · (lit "/like"))).filter noSlash then
      like env req idb
    else pure (errorResp 404 "not found")
  else pure (errorResp 404 "not found")

/-- End of a batch: COMMIT, then clear `wrote`. Returns whether the commit held.
When it is false, every response of the batch that answered must be replaced by a 500
(`rolledBack`), so no client sees a success for a write that did not land. -/
def endBatch (env : Env) : IO Bool := do
  let ok ← env.store.commit
  env.wrote.set false
  pure ok

def rolledBack : ByteArray := internal

end FeedServer.App
