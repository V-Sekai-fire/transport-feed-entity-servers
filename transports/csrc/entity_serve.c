#define _POSIX_C_SOURCE 200809L
#include "entity_cpus.h"
#include "entity_tick.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 5 && argc != 6) { fprintf(stderr, "usage: entity_serve NAME PORT TICKS SLOW_NS\n"); return 2; }
  uint16_t port = (uint16_t)atoi(argv[2]);
  uint32_t ticks = (uint32_t)atol(argv[3]), slow = (uint32_t)atol(argv[4]);
  const char *be = argc == 6 ? argv[5] : "plain";
  char cpus[ET_CPUS_LEN];
  et_report_t r;
  if (strcmp(be, "plain") != 0) { fprintf(stderr, "backend %s is not built in\n", be); return 2; }
  et_cpus_allowed(cpus, sizeof cpus);
  int rc = et_run_with("127.0.0.1", port, ticks, slow, 0, &r, 0);
  printf("%s cpus=%s rc=%d ticks=%u packets_in=%u datagrams_out=%u overruns=%u p50=%lldns p95=%lldns p99=%lldns max=%lldns rcvbuf_drops=%lldpackets\n", argv[1], cpus, rc,
         r.ticks, r.packets_in, r.datagrams_out, r.overruns, (long long)r.p50_ns, (long long)r.p95_ns, (long long)r.p99_ns,
         (long long)r.max_ns, (long long)r.rcvbuf_drops);
  if (argc == 6) printf("backend=%s\n", be);
  if (rc != 0 || r.packets_in < 80) { puts("FAIL: no traffic"); return 1; }
  if (r.p99_ns > 4000000LL) { puts("FAIL: p99 over the 4 ms budget"); return 1; }
  puts("PASS");
  return 0;
}
