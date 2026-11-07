/* io_uring send backend for the tick (Linux, liburing). Receive stays on plain syscalls, so the tick clock
 * means the same for every backend. send_all queues one sendmsg per datagram, submits once and returns only
 * after every completion is reaped, so the tick clock stops after the sends and not at submit.
 * Buffers are static and outlive their completions. No heap. */
#define _GNU_SOURCE
#include "entity_tick.h"
#ifdef __linux__
#include <dirent.h>
#include <liburing.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#define SQ_CPU 3
static struct io_uring ring;
static int up;
static struct msghdr mh[ET_MAX_USERS];
static struct iovec iv[ET_MAX_USERS];
static char info[160];

static int start(unsigned flags) {
  struct io_uring_params p;
  memset(&p, 0, sizeof p);
  p.flags = flags;
  p.sq_thread_idle = 1000; /* ms; only read with SQPOLL. Longer than a 15.6 ms tick, so the thread does not sleep */
  if (io_uring_queue_init_params(ET_MAX_USERS, &ring, &p) < 0) return -1;
  up = 1;
  info[0] = 0;
  return 0;
}
static int open_plain(int fd) { (void)fd; return start(0); }

static int sq_tid(void) {
  DIR *d = opendir("/proc/self/task");
  struct dirent *e;
  int tid = -1;
  if (!d) return -1;
  while ((e = readdir(d)) != 0) {
    char path[64], comm[64];
    FILE *f;
    if (e->d_name[0] == '.') continue;
    snprintf(path, sizeof path, "/proc/self/task/%s/comm", e->d_name);
    f = fopen(path, "r");
    if (!f) continue;
    if (fgets(comm, sizeof comm, f) && strncmp(comm, "iou-sqp", 7) == 0) tid = atoi(e->d_name);
    fclose(f);
  }
  closedir(d);
  return tid;
}
static void cpus_of_tid(int tid, char *out, size_t n) {
  char path[64], line[256];
  FILE *f;
  snprintf(out, n, "n/a");
  snprintf(path, sizeof path, "/proc/self/task/%d/status", tid);
  f = fopen(path, "r");
  if (!f) return;
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, "Cpus_allowed_list:", 18) != 0) continue;
    char *v = line + 18;
    while (*v == ' ' || *v == '\t') v++;
    v[strcspn(v, "\n")] = 0;
    snprintf(out, n, "%s", v);
    break;
  }
  fclose(f);
}
/* SQPOLL: the kernel thread starts on the server's vCPU. Move it to the spare vCPU and read back where it
 * runs, because the thread is not ours to taskset at launch. A failed pin is reported, not hidden. */
static int open_sqpoll(int fd) {
  int tid, pr;
  char cpus[64];
  cpu_set_t m;
  (void)fd;
  if (start(IORING_SETUP_SQPOLL) < 0) return -1;
  tid = sq_tid();
  if (tid < 0) { snprintf(info, sizeof info, "sq_thread=not-found"); return 0; }
  CPU_ZERO(&m);
  CPU_SET(SQ_CPU, &m);
  pr = sched_setaffinity(tid, sizeof m, &m);
  cpus_of_tid(tid, cpus, sizeof cpus);
  snprintf(info, sizeof info, "sq_thread_cpus=%s pin_rc=%d", cpus, pr);
  return 0;
}
static int send_all(int fd, const et_out_t *o, int n) {
  int ok = 0, queued = 0;
  for (int i = 0; i < n; i++) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    if (!sqe) break;
    memset(&mh[i], 0, sizeof mh[i]);
    iv[i].iov_base = (void *)o[i].buf;
    iv[i].iov_len = o[i].len;
    mh[i].msg_name = (void *)o[i].to;
    mh[i].msg_namelen = o[i].tolen;
    mh[i].msg_iov = &iv[i];
    mh[i].msg_iovlen = 1;
    io_uring_prep_sendmsg(sqe, fd, &mh[i], 0);
    queued++;
  }
  if (queued == 0 || io_uring_submit(&ring) < 0) return 0;
  for (int i = 0; i < queued; i++) {
    struct io_uring_cqe *cqe;
    if (io_uring_wait_cqe(&ring, &cqe) < 0) break;
    if (cqe->res >= 0) ok++;
    io_uring_cqe_seen(&ring, cqe);
  }
  return ok;
}
static void ring_close(void) {
  if (up) { io_uring_queue_exit(&ring); up = 0; }
}
const et_io_t et_ring_io = {open_plain, send_all, ring_close};
const et_io_t et_sqpoll_io = {open_sqpoll, send_all, ring_close};
const char *et_ring_info(void) { return info; }
#else
typedef int et_ring_unused;
#endif
