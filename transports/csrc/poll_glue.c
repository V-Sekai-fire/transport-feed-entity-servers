/* poll(2) socket layer for the Lean event loop. Same job as ring_glue.c and the same packed completions:
 * [ud u64][res i32][len u32][flags u32][len data bytes]...
 * ud = op<<56 | tag<<32 | slot. Policy (generations, batching, parsing, COMMIT-before-send) lives in
 * Lean (FeedServer/Server.lean); this file only moves bytes.
 * Readiness is turned into completions: a receive stays armed and reports FLAG_MORE until it ends (EOF or
 * error), a send is one send() call that reports the bytes taken (Lean resends the rest), accept is one-shot.
 * Slots are owned here: a slot is reused only after every operation in flight on it has completed.
 * POSIX and Winsock (_WIN32 branch is written but not yet compiled). */
#include <lean/lean.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#define NET_CLOSE(s) closesocket(s)
#define NET_ERR() WSAGetLastError()
#define NET_POLL(a, n, ms) WSAPoll((a), (ULONG)(n), (ms))
#define NET_SLEEP_MS(ms) Sleep((DWORD)(ms))
#define SEND_FLAGS 0
static int would_block(int e) { return e == WSAEWOULDBLOCK || e == WSAEINTR; }
static int set_nonblock(sock_t s) { u_long one = 1; return ioctlsocket(s, FIONBIO, &one); }
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int sock_t;
#define NET_CLOSE(s) close(s)
#define NET_ERR() errno
#define NET_POLL(a, n, ms) poll((a), (nfds_t)(n), (ms))
#define NET_SLEEP_MS(ms) usleep((useconds_t)(ms) * 1000)
#ifdef MSG_NOSIGNAL
#define SEND_FLAGS MSG_NOSIGNAL
#else
#define SEND_FLAGS 0
#endif
static int would_block(int e) { return e == EAGAIN || e == EWOULDBLOCK || e == EINTR; }
static int set_nonblock(sock_t s) {
  int f = fcntl(s, F_GETFL, 0);
  if (f < 0 || fcntl(s, F_SETFL, f | O_NONBLOCK) < 0) return -1;
  fcntl(s, F_SETFD, FD_CLOEXEC);
  return 0;
}
#endif
#include <time.h>
#define INVALID ((sock_t)-1)
#define MAXC 65536
#define BUF_SIZE 2048 /* one receive is at most this many bytes, as the ring's provided buffers were */
#define FLAG_MORE 2u  /* IORING_CQE_F_MORE: the receive is still armed */
#define ERR_CANCELED (-125)
enum { OP_ACCEPT = 1, OP_RECV = 2, OP_SEND = 3 };

static sock_t lfd = INVALID;
static int accept_armed;
static sock_t fds[MAXC];
static int inflight[MAXC], closing[MAXC], recv_armed[MAXC], send_pending[MAXC], freeq[MAXC], nfree, hi;
static uint32_t rtag[MAXC], stag[MAXC];
static unsigned char *sbuf[MAXC];
static size_t slen[MAXC];
static unsigned char rscratch[BUF_SIZE];
static struct pollfd pf[MAXC + 1];
static int who[MAXC + 1];

static uint64_t ud(int op, uint32_t tag, uint32_t slot) { return ((uint64_t)op << 56) | ((uint64_t)tag << 32) | slot; }

/* the packed output of one wait call */
static unsigned char *ob;
static size_t olen, ocap;
static void emit(uint64_t u, int32_t res, const unsigned char *d, uint32_t dlen, uint32_t fl) {
  if (olen + 20 + dlen > ocap) { ocap = (olen + 20 + dlen) * 2; ob = realloc(ob, ocap); }
  memcpy(ob + olen, &u, 8); memcpy(ob + olen + 8, &res, 4); memcpy(ob + olen + 12, &dlen, 4); memcpy(ob + olen + 16, &fl, 4);
  if (dlen) memcpy(ob + olen + 20, d, dlen);
  olen += 20 + dlen;
}

static void release(uint32_t s) {
  if (closing[s] && inflight[s] == 0) {
    NET_CLOSE(fds[s]); fds[s] = INVALID; closing[s] = 0; recv_armed[s] = 0; send_pending[s] = 0;
    free(sbuf[s]); sbuf[s] = 0;
    freeq[nfree++] = (int)s;
  }
}

LEAN_EXPORT lean_obj_res lean_net_start(b_lean_obj_arg host, uint32_t port, lean_obj_arg w) {
#ifdef _WIN32
  WSADATA wd;
  if (WSAStartup(MAKEWORD(2, 2), &wd) != 0) return lean_io_result_mk_ok(lean_mk_string("WSAStartup failed"));
#endif
  lfd = socket(AF_INET, SOCK_STREAM, 0);
  if (lfd == INVALID) return lean_io_result_mk_ok(lean_mk_string("socket failed"));
#ifndef _WIN32
  int one = 1;
  setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, (const void *)&one, sizeof one); /* on Windows it allows port hijack: left out */
#endif
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, lean_string_cstr(host), &a.sin_addr) != 1) return lean_io_result_mk_ok(lean_mk_string("HOST must be an IPv4 address"));
  if (bind(lfd, (struct sockaddr *)&a, sizeof a) < 0 || listen(lfd, 1024) < 0) return lean_io_result_mk_ok(lean_mk_string("bind/listen failed"));
  if (set_nonblock(lfd) < 0) return lean_io_result_mk_ok(lean_mk_string("nonblocking listener failed"));
  for (int i = MAXC - 1; i >= 0; i--) { fds[i] = INVALID; freeq[nfree++] = i; }
  return lean_io_result_mk_ok(lean_mk_string(""));
}

LEAN_EXPORT lean_obj_res lean_net_arm_accept(lean_obj_arg w) {
  accept_armed = 1;
  return lean_io_result_mk_ok(lean_box(1));
}

LEAN_EXPORT lean_obj_res lean_net_arm_recv(uint32_t slot, uint32_t tag, lean_obj_arg w) {
  if (slot >= MAXC || fds[slot] == INVALID || closing[slot]) return lean_io_result_mk_ok(lean_box(0));
  if (!recv_armed[slot]) { recv_armed[slot] = 1; inflight[slot]++; }
  rtag[slot] = tag;
  return lean_io_result_mk_ok(lean_box(1));
}

/* Sends bytes [off, size) of `data` in one send() call at the next wait. The copy is owned here until the completion. */
LEAN_EXPORT lean_obj_res lean_net_send(uint32_t slot, uint32_t tag, b_lean_obj_arg data, size_t off, lean_obj_arg w) {
  size_t n = lean_sarray_size(data);
  if (slot >= MAXC || fds[slot] == INVALID || closing[slot] || send_pending[slot] || off >= n) return lean_io_result_mk_ok(lean_box(0));
  free(sbuf[slot]);
  sbuf[slot] = malloc(n - off);
  memcpy(sbuf[slot], lean_sarray_cptr(data) + off, n - off);
  slen[slot] = n - off; stag[slot] = tag; send_pending[slot] = 1; inflight[slot]++;
  return lean_io_result_mk_ok(lean_box(1));
}

/* Shut the connection down; the slot is freed once its operations have been reported as complete. */
LEAN_EXPORT lean_obj_res lean_net_close(uint32_t slot, lean_obj_arg w) {
  if (slot < MAXC && fds[slot] != INVALID && !closing[slot]) {
    closing[slot] = 1;
#ifdef _WIN32
    shutdown(fds[slot], SD_BOTH);
#else
    shutdown(fds[slot], SHUT_RDWR);
#endif
    release(slot);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_net_wait(uint64_t timeout_ns, lean_obj_arg w) {
  olen = 0;
  int cancelled = 0;
  /* a closing slot reports its armed receive (EOF) and pending send (canceled) so its accounting balances */
  for (int s = 0; s < hi; s++) {
    if (fds[s] == INVALID || !closing[s] || inflight[s] == 0) continue;
    if (recv_armed[s]) { emit(ud(OP_RECV, rtag[s], (uint32_t)s), 0, 0, 0, 0); recv_armed[s] = 0; inflight[s]--; cancelled = 1; }
    if (send_pending[s]) { emit(ud(OP_SEND, stag[s], (uint32_t)s), ERR_CANCELED, 0, 0, 0); send_pending[s] = 0; inflight[s]--; cancelled = 1; }
    release((uint32_t)s);
  }
  int n = 0;
  if (accept_armed) { pf[n].fd = lfd; pf[n].events = POLLIN; pf[n].revents = 0; who[n++] = -1; }
  for (int s = 0; s < hi; s++) {
    if (fds[s] == INVALID || closing[s]) continue;
    short ev = (short)((recv_armed[s] ? POLLIN : 0) | (send_pending[s] ? POLLOUT : 0));
    if (!ev) continue;
    pf[n].fd = fds[s]; pf[n].events = ev; pf[n].revents = 0; who[n++] = s;
  }
  uint64_t ms64 = (timeout_ns + 999999ULL) / 1000000ULL; /* round up: 1 ns must not become a busy spin */
  int ms = cancelled ? 0 : (ms64 > (uint64_t)INT_MAX ? INT_MAX : (int)ms64);
  if (n > 0) NET_POLL(pf, n, ms);
  else if (ms > 0) NET_SLEEP_MS(ms);
  for (int i = 0; i < n; i++) {
    short re = pf[i].revents;
    if (!re) continue;
    if (who[i] < 0) {
      sock_t c = accept(lfd, 0, 0);
      if (c == INVALID) continue; /* spurious readiness: stay armed */
      accept_armed = 0;
      if (nfree == 0 || set_nonblock(c) < 0) { NET_CLOSE(c); emit(ud(OP_ACCEPT, 0, 0), -1, 0, 0, 0); continue; }
      int s = freeq[--nfree];
      fds[s] = c; inflight[s] = 0; closing[s] = 0; recv_armed[s] = 0; send_pending[s] = 0;
      if (s >= hi) hi = s + 1;
      int one = 1;
      setsockopt(c, IPPROTO_TCP, TCP_NODELAY, (const void *)&one, sizeof one);
#ifdef SO_NOSIGPIPE
      setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, (const void *)&one, sizeof one);
#endif
      emit(ud(OP_ACCEPT, 0, 0), s, 0, 0, 0);
      continue;
    }
    uint32_t s = (uint32_t)who[i];
    if (recv_armed[s] && (re & (POLLIN | POLLHUP | POLLERR))) {
      int r = (int)recv(fds[s], (char *)rscratch, BUF_SIZE, 0);
      if (r > 0) emit(ud(OP_RECV, rtag[s], s), r, rscratch, (uint32_t)r, FLAG_MORE);
      else if (r == 0 || !would_block(NET_ERR())) {
        emit(ud(OP_RECV, rtag[s], s), r == 0 ? 0 : -NET_ERR(), 0, 0, 0);
        recv_armed[s] = 0; inflight[s]--;
      }
    }
    if (send_pending[s] && (re & (POLLOUT | POLLHUP | POLLERR))) {
      int r = (int)send(fds[s], (const char *)sbuf[s], (int)slen[s], SEND_FLAGS);
      if (r >= 0 || !would_block(NET_ERR())) {
        emit(ud(OP_SEND, stag[s], s), r >= 0 ? r : -NET_ERR(), 0, 0, 0);
        send_pending[s] = 0; inflight[s]--;
      }
    }
    release(s);
  }
  lean_object *a = lean_alloc_sarray(1, olen, olen);
  if (olen) memcpy(lean_sarray_cptr(a), ob, olen);
  return lean_io_result_mk_ok(a);
}

LEAN_EXPORT lean_obj_res lean_net_wall_ms(lean_obj_arg w) {
#ifdef _WIN32
  FILETIME ft; GetSystemTimeAsFileTime(&ft);
  uint64_t t = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime; /* 100 ns ticks since 1601 */
  return lean_io_result_mk_ok(lean_box_uint64(t / 10000ULL - 11644473600000ULL));
#else
  struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
  return lean_io_result_mk_ok(lean_box_uint64((uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000));
#endif
}
