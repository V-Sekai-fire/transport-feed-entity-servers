/* EntityServer skateboard: 64 Hz tick, UDP, in-memory entities, tick-to-send percentiles.
 * Packet layout comes from datasources/entity-packet/xr_grid_entity_packet.h and is not
 * re-declared here. Plain C99, no heap in the tick, no Lean headers. */
#ifndef ENTITY_TICK_H
#define ENTITY_TICK_H
#include <stdint.h>
#define ET_TICK_NS 15625000LL
#define ET_MAX_USERS 256
#define ET_VIEW 12
typedef struct {
  uint32_t ticks, overruns, packets_in, datagrams_out;
  int64_t p50_ns, p95_ns, p99_ns, max_ns;
} et_report_t;
/* Binds host:port (port 0 picks one, written to *bound), runs `ticks` ticks, fills `out`.
 * Returns 0, or a negative errno-style code. Linux and macOS (plain syscalls). */
int et_run(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, uint16_t *bound, et_report_t *out);
#endif
