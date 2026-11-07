/* Loopback check: 4 clients send packets, the server ticks 64 times. Exit 1 on failure.
 * With ENTITY_SLOW_NS set it runs the planted slow handler: it must fail the 4 ms budget. */
#define _POSIX_C_SOURCE 200809L
#include "entity_tick.h"
#include "../../datasources/entity-packet/xr_grid_entity_packet.h"
#include <arpa/inet.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define N 4
static uint16_t port;
static void *client(void *arg) {
  int id = (int)(intptr_t)arg, fd = socket(AF_INET, SOCK_DGRAM, 0);
  struct sockaddr_in s; memset(&s, 0, sizeof s); s.sin_family = AF_INET; s.sin_port = htons(port); inet_pton(AF_INET, "127.0.0.1", &s.sin_addr);
  uint8_t p[XR_PACKET_SIZE]; xr_grid_entity_packet_t e; memset(&e, 0, sizeof e); e.gid = (uint32_t)id + 1;
  for (int i = 0; i < 60; i++) { e.pos_um_x = i; xr_grid_entity_packet_encode(&e, p); sendto(fd, p, sizeof p, 0, (struct sockaddr *)&s, sizeof s); { struct timespec z = {0, 15625000L}; nanosleep(&z, 0); } }
  close(fd); return 0;
}
int main(void) {
  const char *sl = getenv("ENTITY_SLOW_NS"); uint32_t slow = sl ? (uint32_t)atol(sl) : 0;
  et_report_t r; int rc;
  /* the server binds first; clients learn the port through a fixed one */
  port = 47321;
  pthread_t th[N];
  for (int i = 0; i < N; i++) pthread_create(&th[i], 0, client, (void *)(intptr_t)i);
  rc = et_run("127.0.0.1", port, 64, slow, 0, &r);
  for (int i = 0; i < N; i++) pthread_join(th[i], 0);
  printf("rc=%d ticks=%u packets_in=%u datagrams_out=%u overruns=%u p50=%lldns p95=%lldns p99=%lldns max=%lldns\n", rc, r.ticks, r.packets_in, r.datagrams_out, r.overruns, (long long)r.p50_ns, (long long)r.p95_ns, (long long)r.p99_ns, (long long)r.max_ns);
  if (rc != 0 || r.packets_in < N * 20 || r.datagrams_out < 64) { puts("FAIL: no traffic"); return 1; }
  if (r.p99_ns > 4000000LL) { puts("FAIL: p99 over the 4 ms budget"); return 1; }
  puts("PASS"); return 0;
}
