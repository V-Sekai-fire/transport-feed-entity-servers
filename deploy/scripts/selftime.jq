# Top self-time table from a samply --unstable-presymbolicate profile.
# usage: gzip -dc X.profile.json.gz | jq -r --slurpfile S X.profile.json.syms.json -f scripts/selftime.jq
def hex2n: ltrimstr("0x") | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
($S[0]) as $s
| (.threads | max_by(.samples.length)) as $t
| ($t.samples.length) as $n
| [ $t.samples.stack[] | select(. != null)
    | $t.stackTable.frame[.] as $fr | $t.frameTable.func[$fr] as $fn
    | { name: $t.stringArray[$t.funcTable.name[$fn]], lib: $t.resourceTable.lib[$t.funcTable.resource[$fn]] } ]
| group_by([.name, .lib]) | map({name: .[0].name, lib: .[0].lib, c: length})
| map( . as $f
      | (if ($f.name | startswith("0x")) then ($f.name | hex2n) else null end) as $a
      | ( if $a == null then $f.name
          else ([ $s.data[$f.lib].symbol_table[] | select(.rva <= $a and $a < .rva + .size) ][0].symbol) as $si
               | (if $si == null then $f.name else $s.string_table[$si] end) end ) as $sym
      | { sym: $sym, lib: $s.data[$f.lib].debug_name, c: $f.c } )
| group_by([.sym, .lib]) | map({sym: .[0].sym, lib: .[0].lib, c: (map(.c) | add)}) | sort_by(-.c) as $rows
| "samples on the busiest thread: \($n)  (1 ms interval, 20 s window)",
  ($rows[0:12][] | "\(.c)\t\(((.c * 1000 / $n) | round) / 10)%\t\(.lib)\t\(.sym)")
