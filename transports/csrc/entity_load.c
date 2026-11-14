#define _POSIX_C_SOURCE 200809L
#include "entity_cpus.h"
#include "entity_tick.h"
#include "../../datasources/entity-packet/xr_grid_entity_packet.h"
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define MAX_SOCKETS ET_MAX_USERS

static int fd[MAX_SOCKETS];
static struct sockaddr_storage to[MAX_SOCKETS];
static socklen_t tolen;

static int64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

/* Sends SENDS passes, one datagram per client per pass, one pass per tick. A pass that takes longer than a tick,
 * or starts more than a tick late, is counted: such a run measured the loader and not the server. */
int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: entity_load SENDS CLIENTS_PER_PORT PORT...\n"); return 2; }
  int sends = atoi(argv[1]), per = atoi(argv[2]), np = argc - 3, total = np * per;
  if (sends <= 0 || per <= 0 || total > MAX_SOCKETS) return 2;
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < (rlim_t)total + 32) {
    rl.rlim_cur = rl.rlim_max < (rlim_t)total + 32 ? rl.rlim_max : (rlim_t)total + 32;
    setrlimit(RLIMIT_NOFILE, &rl);
  }
  for (int p = 0; p < np; p++)
    for (int c = 0; c < per; c++) {
      int k = p * per + c;
      const char *host = getenv("ENTITY_LOAD_HOST") ? getenv("ENTITY_LOAD_HOST") : "127.0.0.1";
      struct sockaddr_in6 *t6 = (struct sockaddr_in6 *)&to[k]; struct sockaddr_in *t4 = (struct sockaddr_in *)&to[k];
      memset(&to[k], 0, sizeof to[k]);
      if (inet_pton(AF_INET6, host, &t6->sin6_addr) == 1) { t6->sin6_family = AF_INET6; t6->sin6_port = htons((uint16_t)atoi(argv[3 + p])); tolen = sizeof *t6; fd[k] = socket(AF_INET6, SOCK_DGRAM, 0); }
      else { inet_pton(AF_INET, host, &t4->sin_addr); t4->sin_family = AF_INET; t4->sin_port = htons((uint16_t)atoi(argv[3 + p])); tolen = sizeof *t4; fd[k] = socket(AF_INET, SOCK_DGRAM, 0); }
    }
  const char *ord = getenv("ENTITY_LOAD_ORDER");
  int interleave = ord && strcmp(ord, "interleave") == 0;
  xr_grid_entity_packet_t e;
  uint8_t pk[XR_PACKET_SIZE];
  int64_t next = now_ns(), max_pass = 0;
  int slow = 0, failed = 0;
  memset(&e, 0, sizeof e);
  for (int i = 0; i < sends; i++) {
    int64_t d = next - now_ns();
    if (d > 0) { struct timespec r = {(time_t)(d / 1000000000LL), (long)(d % 1000000000LL)}; nanosleep(&r, 0); }
    int64_t t0 = now_ns();
    for (int o = 0; o < total; o++) {
      /* blocked (default): all of port 0's clients, then port 1's. interleave: one client per port in turn. */
      int k = interleave ? (o % np) * per + o / np : o;
      e.gid = (uint32_t)k + 1;
      e.pos_um_x = i;
      xr_grid_entity_packet_encode(&e, pk);
      if (sendto(fd[k], pk, sizeof pk, 0, (struct sockaddr *)&to[k], tolen) < 0) failed++;
    }
    int64_t t1 = now_ns();
    if (t1 - t0 > max_pass) max_pass = t1 - t0;
    if (t1 - t0 > ET_TICK_NS || t0 - next > ET_TICK_NS) slow++;
    next += ET_TICK_NS;
  }
  char cpus[ET_CPUS_LEN];
  et_cpus_allowed(cpus, sizeof cpus);
  printf("load cpus=%s order=%s sockets=%d sends=%d max_pass_ns=%lldns slow_passes=%d sends_failed=%d\n", cpus, interleave ? "interleave" : "blocked", total, sends, (long long)max_pass, slow, failed);
  return 0;
}
