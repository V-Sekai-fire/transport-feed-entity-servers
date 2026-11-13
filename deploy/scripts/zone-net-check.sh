#!/usr/bin/env bash
# The relay on sockets: rules of the source, two planted defects, then the clean run. See docs/zone-net.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="${BIN:-$(mktemp -d)}"
CC="${CC:-gcc}"
SRC=transports/csrc
STRICT="-std=c99 -Wall -Wextra -Werror -pedantic -O2"
RUNS="${RUNS:-8}"

opaque() {
  ! grep -n -E 'dgram|held' "$1" | grep -v -E \
    -e '^[0-9]+: +static uint8_t dgram\[ZR_FRAME_MAX \+ 1\];$' \
    -e '^[0-9]+: +ssize_t n = recvfrom\(fd\[half\], dgram, sizeof dgram, 0, \(struct sockaddr \*\)&from, &fl\);$' \
    -e '^[0-9]+: +if \(!zr_put\(z, slot, half, dgram, \(size_t\)n\)\) \{ out->refused\+\+; continue; \}$' \
    -e '^[0-9]+: +const uint8_t \*held = zr_frame\(z, v, \(slot > v \? slot - 1 : slot\) \* 2 \+ half, &len\);$' \
    -e '^[0-9]+: +if \(sendto\(fd\[(half|1 - half)\], held, len, 0, \(const struct sockaddr \*\)&who\[seated\[zi\]\[v\]\]\.a, sizeof who\[0\]\.a\) >= 0\) out->datagrams_out\+\+;$'
}

$CC $STRICT -c "$SRC/zone_relay.c" -o "$BIN/zone_relay.o"
$CC $STRICT -c "$SRC/zone_net.c" -o "$BIN/zone_net.o"
$CC $STRICT -DZN_PLANT_HALF -c "$SRC/zone_net.c" -o "$BIN/zone_net_half.o"
$CC -std=gnu99 -O2 -Wall -Wextra -Werror -pthread "$SRC/zone_net_check.c" "$BIN/zone_net.o" "$BIN/zone_relay.o" -o "$BIN/zone_net_check"
$CC -std=gnu99 -O2 -Wall -Wextra -Werror -pthread "$SRC/zone_net_check.c" "$BIN/zone_net_half.o" "$BIN/zone_relay.o" -o "$BIN/zone_net_check_half"
$CC $STRICT "$SRC/zone_serve.c" "$BIN/zone_net.o" "$BIN/zone_relay.o" -o "$BIN/zone_serve"
$CC $STRICT "$SRC/zone_load.c" -o "$BIN/zone_load"

if nm "$BIN/zone_net.o" | grep -E ' U _?(malloc|calloc|realloc|free|lean_)'; then echo "the socket layer has an allocator or Lean symbol"; exit 1; fi
opaque "$SRC/zone_net.c" || { echo "the socket layer touches a frame outside recvfrom, zr_put, zr_frame and sendto"; exit 1; }
sed 's|^        out->frames_in++;$|        out->frames_in += 1 + (dgram[0] \& 0);|' "$SRC/zone_net.c" > "$BIN/zone_net_reads.c"
if cmp -s "$SRC/zone_net.c" "$BIN/zone_net_reads.c"; then echo "the planted read was not planted"; exit 1; fi
if opaque "$BIN/zone_net_reads.c" > /dev/null; then echo "the source rule did not catch a planted read"; exit 1; fi
echo "RULES no heap, no Lean, a frame goes only to recvfrom, zr_put, zr_frame and sendto, planted read caught"

must_fail() {
  local want="$1"; shift
  for i in $(seq 1 "$RUNS"); do
    if "$@" > "$BIN/control.out"; then cat "$BIN/control.out"; echo "run $i: planted defect not caught"; exit 1; fi
    grep -q "^RESULT: FAIL $want" "$BIN/control.out" || { cat "$BIN/control.out"; echo "run $i: failed for another reason"; exit 1; }
  done
  tail -1 "$BIN/control.out"
}
must_fail "a frame came from the socket of the other half" "$BIN/zone_net_check_half"
must_fail "p99 over the 4 ms budget" env ZONE_SLOW_NS=6000000 "$BIN/zone_net_check"
for i in $(seq 1 "$RUNS"); do "$BIN/zone_net_check" > "$BIN/clean.out" || { cat "$BIN/clean.out"; echo "run $i of the clean check failed"; exit 1; }; done
cat "$BIN/clean.out"
