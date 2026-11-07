#!/usr/bin/env bash
# Differential test, run inside the privileged container: the Rust reference (the oracle) and the
# Lean port serve copies of the same seed database; every request in the corpus is sent to both as
# raw bytes and the raw responses are compared. Only the clock-dependent fields are masked.
set -u
export LC_ALL=C
S=twelve-dollar-challenge
mkdir -p /w && cd /src && tar cf - --exclude=.lake --exclude=.git --exclude=target . | tar xf - -C /w && cd /w
bash deploy/scripts/fetch-sqlite.sh
echo "== build Lean";  lake build feed-server 2>&1 | grep -E "^error|Build" | head -3
echo "== build Rust";  (cd datasources/reference && bash build.sh 2>&1 | tail -2)
echo "== seed"
git clone -q --depth 1 https://github.com/arjaythedev/twelve-dollar-server-challenge.git /c
(cd /c && bash seed/make-seed.sh >/dev/null 2>&1)
cp /c/seed/feed.db /tmp/rust.db; cp /c/seed/feed.db /tmp/lean.db

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
tok() { local h p; h=$(printf '%s' "$1" | b64); p=$(printf '%s' "$2" | b64)
        printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$S" -binary | b64)"; }
HDR='{"alg":"HS256","typ":"JWT"}'
GOOD=$(tok "$HDR" '{"sub":"1","username":"ann","exp":4102444800}')
D=/tmp/cases; rm -rf $D; mkdir -p $D; n=0
mk() { n=$((n+1)); f=$(printf '%s/%03d-%s.req' $D $n "${1//[^A-Za-z0-9._-]/_}"); { printf '%b' "$2"; printf '%s' "${3-}"; } > "$f"; }
mk2() { f=$(printf '%s/%03d-%s.req2' $D $n "${1//[^A-Za-z0-9._-]/_}"); printf '%b' "$2" > "$f"; }
G() { mk "$1" "GET $2 HTTP/1.1\r\nHost: x\r\n\r\n"; }
PB() { mk "$1" "POST $2 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer $3\r\nContent-Length: ${#4}\r\n\r\n" "$4"; }
LK() { mk "$1" "POST $2 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer $3\r\n\r\n"; }

G health /health; G feed /feed; G feed-query "/feed?x=1&y=2"
for id in 1 2 99999999 0 -1 01 abc 1/ 123456789012345678 1234567890123456789 "1%20"; do G "post-$id" "/posts/$id"; done
G post-trailing-slash /posts/; G double-slash //feed; G unknown /nope; G root /
for m in HEAD PUT DELETE OPTIONS PATCH; do mk "method-$m" "$m /feed HTTP/1.1\r\nHost: x\r\n\r\n"; done
mk http10 "GET /feed HTTP/1.0\r\n\r\n"; mk http2 "GET /feed HTTP/2.0\r\n\r\n"; mk bare-lf "GET /feed HTTP/1.1\nHost: x\n\n"
mk no-version "GET /feed\r\n\r\n"; mk lowercase-method "get /feed HTTP/1.1\r\n\r\n"
mk te "POST /posts HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
mk cl-letters "POST /posts HTTP/1.1\r\nContent-Length: 1x\r\n\r\n"
mk cl-empty "POST /posts HTTP/1.1\r\nContent-Length:\r\n\r\n"
mk cl-10digits "POST /posts HTTP/1.1\r\nContent-Length: 1234567890\r\n\r\n"
mk cl-over-1mb "POST /posts HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n"
mk cl-zeros "POST /posts HTTP/1.1\r\nAuthorization: Bearer $GOOD\r\nContent-Length: 0000012\r\n\r\n" '{"body":"hi"}'
mk head-16k "GET /feed HTTP/1.1\r\nX-Pad: $(head -c 17000 /dev/zero | tr '\0' a)\r\n\r\n"
mk upper-headers "POST /posts HTTP/1.1\r\nAUTHORIZATION: Bearer $GOOD\r\nCONTENT-LENGTH: 13\r\n\r\n" '{"body":"hi"}'
mk dup-auth "POST /posts HTTP/1.1\r\nAuthorization: Bearer x\r\nAuthorization: Bearer $GOOD\r\nContent-Length: 13\r\n\r\n" '{"body":"hi"}'
mk pipelined "GET /health HTTP/1.1\r\n\r\nGET /feed HTTP/1.1\r\n\r\nGET /posts/1 HTTP/1.1\r\n\r\n"
mk split-head "GET /fe"; mk2 split-head "ed HTTP/1.1\r\n\r\n"
mk split-body "POST /posts HTTP/1.1\r\nAuthorization: Bearer $GOOD\r\nContent-Length: 13\r\n\r\n" '{"body"'; mk2 split-body '' ; printf ':"hi"}' > $(printf '%s/%03d-split-body.req2' $D $n)
PB noauth /posts "" '{"body":"x"}'; PB badsig /posts "${GOOD%?}A" '{"body":"x"}'
mk bearer-lower "POST /posts HTTP/1.1\r\nAuthorization: bearer $GOOD\r\nContent-Length: 13\r\n\r\n" '{"body":"hi"}'
PB create /posts "$GOOD" '{"body":"hello"}'
PB create-trim /posts "$GOOD" '{"body":"  hi there  "}'
PB create-nbsp /posts "$GOOD" "{\"body\":\"$(printf '\xc2\xa0')x$(printf '\xc2\xa0')\"}"
PB create-nel /posts "$GOOD" "{\"body\":\"$(printf '\xc2\x85')x\"}"
PB create-bom /posts "$GOOD" "{\"body\":\"$(printf '\xef\xbb\xbf')x\"}"
PB create-escapes /posts "$GOOD" '{"body":"a\"b\\c\/d\n\t\u0041\u00e9"}'
PB create-surrogate /posts "$GOOD" '{"body":"\ud83d\ude00 \ud800x"}'
PB create-nul /posts "$GOOD" '{"body":"a\u0000b"}'
PB create-dupkeys /posts "$GOOD" '{"body":"first","body":"last"}'
PB create-escaped-key /posts "$GOOD" '{"b\u006fdy":"esc key"}'
PB create-num /posts "$GOOD" '{"body":5}'; PB create-null /posts "$GOOD" '{"body":null}'
PB create-array /posts "$GOOD" '[1]'; PB create-empty-obj /posts "$GOOD" '{}'; PB create-blank /posts "$GOOD" '{"body":"   "}'
PB create-badjson /posts "$GOOD" '{"body":'; PB create-trailing /posts "$GOOD" '{"body":"x"} x'
PB create-500 /posts "$GOOD" "{\"body\":\"$(head -c 500 /dev/zero | tr '\0' a)\"}"
PB create-501 /posts "$GOOD" "{\"body\":\"$(head -c 501 /dev/zero | tr '\0' a)\"}"
PB create-500-emoji /posts "$GOOD" "{\"body\":\"$(for i in $(seq 250); do printf '\xf0\x9f\x98\x80'; done)\"}"
PB create-501-emoji /posts "$GOOD" "{\"body\":\"$(for i in $(seq 501); do printf '\xf0\x9f\x98\x80'; done)\"}"
PB create-251-emoji /posts "$GOOD" "{\"body\":\"$(for i in $(seq 251); do printf '\xf0\x9f\x98\x80'; done)\"}"
PB create-invalid-utf8 /posts "$GOOD" "{\"body\":\"$(printf '\xff')\"}"
PB create-depth64 /posts "$GOOD" "{\"body\":\"x\",\"z\":$(printf '%64s' | tr ' ' '[')$(printf '%64s' | tr ' ' ']')}"
PB create-depth66 /posts "$GOOD" "{\"body\":\"x\",\"z\":$(printf '%66s' | tr ' ' '[')$(printf '%66s' | tr ' ' ']')}"
PB create-numbers /posts "$GOOD" '{"body":"x","a":-0.5e+3,"b":1E2,"c":01}'
PB create-numbers-ok /posts "$GOOD" '{"body":"x","a":-0.5e+3,"b":1E2,"c":0}'
LK like-1 /posts/1/like "$GOOD"; LK like-1-again /posts/1/like "$GOOD"; LK like-missing /posts/99999999/like "$GOOD"
LK like-bad-id /posts/abc/like "$GOOD"; LK like-0 /posts/0/like "$GOOD"; LK like-noauth /posts/1/like ""; LK like-slash /posts/1/like/ "$GOOD"
LK like-nested /posts/1/2/like "$GOOD"
for c in '{"sub":"01","username":"a","exp":4102444800}' '{"sub":1,"username":"a","exp":4102444800}' '{"sub":"1\u0030","username":"a","exp":4102444800}' \
         '{"sub":"1","exp":4102444800}' '{"sub":"1","username":"a"}' '{"sub":"1","username":"a","exp":"4102444800"}' '{"sub":"1","username":"a","exp":1}' \
         '{"sub":"1","username":"a\u00e9\"q","exp":4102444800}' '{"sub":"1","username":"a","exp":4102444800.5}' '{"sub":"1","username":5,"exp":4102444800}' \
         '{"sub":"9999999999999999999","username":"a","exp":4102444800}' '[1]'; do
  t=$(tok "$HDR" "$c"); PB "jwt-$(printf '%s' "$c" | md5sum | cut -c1-6)" /posts "$t" '{"body":"j"}'; done
for h in '{"alg":"none"}' '{"typ":"JWT"}' '{"alg":"HS512"}' '{"alg":"HS\u0032\u0035\u0036"}' '[1]'; do
  t=$(tok "$h" '{"sub":"1","username":"a","exp":4102444800}'); PB "jwt-hdr-$(printf '%s' "$h" | md5sum | cut -c1-6)" /posts "$t" '{"body":"j"}'; done
PB jwt-two-parts /posts "a.b" '{"body":"x"}'; PB jwt-four-parts /posts "$GOOD.x" '{"body":"x"}'
mk jwt-noncanon-b64 "POST /posts HTTP/1.1\r\nAuthorization: Bearer ${GOOD%.*}.$(printf '%s' "${GOOD##*.}" | sed 's/.$/B/')\r\nContent-Length: 13\r\n\r\n" '{"body":"hi"}'
G feed-after /feed; G post-new /posts/1000001; G health-after /health

echo "== run $n cases"
( cd /w/datasources/reference && SQLITE_PATH=/tmp/rust.db JWT_SECRET=$S HOST=127.0.0.1 PORT=3001 ./target/release/feed-server 2>/tmp/rust.err & )
( cd /w && SQLITE_PATH=/tmp/lean.db JWT_SECRET=$S HOST=127.0.0.1 PORT=3000 .lake/build/bin/feed-server 2>/tmp/lean.err & )
sleep 3
send() { ( cat "$2"; [ -f "${2}2" ] && { sleep 0.3; cat "${2}2"; } ) | timeout 4 nc -q1 127.0.0.1 "$1"; }
YM=$(date -u +%Y-%m)
norm() { sed -E "s/${YM}-[0-9]{2}T[0-9:.]+Z/TS/g; s/\"uptime_s\":[0-9]+/\"uptime_s\":N/g"; }
same=0; diffs=0; nonempty=0; : > /tmp/status.rust
for f in $(ls $D/*.req | sort); do
  b=$(basename $f .req)
  send 3001 $f | norm > /tmp/o.rust; send 3000 $f | norm > /tmp/o.lean
  [ -s /tmp/o.rust ] && nonempty=$((nonempty+1))
  head -1 /tmp/o.rust | tr -d '\r' >> /tmp/status.rust
  if cmp -s /tmp/o.rust /tmp/o.lean; then same=$((same+1)); else
    diffs=$((diffs+1)); echo "DIFF $b"; echo "  rust: $(head -c 300 /tmp/o.rust | cat -v | tr '\n' ' ')"; echo "  lean: $(head -c 300 /tmp/o.lean | cat -v | tr '\n' ' ')"; fi
done
echo "identical=$same different=$diffs cases=$(ls $D/*.req | wc -l) rust_nonempty=$nonempty"
echo "== rust status lines"; sort /tmp/status.rust | uniq -c | sort -rn
echo "== rust stderr"; head -3 /tmp/rust.err; echo "== lean stderr"; head -3 /tmp/lean.err
pkill feed-server 2>/dev/null; true
