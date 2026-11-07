#!/usr/bin/env bash
# Linux smoke test: build, seed a tiny DB, start the Lean io_uring server, hit it with curl.
set -u
mkdir -p /w && cd /src && tar cf - --exclude=.lake --exclude=.git . | tar xf - -C /w && cd /w
bash scripts/fetch-sqlite.sh
lake build feed-server 2>&1 | grep -E "^error|Build" | head -5
rm -f /tmp/f.db*
sqlite3 /tmp/f.db < reference/schema.sql
sqlite3 /tmp/f.db "PRAGMA journal_mode=WAL; INSERT INTO users(id,username) VALUES (1,'ann'),(2,'bob'); INSERT INTO posts(id,user_id,body,created_at) VALUES (1,1,'a','2026-01-01T00:00:01.000Z'),(2,2,'b','2026-01-01T00:00:02.000Z'); INSERT INTO likes(user_id,post_id) VALUES (1,2);" >/dev/null
SECRET=twelve-dollar-challenge
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
H=$(printf '{"alg":"HS256","typ":"JWT"}' | b64)
P=$(printf '{"sub":"1","username":"ann","exp":4102444800}' | b64)
S=$(printf '%s.%s' "$H" "$P" | openssl dgst -sha256 -hmac "$SECRET" -binary | b64)
TOK="$H.$P.$S"
SQLITE_PATH=/tmp/f.db JWT_SECRET=$SECRET HOST=127.0.0.1 PORT=3000 .lake/build/bin/feed-server &
PID=$!
sleep 2
echo "--- health";  curl -s -i http://127.0.0.1:3000/health | head -12
echo "--- feed";    curl -s http://127.0.0.1:3000/feed; echo
echo "--- post 2";  curl -s http://127.0.0.1:3000/posts/2; echo
echo "--- no auth"; curl -s -i -X POST http://127.0.0.1:3000/posts -d '{"body":"x"}' | head -1
echo "--- create";  curl -s -i -X POST http://127.0.0.1:3000/posts -H "Authorization: Bearer $TOK" -d '{"body":"hello from lean"}' | sed -n '1p;$p'
echo "--- like";    curl -s -X POST http://127.0.0.1:3000/posts/1/like -H "Authorization: Bearer $TOK"; echo
echo "--- like again"; curl -s -X POST http://127.0.0.1:3000/posts/1/like -H "Authorization: Bearer $TOK"; echo
echo "--- feed after"; curl -s http://127.0.0.1:3000/feed; echo
kill $PID 2>/dev/null
