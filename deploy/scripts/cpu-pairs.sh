# Sourced by tick-layouts.sh and client-sweep.sh: reads which vCPUs share a physical core from sysfs.
# Runners pair 0-1/2-3 or 0,2/1,3; the scripts place work by these roles, not by fixed numbers.
# Sets SIB0 (cpu0's sibling), OC (first vCPU on another core) and SIBOC (OC's sibling), or prints FAIL and returns 1.
CPU_SYSFS=${CPU_SYSFS:-/sys/devices/system/cpu}

siblings_of() {
  local raw part a b out=""
  raw=$(cat "$CPU_SYSFS/cpu$1/topology/thread_siblings_list" 2>/dev/null) || return 1
  for part in ${raw//,/ }; do
    if [[ $part == *-* ]]; then
      a=${part%-*}; b=${part#*-}
      out="$out $(seq -s ' ' "$a" "$b")"
    else
      out="$out $part"
    fi
  done
  echo $out
}

partner_of() {
  local s c n=0 p=""
  s=$(siblings_of "$1") || return 1
  for c in $s; do n=$((n + 1)); [ "$c" != "$1" ] && p=$c; done
  [ "$n" = 2 ] && [ -n "$p" ] && echo "$p"
}

cpu_pairs() {
  local s0 c
  s0=$(siblings_of 0) || { echo "FAIL: cannot read $CPU_SYSFS/cpu0/topology/thread_siblings_list"; return 1; }
  SIB0=$(partner_of 0) || { echo "FAIL: vCPU 0 is not one of a pair of hyperthreads (siblings: $s0)"; return 1; }
  OC=""
  for c in $(seq 0 $(( $(ls -d "$CPU_SYSFS"/cpu[0-9]* | wc -l) - 1 ))); do
    case " $s0 " in *" $c "*) ;; *) OC=$c; break ;; esac
  done
  [ -n "$OC" ] || { echo "FAIL: no vCPU outside vCPU 0's core (siblings: $s0)"; return 1; }
  SIBOC=$(partner_of "$OC") || { echo "FAIL: vCPU $OC is not one of a pair of hyperthreads"; return 1; }
  echo "core pairs: 0+$SIB0 and $OC+$SIBOC"
}
