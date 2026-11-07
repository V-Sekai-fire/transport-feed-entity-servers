#!/usr/bin/env bash
# Acceptance: the challenge's own seed + test/test.sh against the Lean server (Linux, privileged).
set -u
apt-get install -y -qq nodejs >/dev/null 2>&1
mkdir -p /w && cd /src && tar cf - --exclude=.lake --exclude=.git . | tar xf - -C /w && cd /w
bash scripts/fetch-sqlite.sh
bash scripts/fetch-sqlite.sh
lake build feed-server 2>&1 | grep -E "^error|Build" | head -3
git clone -q --depth 1 https://github.com/arjaythedev/twelve-dollar-server-challenge.git /c 2>&1 | tail -1
cd /c && bash seed/make-seed.sh >/dev/null 2>&1; ls seed
cp seed/feed.db /tmp/a.db
cd /w
SQLITE_PATH=/tmp/a.db JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3000 .lake/build/bin/feed-server &
sleep 3

BASE_URL=http://127.0.0.1:3000 bash test/test.sh http://127.0.0.1:3000 2>&1 | tail -25
