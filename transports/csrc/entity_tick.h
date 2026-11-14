/* EntityServer skateboard: 64 Hz tick, UDP, in-memory entities, tick-to-send percentiles.
 * Packet layout comes from datasources/entity-packet/xr_grid_entity_packet.h and is not
 * re-declared here. Plain C99, no heap in the tick, no Lean headers. */
#ifndef ENTITY_TICK_H
#define ENTITY_TICK_H
#include <stdint.h>
#define ET_TICK_NS 15625000LL
#define ET_MAX_USERS 4096
#define ET_VIEW 12
typedef struct {
  uint32_t ticks, overruns, packets_in, datagrams_out;
  int64_t p50_ns, p95_ns, p99_ns, max_ns;
  int ring; /* 1 where receive goes through io_uring, fixed at build time; drops then count CQ overflow */
  int64_t rcvbuf_drops; /* datagrams the kernel dropped on the server socket; -1 where the kernel does not say */
} et_report_t;
/* Binds host:port (port 0 picks one, written to *bound), runs `ticks` ticks, fills `out`.
 * Returns 0, or a negative errno-style code. Linux and macOS (plain syscalls). */
int et_run(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, uint16_t *bound, et_report_t *out);
/* One outgoing datagram. `to` points at the session's sockaddr_in; it stays valid until send_all returns. */
typedef struct { const void *buf; uint32_t len; const void *to; uint32_t tolen; } et_out_t;
/* Optional send backend. NULL, or a NULL send_all, means one sendto per datagram. send_all returns how many
 * datagrams the kernel accepted and must not return before all `n` have completed, so the tick clock stops
 * after the sends, not at submit. open runs once after the socket is bound, close once at the end. */
typedef struct {
  int (*open)(int fd);
  int (*send_all)(int fd, const et_out_t *o, int n);
  void (*close)(void);
} et_io_t;
int et_run_with(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, uint16_t *bound, et_report_t *out,
                const et_io_t *io);
#endif
