#define _POSIX_C_SOURCE 200809L
#include "entity_cpus.h"
#include "entity_tick.h"
#include "../../datasources/entity-packet/xr_grid_entity_packet.h"
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#define MAX_SOCKETS 64

static int64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: entity_load SENDS CLIENTS_PER_PORT PORT...\n"); return 2; }
  int sends = atoi(argv[1]), per = atoi(argv[2]), np = argc - 3, total = np * per;
  if (sends <= 0 || per <= 0 || total > MAX_SOCKETS) return 2;
  int fd[MAX_SOCKETS];
  struct sockaddr_in to[MAX_SOCKETS];
  for (int p = 0; p < np; p++)
    for (int c = 0; c < per; c++) {
      int k = p * per + c;
      fd[k] = socket(AF_INET, SOCK_DGRAM, 0);
      memset(&to[k], 0, sizeof to[k]);
      to[k].sin_family = AF_INET;
      to[k].sin_port = htons((uint16_t)atoi(argv[3 + p]));
      inet_pton(AF_INET, "127.0.0.1", &to[k].sin_addr);
    }
  xr_grid_entity_packet_t e;
  uint8_t pk[XR_PACKET_SIZE];
  int64_t next = now_ns();
  memset(&e, 0, sizeof e);
  for (int i = 0; i < sends; i++) {
    int64_t d = next - now_ns();
    if (d > 0) { struct timespec r = {(time_t)(d / 1000000000LL), (long)(d % 1000000000LL)}; nanosleep(&r, 0); }
    for (int k = 0; k < total; k++) {
      e.gid = (uint32_t)k + 1;
      e.pos_um_x = i;
      xr_grid_entity_packet_encode(&e, pk);
      sendto(fd[k], pk, sizeof pk, 0, (struct sockaddr *)&to[k], sizeof to[k]);
    }
    next += ET_TICK_NS;
  }
  char cpus[ET_CPUS_LEN];
  et_cpus_allowed(cpus, sizeof cpus);
  printf("load cpus=%s sockets=%d sends=%d\n", cpus, total, sends);
  return 0;
}
