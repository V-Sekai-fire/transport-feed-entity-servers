#define _POSIX_C_SOURCE 200809L
#include "entity_tick.h"
#include "../../datasources/entity-packet/xr_grid_entity_packet.h"
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#define PKT XR_PACKET_SIZE
typedef struct { struct sockaddr_storage a; socklen_t al; int used; uint32_t slot; } sess_t;
static sess_t sess[ET_MAX_USERS];
static uint8_t ents[ET_MAX_USERS][PKT];
static int64_t lat[1 << 16];
static int64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec; }
static int cmp(const void *x, const void *y) { int64_t a = *(const int64_t *)x, b = *(const int64_t *)y; return (a > b) - (a < b); }
static int find(const struct sockaddr_storage *a, socklen_t al) {
  for (int i = 0; i < ET_MAX_USERS; i++)
    if (sess[i].used && sess[i].al == al && memcmp(&sess[i].a, a, al) == 0) return i;
  for (int i = 0; i < ET_MAX_USERS; i++)
    if (!sess[i].used) { sess[i].used = 1; sess[i].al = al; memcpy(&sess[i].a, a, al); memset(ents[i], 0, PKT); return i; }
  return -1;
}
static uint8_t dgs[ET_MAX_USERS][PKT * ET_VIEW];
static et_out_t outs[ET_MAX_USERS];
int et_run(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, uint16_t *bound, et_report_t *out) {
  return et_run_with(host, port, ticks, slow_ns, bound, out, 0);
}
int et_run_with(const char *host, uint16_t port, uint32_t ticks, uint32_t slow_ns, uint16_t *bound, et_report_t *out,
                const et_io_t *io) {
  if (ticks == 0 || ticks > (1u << 16)) return -EINVAL;
  memset(sess, 0, sizeof sess); memset(out, 0, sizeof *out);
  /* An IPv6 literal gives a dual-stack socket, so IPv4 clients come as v4-mapped addresses; an
   * IPv4 literal gives an IPv4 socket as before. */
  struct sockaddr_storage a; memset(&a, 0, sizeof a);
  struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&a; struct sockaddr_in *a4 = (struct sockaddr_in *)&a;
  socklen_t al;
  int fd;
  if (inet_pton(AF_INET6, host, &a6->sin6_addr) == 1) {
    a6->sin6_family = AF_INET6; a6->sin6_port = htons(port); al = sizeof *a6;
    fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd >= 0) { int off = 0; setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off); }
  } else if (inet_pton(AF_INET, host, &a4->sin_addr) == 1) {
    a4->sin_family = AF_INET; a4->sin_port = htons(port); al = sizeof *a4;
    fd = socket(AF_INET, SOCK_DGRAM, 0);
  } else return -EINVAL;
  if (fd < 0) return -errno;
  { socklen_t sl = al;
    if (bind(fd, (struct sockaddr *)&a, al) < 0 || getsockname(fd, (struct sockaddr *)&a, &sl) < 0) { int e = errno; close(fd); return -e; } }
  if (bound) *bound = ntohs(a.ss_family == AF_INET6 ? a6->sin6_port : a4->sin_port);
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
  if (io && io->open && io->open(fd) < 0) { close(fd); return -EIO; }
  int64_t next = now_ns() + ET_TICK_NS;
  for (uint32_t t = 0; t < ticks; t++) {
    struct timespec ts; ts.tv_sec = (time_t)(next / 1000000000LL); ts.tv_nsec = (long)(next % 1000000000LL);
#ifdef __linux__
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, 0);
#else
    { int64_t d = next - now_ns(); if (d > 0) { struct timespec r; r.tv_sec = (time_t)(d / 1000000000LL); r.tv_nsec = (long)(d % 1000000000LL); nanosleep(&r, 0); } }
#endif
    int64_t t0 = now_ns(), first = -1;
    uint8_t buf[PKT + 8]; struct sockaddr_storage from; socklen_t fl;
    for (;;) {
      fl = sizeof from;
      ssize_t n = recvfrom(fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
      if (n < 0) break;
      if (first < 0) first = now_ns();
      if (n != PKT) continue;
      int i = find(&from, fl);
      if (i >= 0) { memcpy(ents[i], buf, PKT); out->packets_in++; }
    }
    if (slow_ns) { int64_t end = now_ns() + slow_ns; while (now_ns() < end) { } }
    int n = 0;
    for (int i = 0; i < ET_MAX_USERS; i++) {
      if (!sess[i].used) continue;
      int k = 0;
      for (int j = 0; j < ET_MAX_USERS && k < ET_VIEW; j++)
        if (sess[j].used) { memcpy(dgs[n] + (size_t)k * PKT, ents[j], PKT); k++; }
      outs[n].buf = dgs[n]; outs[n].len = (uint32_t)k * PKT; outs[n].to = &sess[i].a; outs[n].tolen = sess[i].al;
      n++;
    }
    if (io && io->send_all) out->datagrams_out += (uint32_t)io->send_all(fd, outs, n);
    else
      for (int i = 0; i < n; i++)
        if (sendto(fd, outs[i].buf, outs[i].len, 0, (const struct sockaddr *)outs[i].to, outs[i].tolen) >= 0) out->datagrams_out++;
    int64_t t1 = now_ns();
    lat[t] = t1 - (first >= 0 ? first : t0);
    if (t1 > next + ET_TICK_NS) { out->overruns++; next = t1 + ET_TICK_NS; } else next += ET_TICK_NS;
  }
  out->ticks = ticks;
  { static int64_t s[1 << 16]; memcpy(s, lat, (size_t)ticks * sizeof(int64_t));
    qsort(s, ticks, sizeof(int64_t), cmp);
    out->p50_ns = s[ticks / 2]; out->p95_ns = s[(ticks * 95u) / 100]; out->p99_ns = s[(ticks * 99u) / 100]; out->max_ns = s[ticks - 1]; }
  out->rcvbuf_drops = -1;
#ifdef SO_MEMINFO
  { uint32_t mi[9]; socklen_t ml = sizeof mi; /* SK_MEMINFO_DROPS is index 8 */
    if (getsockopt(fd, SOL_SOCKET, SO_MEMINFO, mi, &ml) == 0 && ml >= sizeof mi) out->rcvbuf_drops = (int64_t)mi[8]; }
#endif
  if (io && io->close) io->close();
  close(fd);
  return 0;
}
