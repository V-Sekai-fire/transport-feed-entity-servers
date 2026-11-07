import FeedServer.All
import Fake
open FeedServer

def b (s : String) : ByteArray := s.toUTF8
def check (name : String) (ok : Bool) : IO Bool := do
  IO.println s!"{if ok then "ok  " else "FAIL"} {name}"; pure ok

def showP : Http.Parsed → String
  | .done r n => s!"done {String.fromUTF8! r.method} {String.fromUTF8! r.path} auth={match r.auth with | some a => "some " ++ String.fromUTF8! a | none => "none"} body={String.fromUTF8! r.body} n={n}"
  | .incomplete => "incomplete" | .bad => "bad"

def main : IO UInt32 := do
  let mut results : Array Bool := #[]
  let req1 := "GET /feed?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization:  Bearer t \r\n\r\n"
  let r1 := Http.parse (b req1)
  results := results.push (← check "GET with query + auth" (showP r1 == "done GET /feed auth=some Bearer t body= n=" ++ toString req1.utf8ByteSize))
  IO.println (showP r1)
  let r2 := Http.parse (b "POST /posts HTTP/1.1\r\nContent-Length: 5\r\n\r\nab")
  results := results.push (← check "partial body" (showP r2 == "incomplete"))
  let r3 := Http.parse (b "POST /posts HTTP/1.1\r\ncontent-length: 2\r\n\r\nabEXTRA")
  results := results.push (← check "body + pipelined rest" (showP r3 == "done POST /posts auth=none body=ab n=" ++ toString ("POST /posts HTTP/1.1\r\ncontent-length: 2\r\n\r\nab".length)))
  results := results.push (← check "chunked rejected" (showP (Http.parse (b "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) == "bad"))
  results := results.push (← check "bad version" (showP (Http.parse (b "GET / FTP/1.1\r\n\r\n")) == "bad"))
  results := results.push (← check "no newline yet" (showP (Http.parse (b "GET /fe")) == "incomplete"))
  results := results.push (← check "bad content-length" (showP (Http.parse (b "POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\n")) == "bad"))
  -- JSON
  let jo := Json.parseObject (b "{\"body\":\"hi\\nthere\",\"n\":1.5e2,\"x\":[1,{\"a\":null}],\"body\":\"last\"}")
  match jo with
  | none => results := results.push (← check "json object parses" false)
  | some (isObj, ms) =>
    results := results.push (← check "json object parses" (isObj && ms.length == 4))
    let lastBody := ms.foldl (fun acc m => if m.key == b "body" then some m.val else acc) none
    results := results.push (← check "last duplicate wins" (match lastBody with | some (Json.Val.str r _) => r == b "last" | _ => false))
    let n := ms.foldl (fun acc m => if m.key == b "n" then (match m.val with | Json.Val.num f => some f | _ => acc) else acc) none
    results := results.push (← check "number 1.5e2 = 150" (n == some 150.0))
  results := results.push (← check "trailing garbage rejected" (Json.parseObject (b "{} x")).isNone)
  results := results.push (← check "bad escape rejected" (Json.parseObject (b "{\"a\":\"\\q\"}")).isNone)
  results := results.push (← check "leading zero rejected" (Json.parseObject (b "{\"a\":01}")).isNone)
  results := results.push (← check "non-object ok" (match Json.parseObject (b "[1,2]") with | some (false, _) => true | _ => false))
  results := results.push (← check "unescape \\u00e9 + surrogate pair" (Json.unescape (b "\\u00e9\\ud83d\\ude00") == b "é😀"))
  results := results.push (← check "lone surrogate -> U+FFFD" (Json.unescape (b "\\ud800x") == b "\uFFFDx"))
  results := results.push (← check "escape" (Json.escape (ByteArray.mk #[34, 92, 10, 1, 65]) == b "\\\"\\\\\\n\\u0001A"))
  results := results.push (← check "intBytes" (Json.intBytes (-42) == b "-42"))
  -- SHA-256 / HMAC / base64url vectors
  results := results.push (← check "sha256 abc" (Sha256.hex (Sha256.hash (b "abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
  results := results.push (← check "sha256 empty" (Sha256.hex (Sha256.hash (b "")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
  results := results.push (← check "sha256 448-bit" (Sha256.hex (Sha256.hash (b "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))
  results := results.push (← check "hmac rfc4231 case2" (Sha256.hex (Sha256.hmac (b "Jefe") (b "what do ya want for nothing?")) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
  results := results.push (← check "b64url encode" (Jwt.b64urlEncode (b "foobar") == b "Zm9vYmFy" && Jwt.b64urlEncode (b "fo") == b "Zm8"))
  results := results.push (← check "b64url roundtrip" ((List.range 20).all fun n => let x := ByteArray.mk ((Array.range n).map (·.toUInt8 * 37)); Jwt.b64urlDecode (Jwt.b64urlEncode x) == some x))
  results := results.push (← check "b64url non-canonical rejected" (Jwt.b64urlDecode (b "Zm9") |>.isNone))
  -- App handlers against a fake store
  let likes ← IO.mkRef (#[] : Array (Int × Int))
  let store : App.Store := {
    feed := pure (.ok (b "{\"posts\":[]}"))
    post := fun id => pure (.ok (if id == 7 then some (b "{\"post\":{\"id\":7}}") else none))
    health := pure (.ok ())
    insertPost := fun _ _ => pure (.ok (42, b "2026-01-01T00:00:00.000Z"))
    postExists := fun id => pure (.ok (id == 7))
    insertLike := fun u p => do
      let ls ← likes.get
      if ls.contains (u, p) then pure (.ok false) else do likes.set (ls.push (u, p)); pure (.ok true)
    commit := pure true }
  let secret := b "twelve-dollar-challenge"
  let mk := fun (payload : String) =>
    let h := Jwt.b64urlEncode (b "{\"alg\":\"HS256\",\"typ\":\"JWT\"}")
    let p := Jwt.b64urlEncode (b payload)
    let signed := h ++ b "." ++ p
    String.fromUTF8! (signed ++ b "." ++ Jwt.b64urlEncode (Sha256.hmac secret signed))
  let tok := mk "{\"sub\":\"3\",\"username\":\"ann\",\"exp\":4102444800}"
  let expired := mk "{\"sub\":\"3\",\"username\":\"ann\",\"exp\":1}"
  let wrote ← IO.mkRef false
  let env : App.Env := { store, wrote, secret, nowSecs := pure 1.8e9, uptimeS := pure 5 }
  let run := fun (raw : String) => do
    match Http.parse (b raw) with
    | .done r _ => pure (String.fromUTF8! (← App.handle env r))
    | _ => pure "PARSE-FAIL"
  let has := fun (s sub : String) => (s.splitOn sub).length > 1
  let r ← run "GET /health HTTP/1.1\r\n\r\n"
  results := results.push (← check "health 200 + body" (has r "200 OK" && has r "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":5}" && has r "Content-Length: 38"))
  results := results.push (← check "feed" (has (← run "GET /feed HTTP/1.1\r\n\r\n") "{\"posts\":[]}"))
  results := results.push (← check "post 404" (has (← run "GET /posts/8 HTTP/1.1\r\n\r\n") "404 Not Found"))
  results := results.push (← check "post bad id" (has (← run "GET /posts/07 HTTP/1.1\r\n\r\n") "400 Bad Request"))
  results := results.push (← check "unknown route" (has (← run "GET /nope HTTP/1.1\r\n\r\n") "{\"error\":\"not found\"}"))
  results := results.push (← check "create no auth" (has (← run "POST /posts HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}") "missing bearer token"))
  results := results.push (← check "create expired" (has (← run s!"POST /posts HTTP/1.1\r\nAuthorization: Bearer {expired}\r\nContent-Length: 2\r\n\r\n\{}") "invalid or expired token"))
  let body := "{\"body\":\"  hi \\\"x\\\" \"}"
  let c ← run s!"POST /posts HTTP/1.1\r\nAuthorization: Bearer {tok}\r\nContent-Length: {body.utf8ByteSize}\r\n\r\n{body}"
  results := results.push (← check "create 201" (has c "201 Created" && has c "\"body\":\"hi \\\"x\\\"\",\"created_at\":\"2026-01-01T00:00:00.000Z\",\"author\":\"ann\",\"like_count\":0}}"))
  let e := "{\"body\":\"   \"}"
  results := results.push (← check "create blank" (has (← run s!"POST /posts HTTP/1.1\r\nAuthorization: Bearer {tok}\r\nContent-Length: {e.utf8ByteSize}\r\n\r\n{e}") "body is required"))
  let l1 ← run s!"POST /posts/7/like HTTP/1.1\r\nAuthorization: Bearer {tok}\r\n\r\n"
  let l2 ← run s!"POST /posts/7/like HTTP/1.1\r\nAuthorization: Bearer {tok}\r\n\r\n"
  results := results.push (← check "like 201 then 200" (has l1 "201 Created" && has l1 "\"already_liked\":false" && has l2 "200 OK" && has l2 "\"already_liked\":true"))
  results := results.push (← check "like missing post" (has (← run s!"POST /posts/9/like HTTP/1.1\r\nAuthorization: Bearer {tok}\r\n\r\n") "404 Not Found"))
  -- Db layer over fake cursors
  let expectedFeed := "{\"posts\":[{\"id\":3,\"body\":\"c\",\"created_at\":\"2026-01-01T00:00:03.000Z\",\"author\":\"ann\",\"like_count\":0},{\"id\":2,\"body\":\"b\\\"q\",\"created_at\":\"2026-01-01T00:00:02.000Z\",\"author\":\"bob\",\"like_count\":2},{\"id\":1,\"body\":\"a\",\"created_at\":\"2026-01-01T00:00:01.000Z\",\"author\":\"ann\",\"like_count\":1}]}"
  for fast in [true, false] do
    let cs ← Fake.cursors fast
    let st := Db.store cs
    let f ← st.feed
    results := results.push (← check s!"db feed (range walk fast={fast})" (match f with | .ok x => String.fromUTF8! x == expectedFeed | _ => false))
    let p ← st.post 2
    results := results.push (← check s!"db post 2 (fast={fast})" (match p with
      | .ok (some x) => String.fromUTF8! x == "{\"post\":{\"id\":2,\"body\":\"b\\\"q\",\"created_at\":\"2026-01-01T00:00:02.000Z\",\"author\":\"bob\",\"like_count\":2}}"
      | _ => false))
  let cs ← Fake.cursors true
  let st := Db.store cs
  results := results.push (← check "db post missing" (match ← st.post 9 with | .ok none => true | _ => false))
  results := results.push (← check "db postExists" (match ← st.postExists 1, ← st.postExists 5 with | .ok true, .ok false => true | _, _ => false))
  -- commit semantics: wrote flag set by create, cleared by endBatch
  let w2 ← IO.mkRef false
  let env2 : App.Env := { store := st, wrote := w2, secret, nowSecs := pure 1.8e9, uptimeS := pure 0 }
  let cbody := "{\"body\":\"x\"}"
  match Http.parse (b s!"POST /posts HTTP/1.1\r\nAuthorization: Bearer {tok}\r\nContent-Length: {cbody.utf8ByteSize}\r\n\r\n{cbody}") with
  | .done r _ => let _ ← App.handle env2 r
  | _ => pure ()
  results := results.push (← check "wrote set after create" (← w2.get))
  results := results.push (← check "endBatch commits and clears" ((← App.endBatch env2) && !(← w2.get)))
  -- Connection policy
  let held ← IO.mkRef false
  let two := "GET /health HTTP/1.1\r\n\r\nGET /feed HTTP/1.1\r\n\r\n"
  let c1 ← Conn.serve env (held.get) {} (b two)
  results := results.push (← check "pipelined: two responses" (let s := String.fromUTF8! c1.out; (s.splitOn "HTTP/1.1 200 OK").length == 3 && c1.pending.size == 0 && c1.answered))
  let c2 ← Conn.serve env (held.get) {} (b "GET /feed HTTP/1.1\r\nHo")
  results := results.push (← check "partial request is stashed" (c2.out.size == 0 && c2.pending.size > 0 && !c2.answered))
  let c3 ← Conn.serve env (held.get) c2 (b "st: x\r\n\r\n")
  results := results.push (← check "partial completed later" (((String.fromUTF8! c3.out).splitOn "{\"posts\":[]}").length == 2 && c3.pending.size == 0))
  let c4 ← Conn.serve env (held.get) {} (b "NOT HTTP\r\n\r\n")
  results := results.push (← check "bad request -> 400 + close" (c4.closeAfter && ((String.fromUTF8! c4.out).splitOn "400 Bad Request").length == 2))
  held.set true
  let pb := "POST /posts HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
  let c5 ← Conn.serve env (held.get) {} (b ("GET /health HTTP/1.1\r\n\r\n" ++ pb))
  results := results.push (← check "held write stops the pass" (c5.held && !c5.pending.isEmpty && ((String.fromUTF8! c5.out).splitOn "200 OK").length == 2))
  held.set false
  let c6 ← Conn.serve env (held.get) c5 ByteArray.empty
  results := results.push (← check "released write is answered" (((String.fromUTF8! c6.out).splitOn "401 Unauthorized").length == 2))
  let c7 ← Conn.serve env (held.get) {} (b two)
  let before := c7.out.size
  let rb := Conn.endBatch false c7
  results := results.push (← check "rollback replaces answers with 500" (rb.closeAfter && rb.out.size < before && ((String.fromUTF8! rb.out).splitOn "500 Internal").length == 2))
  results := results.push (← check "commit keeps answers" ((Conn.endBatch true c7).out == c7.out))
  -- SQLite record decoding
  results := results.push (← check "varint 1 byte" (Record.varint (ByteArray.mk #[0x7f]) 0 == some (127, 1)))
  results := results.push (← check "varint 2 bytes (128)" (Record.varint (ByteArray.mk #[0x81, 0x00]) 0 == some (128, 2)))
  results := results.push (← check "varint 9 bytes" (Record.varint (ByteArray.mk #[0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff]) 0 == some (0xffffffffffffffff, 9)))
  results := results.push (← check "varint truncated" (Record.varint (ByteArray.mk #[0x81]) 0).isNone)
  let rec1 := ByteArray.mk #[3, 1, 19, 0xff, 97, 98, 99]
  results := results.push (← check "columns int8 + text" (match Record.columns rec1 2 with
    | some [(1, a), (19, t)] => Record.intOf 1 a == some (-1) && Record.text (19, t) == some (b "abc")
    | _ => false))
  results := results.push (← check "columns header too long" (Record.columns (ByteArray.mk #[9, 1]) 1).isNone)
  results := results.push (← check "columns body too short" (Record.columns (ByteArray.mk #[2, 1]) 1).isNone)
  results := results.push (← check "intOf 3-byte" (Record.intOf 3 (ByteArray.mk #[0x01, 0x00, 0x00]) == some 65536))
  results := results.push (← check "intOf consts" (Record.intOf 8 ByteArray.empty == some 0 && Record.intOf 9 ByteArray.empty == some 1))
  results := results.push (← check "text rejects blob" (Record.text (18, ByteArray.empty)).isNone)
  let bad := results.filter (!·) |>.size
  IO.println s!"{results.size - bad}/{results.size} passed"
  pure (if bad == 0 then 0 else 1)
