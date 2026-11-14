#define _POSIX_C_SOURCE 200809L
#include "entity_cpus.h"
#include "entity_tick.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Control, not a send path: the tick runs in full and the sends are skipped, so the difference from plain is the
 * cost of the sendto calls. It reports every datagram as sent, so datagrams_out is not a count of anything real. */
static int nosend_all(int fd, const et_out_t *o, int n) { (void)fd; (void)o; return n; }
static const et_io_t nosend_io = { 0, nosend_all, 0 };

int main(int argc, char **argv) {
  if (argc != 5 && argc != 6) { fprintf(stderr, "usage: entity_serve NAME PORT TICKS SLOW_NS [plain|nosend]\n"); return 2; }
  uint16_t port = (uint16_t)atoi(argv[2]);
  uint32_t ticks = (uint32_t)atol(argv[3]), slow = (uint32_t)atol(argv[4]);
  const char *be = argc == 6 ? argv[5] : "plain";
  char cpus[ET_CPUS_LEN];
  et_report_t r;
  const et_io_t *io = 0;
  if (strcmp(be, "nosend") == 0) io = &nosend_io;
  else if (strcmp(be, "plain") != 0) { fprintf(stderr, "backend %s is not built in\n", be); return 2; }
  et_cpus_allowed(cpus, sizeof cpus);
  const char *host = getenv("ENTITY_SERVE_HOST") ? getenv("ENTITY_SERVE_HOST") : "127.0.0.1";
  int rc = et_run_with(host, port, ticks, slow, 0, &r, io);
  printf("%s cpus=%s rc=%d ticks=%u packets_in=%u datagrams_out=%u overruns=%u p50=%lldns p95=%lldns p99=%lldns max=%lldns rcvbuf_drops=%lldpackets\n", argv[1], cpus, rc,
         r.ticks, r.packets_in, r.datagrams_out, r.overruns, (long long)r.p50_ns, (long long)r.p95_ns, (long long)r.p99_ns,
         (long long)r.max_ns, (long long)r.rcvbuf_drops);
  if (argc == 6) printf("backend=%s\n", be);
  if (rc != 0 || r.packets_in < 80) { puts("FAIL: no traffic"); return 1; }
  if (r.p99_ns > 4000000LL) { puts("FAIL: p99 over the 4 ms budget"); return 1; }
  puts("PASS");
  return 0;
}
