/* io_uring syscall layer for the Lean event loop. Policy (generations, batching, parsing,
 * COMMIT-before-send) lives in Lean (FeedServer/Server.lean); this file only moves bytes.
 * Completions come back packed: [ud u64][res i32][len u32][len data bytes]...
 * ud = op<<56 | tag<<32 | slot. Slots are owned here: a slot is reused only after every
 * operation in flight on it has completed. Linux only; elsewhere every call reports failure. */
#include <lean/lean.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <liburing.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <time.h>

#define MAXC 65536
/* main.rs BUF_SIZE / BUF_COUNT: one provided-buffer ring (group 0); idle connections own no receive memory. */
#define BUF_SIZE 2048
#define BUF_COUNT 1024
enum { OP_ACCEPT = 1, OP_RECV = 2, OP_SEND = 3 };
static struct io_uring_buf_ring *br;
static unsigned char *bufmem;

static struct io_uring ring;
static int lfd = -1;
static int fds[MAXC], inflight[MAXC], closing[MAXC], freeq[MAXC], nfree;
static unsigned char *sbuf[MAXC];

static uint64_t ud(int op, uint32_t tag, uint32_t slot) { return ((uint64_t)op << 56) | ((uint64_t)tag << 32) | slot; }

static void release(uint32_t s) {
  if (closing[s] && inflight[s] == 0) {
    close(fds[s]); fds[s] = -1; closing[s] = 0;
    free(sbuf[s]); sbuf[s] = 0;
    freeq[nfree++] = (int)s;
  }
}

LEAN_EXPORT lean_obj_res lean_ring_start(b_lean_obj_arg host, uint32_t port, lean_obj_arg w) {
  struct io_uring_params p; memset(&p, 0, sizeof p);
  if (io_uring_queue_init_params(4096, &ring, &p) < 0) return lean_io_result_mk_ok(lean_mk_string("io_uring_queue_init failed"));
  int berr = 0;
  br = io_uring_setup_buf_ring(&ring, BUF_COUNT, 0, 0, &berr);
  if (!br) return lean_io_result_mk_ok(lean_mk_string("provided buffer ring registration failed"));
  bufmem = malloc((size_t)BUF_COUNT * BUF_SIZE);
  for (int i = 0; i < BUF_COUNT; i++)
    io_uring_buf_ring_add(br, bufmem + (size_t)i * BUF_SIZE, BUF_SIZE, (unsigned short)i, io_uring_buf_ring_mask(BUF_COUNT), i);
  io_uring_buf_ring_advance(br, BUF_COUNT);
  lfd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  int one = 1;
  setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  setsockopt(lfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons((uint16_t)port);
  if (inet_pton(AF_INET, lean_string_cstr(host), &a.sin_addr) != 1) return lean_io_result_mk_ok(lean_mk_string("HOST must be an IPv4 address"));
  if (bind(lfd, (struct sockaddr *)&a, sizeof a) < 0 || listen(lfd, 65535) < 0) return lean_io_result_mk_ok(lean_mk_string("bind/listen failed"));
  for (int i = MAXC - 1; i >= 0; i--) { fds[i] = -1; freeq[nfree++] = i; }
  return lean_io_result_mk_ok(lean_mk_string(""));
}

LEAN_EXPORT lean_obj_res lean_ring_arm_accept(lean_obj_arg w) {
  struct io_uring_sqe *e = io_uring_get_sqe(&ring);
  if (!e) return lean_io_result_mk_ok(lean_box(0));
  io_uring_prep_accept(e, lfd, 0, 0, SOCK_CLOEXEC);
  io_uring_sqe_set_data64(e, ud(OP_ACCEPT, 0, 0));
  return lean_io_result_mk_ok(lean_box(1));
}

LEAN_EXPORT lean_obj_res lean_ring_arm_recv(uint32_t slot, uint32_t tag, lean_obj_arg w) {
  if (slot >= MAXC || fds[slot] < 0 || closing[slot]) return lean_io_result_mk_ok(lean_box(0));
  struct io_uring_sqe *e = io_uring_get_sqe(&ring);
  if (!e) return lean_io_result_mk_ok(lean_box(0));
  /* main.rs arm_recv: one multishot receive per connection, buffers picked when data arrives. */
  io_uring_prep_recv_multishot(e, fds[slot], NULL, 0, 0);
  e->flags |= IOSQE_BUFFER_SELECT;
  e->buf_group = 0;
  io_uring_sqe_set_data64(e, ud(OP_RECV, tag, slot));
  inflight[slot]++;
  return lean_io_result_mk_ok(lean_box(1));
}

/* Sends bytes [off, size) of `data`. The copy is owned here until the completion. */
LEAN_EXPORT lean_obj_res lean_ring_send(uint32_t slot, uint32_t tag, b_lean_obj_arg data, size_t off, lean_obj_arg w) {
  size_t n = lean_sarray_size(data);
  if (slot >= MAXC || fds[slot] < 0 || closing[slot] || off >= n) return lean_io_result_mk_ok(lean_box(0));
  struct io_uring_sqe *e = io_uring_get_sqe(&ring);
  if (!e) return lean_io_result_mk_ok(lean_box(0));
  free(sbuf[slot]);
  sbuf[slot] = malloc(n - off);
  memcpy(sbuf[slot], lean_sarray_cptr(data) + off, n - off);
  io_uring_prep_send(e, fds[slot], sbuf[slot], n - off, MSG_NOSIGNAL);
  io_uring_sqe_set_data64(e, ud(OP_SEND, tag, slot));
  inflight[slot]++;
  return lean_io_result_mk_ok(lean_box(1));
}

/* Shut the connection down; the slot is freed once its in-flight operations complete. */
LEAN_EXPORT lean_obj_res lean_ring_close(uint32_t slot, lean_obj_arg w) {
  if (slot < MAXC && fds[slot] >= 0 && !closing[slot]) {
    closing[slot] = 1;
    shutdown(fds[slot], SHUT_RDWR);
    release(slot);
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_ring_wait(uint64_t timeout_ns, lean_obj_arg w) {
  struct __kernel_timespec ts = { 0, (long long)timeout_ns };
  struct io_uring_cqe *cqe;
  io_uring_submit_and_wait_timeout(&ring, &cqe, 1, &ts, NULL);
  size_t len = 0, cap = 4096;
  unsigned char *b = malloc(cap);
  unsigned head, count = 0, nback = 0;
  io_uring_for_each_cqe(&ring, head, cqe) {
    count++;
    int bid = -1;
    uint64_t u = io_uring_cqe_get_data64(cqe);
    int op = (int)(u >> 56); uint32_t slot = (uint32_t)u; int32_t res = cqe->res;
    uint32_t dlen = 0; const unsigned char *d = 0;
    if (op == OP_ACCEPT && res >= 0) {
      if (nfree == 0) { close(res); res = -1; }
      else {
        int s = freeq[--nfree];
        fds[s] = res; inflight[s] = 0; closing[s] = 0;
        int one = 1; setsockopt(res, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        res = s;
      }
    } else if (op == OP_RECV) {
      /* a multishot receive stays in flight until a completion arrives without IORING_CQE_F_MORE */
      if (!(cqe->flags & IORING_CQE_F_MORE)) inflight[slot]--;
      if (cqe->flags & IORING_CQE_F_BUFFER) {
        bid = (int)(cqe->flags >> IORING_CQE_BUFFER_SHIFT);
        if (res > 0 && !closing[slot]) { d = bufmem + (size_t)bid * BUF_SIZE; dlen = (uint32_t)res; }
      }
    } else if (op == OP_SEND) {
      inflight[slot]--;
    }
    uint32_t fl = cqe->flags;
    if (len + 20 + dlen > cap) { cap = (len + 20 + dlen) * 2; b = realloc(b, cap); }
    memcpy(b + len, &u, 8); memcpy(b + len + 8, &res, 4); memcpy(b + len + 12, &dlen, 4); memcpy(b + len + 16, &fl, 4);
    if (dlen) memcpy(b + len + 20, d, dlen);
    len += 20 + dlen;
    /* the bytes are copied into the record; the provided buffer goes straight back to the ring */
    if (bid >= 0) io_uring_buf_ring_add(br, bufmem + (size_t)bid * BUF_SIZE, BUF_SIZE, (unsigned short)bid, io_uring_buf_ring_mask(BUF_COUNT), nback++);
    if (op != OP_ACCEPT) release(slot);
  }
  io_uring_cq_advance(&ring, count);
  if (nback) io_uring_buf_ring_advance(br, nback);
  lean_object *a = lean_alloc_sarray(1, len, len);
  memcpy(lean_sarray_cptr(a), b, len);
  free(b);
  return lean_io_result_mk_ok(a);
}

LEAN_EXPORT lean_obj_res lean_wall_ms(lean_obj_arg w) {
  struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
  return lean_io_result_mk_ok(lean_box_uint64((uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000));
}
#else
LEAN_EXPORT lean_obj_res lean_ring_start(b_lean_obj_arg h, uint32_t p, lean_obj_arg w) { return lean_io_result_mk_ok(lean_mk_string("io_uring needs Linux")); }
LEAN_EXPORT lean_obj_res lean_ring_arm_accept(lean_obj_arg w) { return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res lean_ring_arm_recv(uint32_t s, uint32_t t, lean_obj_arg w) { return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res lean_ring_send(uint32_t s, uint32_t t, b_lean_obj_arg d, size_t o, lean_obj_arg w) { return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res lean_ring_close(uint32_t s, lean_obj_arg w) { return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res lean_ring_wait(uint64_t t, lean_obj_arg w) { return lean_io_result_mk_ok(lean_alloc_sarray(1, 0, 0)); }
#include <time.h>
LEAN_EXPORT lean_obj_res lean_wall_ms(lean_obj_arg w) {
  struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
  return lean_io_result_mk_ok(lean_box_uint64((uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000));
}
#endif
