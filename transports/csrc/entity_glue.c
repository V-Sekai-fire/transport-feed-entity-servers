/* Lean ABI wrapper for entity_tick.c. Policy stays in C; this file only converts arguments. */
#include <lean/lean.h>
#include <stdio.h>
#include "entity_tick.h"
LEAN_EXPORT lean_obj_res lean_entity_run(b_lean_obj_arg host, uint32_t port, uint32_t ticks, uint32_t slow_ns, lean_obj_arg w) {
  et_report_t r; uint16_t bound = 0; char msg[256];
  int rc = et_run(lean_string_cstr(host), (uint16_t)port, ticks, slow_ns, &bound, &r);
  if (rc != 0) { snprintf(msg, sizeof msg, "error %d", rc); return lean_io_result_mk_ok(lean_mk_string(msg)); }
  snprintf(msg, sizeof msg, "ticks=%u in=%u out=%u overruns=%u p50=%lld p95=%lld p99=%lld max=%lld ns",
           r.ticks, r.packets_in, r.datagrams_out, r.overruns, (long long)r.p50_ns, (long long)r.p95_ns, (long long)r.p99_ns, (long long)r.max_ns);
  return lean_io_result_mk_ok(lean_mk_string(msg));
}
