#ifdef __linux__
#define _GNU_SOURCE /* sendmmsg */
#endif
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
#ifdef __linux__
#include <sys/socket.h>
#include <sys/uio.h>
/* Batched send: one sendmmsg call per up to 1024 datagrams (UIO_MAXIOV) instead of one sendto each. Static arrays,
 * so the tick still has no heap. sendmmsg is synchronous, so the tick clock stops after the sends. A short return
 * (full socket buffer) stops the loop and the missing datagrams are not counted, as with a failed sendto. */
static struct mmsghdr mm[ET_MAX_USERS];
static struct iovec mv[ET_MAX_USERS];
static int mmsg_all(int fd, const et_out_t *o, int n) {
  for (int i = 0; i < n; i++) {
    mv[i].iov_base = (void *)o[i].buf; mv[i].iov_len = o[i].len;
    memset(&mm[i], 0, sizeof mm[i]);
    mm[i].msg_hdr.msg_name = (void *)o[i].to; mm[i].msg_hdr.msg_namelen = o[i].tolen;
    mm[i].msg_hdr.msg_iov = &mv[i]; mm[i].msg_hdr.msg_iovlen = 1;
  }
  int sent = 0;
  while (sent < n) {
    int chunk = n - sent > 1024 ? 1024 : n - sent;
    int r = sendmmsg(fd, mm + sent, (unsigned)chunk, 0);
    if (r <= 0) break;
    sent += r;
  }
  return sent;
}
static const et_io_t mmsg_io = { 0, mmsg_all, 0 };
#endif

int main(int argc, char **argv) {
  if (argc != 5 && argc != 6) { fprintf(stderr, "usage: entity_serve NAME PORT TICKS SLOW_NS [plain|nosend|sendmmsg]\n"); return 2; }
  uint16_t port = (uint16_t)atoi(argv[2]);
  uint32_t ticks = (uint32_t)atol(argv[3]), slow = (uint32_t)atol(argv[4]);
  const char *be = argc == 6 ? argv[5] : "plain";
  char cpus[ET_CPUS_LEN];
  et_report_t r;
  const et_io_t *io = 0;
  if (strcmp(be, "nosend") == 0) io = &nosend_io;
#ifdef __linux__
  else if (strcmp(be, "sendmmsg") == 0) io = &mmsg_io;
#endif
  else if (strcmp(be, "plain") != 0) { fprintf(stderr, "backend %s is not built in\n", be); return 2; }
  et_cpus_allowed(cpus, sizeof cpus);
  int rc = et_run_with("127.0.0.1", port, ticks, slow, 0, &r, io);
  printf("%s cpus=%s rc=%d ticks=%u packets_in=%u datagrams_out=%u overruns=%u p50=%lldns p95=%lldns p99=%lldns max=%lldns rcvbuf_drops=%lldpackets\n", argv[1], cpus, rc,
         r.ticks, r.packets_in, r.datagrams_out, r.overruns, (long long)r.p50_ns, (long long)r.p95_ns, (long long)r.p99_ns,
         (long long)r.max_ns, (long long)r.rcvbuf_drops);
  if (argc == 6) printf("backend=%s\n", be);
  if (rc != 0 || r.packets_in < 80) { puts("FAIL: no traffic"); return 1; }
  if (r.p99_ns > 4000000LL) { puts("FAIL: p99 over the 4 ms budget"); return 1; }
  puts("PASS");
  return 0;
}
