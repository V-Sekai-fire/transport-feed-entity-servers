/* Lean-ABI wrappers over the unmodified td_* shim (csrc/shim.c, the SQLite side).
 * Conventions: statuses come back as Nat = shim result + 1 (0 = error, 1 = absent/none, 2 = ok/found);
 * ids travel as UInt64; blobs as ByteArray. */
#include <lean/lean.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef long long i64;
extern int td_open(const char *path, char *err, int n);
extern int td_begin(void);
extern int td_commit(void);
extern void td_tick(void);
extern int td_writes_held(void);
extern void *td_cursor(int i);
extern int td_seek(void *c, i64 id);
extern int td_seek_ge(void *c, i64 k);
extern int td_first(void *c);
extern int td_next(void *c);
extern const unsigned char *td_payload(void *c, uint32_t *len);
extern int td_count_likes(void *c, i64 lo, i64 hi, unsigned *n);
extern int td_insert_post(i64 uid, const char *body, int len, i64 *id, char *created, int *clen);
extern int td_insert_like(i64 uid, i64 pid);
extern int td_health(char *err, int n);
extern int td_feed_sql_step(i64 *id, const unsigned char **body, int *blen, const unsigned char **ca,
                            int *clen, const unsigned char **author, int *alen, i64 *likes);

static lean_obj_res nat_res(int r) { return lean_io_result_mk_ok(lean_box((size_t)(r + 1))); }

static lean_obj_res bytes(const void *p, size_t n) {
  lean_object *a = lean_alloc_sarray(1, n, n);
  if (n) memcpy(lean_sarray_cptr(a), p, n);
  return a;
}

LEAN_EXPORT lean_obj_res lean_td_open(b_lean_obj_arg path, lean_obj_arg w) {
  char err[512] = {0};
  int rc = td_open(lean_string_cstr(path), err, sizeof err);
  return lean_io_result_mk_ok(lean_mk_string(rc == 0 ? "" : (err[0] ? err : "open failed")));
}
LEAN_EXPORT lean_obj_res lean_td_begin(lean_obj_arg w) { return lean_io_result_mk_ok(lean_box(td_begin() == 0)); }
LEAN_EXPORT lean_obj_res lean_td_commit(lean_obj_arg w) { return lean_io_result_mk_ok(lean_box(td_commit() == 0)); }
LEAN_EXPORT lean_obj_res lean_td_tick(lean_obj_arg w) { td_tick(); return lean_io_result_mk_ok(lean_box(0)); }
LEAN_EXPORT lean_obj_res lean_td_writes_held(lean_obj_arg w) { return lean_io_result_mk_ok(lean_box(td_writes_held() != 0)); }

LEAN_EXPORT lean_obj_res lean_td_seek(uint32_t cur, uint64_t id, lean_obj_arg w) { return nat_res(td_seek(td_cursor((int)cur), (i64)id)); }
LEAN_EXPORT lean_obj_res lean_td_seek_ge(uint32_t cur, uint64_t k, lean_obj_arg w) { return nat_res(td_seek_ge(td_cursor((int)cur), (i64)k)); }
LEAN_EXPORT lean_obj_res lean_td_first(uint32_t cur, lean_obj_arg w) { return nat_res(td_first(td_cursor((int)cur))); }
LEAN_EXPORT lean_obj_res lean_td_next(uint32_t cur, lean_obj_arg w) { return nat_res(td_next(td_cursor((int)cur))); }

/* Empty array = no payload; otherwise byte 1 followed by the record (one copy). */
LEAN_EXPORT lean_obj_res lean_td_payload(uint32_t cur, lean_obj_arg w) {
  uint32_t n = 0;
  const unsigned char *p = td_payload(td_cursor((int)cur), &n);
  if (!p) return lean_io_result_mk_ok(bytes(0, 0));
  lean_object *a = lean_alloc_sarray(1, (size_t)n + 1, (size_t)n + 1);
  lean_sarray_cptr(a)[0] = 1;
  if (n) memcpy(lean_sarray_cptr(a) + 1, p, n);
  return lean_io_result_mk_ok(a);
}

/* [status+1][u32 LE count] for lo <= post_id <= hi (at most 513 ids). */
LEAN_EXPORT lean_obj_res lean_td_count_likes(uint32_t cur, uint64_t lo, uint64_t hi, lean_obj_arg w) {
  size_t n = (size_t)((i64)hi - (i64)lo + 1);
  if ((i64)hi < (i64)lo || n > 513) { unsigned char e = 0; return lean_io_result_mk_ok(bytes(&e, 1)); }
  unsigned *cnt = calloc(n, sizeof(unsigned));
  int rc = td_count_likes(td_cursor((int)cur), (i64)lo, (i64)hi, cnt);
  lean_object *a = lean_alloc_sarray(1, 1 + 4 * n, 1 + 4 * n);
  unsigned char *o = lean_sarray_cptr(a);
  o[0] = (unsigned char)(rc + 1);
  for (size_t i = 0; i < n; i++) for (int k = 0; k < 4; k++) o[1 + 4 * i + k] = (cnt[i] >> (8 * k)) & 0xff;
  free(cnt);
  return lean_io_result_mk_ok(a);
}

/* Empty = error; else [1][id u64 LE][created bytes]. */
LEAN_EXPORT lean_obj_res lean_td_insert_post(uint64_t uid, b_lean_obj_arg body, lean_obj_arg w) {
  i64 id = 0; char created[64]; int cl = 0;
  if (td_insert_post((i64)uid, (const char *)lean_sarray_cptr(body), (int)lean_sarray_size(body), &id, created, &cl) != 0)
    return lean_io_result_mk_ok(bytes(0, 0));
  lean_object *a = lean_alloc_sarray(1, 9 + (size_t)cl, 9 + (size_t)cl);
  unsigned char *o = lean_sarray_cptr(a);
  o[0] = 1;
  for (int k = 0; k < 8; k++) o[1 + k] = ((uint64_t)id >> (8 * k)) & 0xff;
  memcpy(o + 9, created, (size_t)cl);
  return lean_io_result_mk_ok(a);
}
LEAN_EXPORT lean_obj_res lean_td_insert_like(uint64_t uid, uint64_t pid, lean_obj_arg w) { return nat_res(td_insert_like((i64)uid, (i64)pid)); }

LEAN_EXPORT lean_obj_res lean_td_health(lean_obj_arg w) {
  char err[512] = {0};
  int rc = td_health(err, sizeof err);
  return lean_io_result_mk_ok(lean_mk_string(rc == 0 ? "" : (err[0] ? err : "health failed")));
}

static void put(unsigned char **b, size_t *len, size_t *cap, const void *p, size_t n) {
  if (*len + n > *cap) { *cap = (*len + n) * 2; *b = realloc(*b, *cap); }
  memcpy(*b + *len, p, n);
  *len += n;
}
static void put_u(unsigned char **b, size_t *len, size_t *cap, uint64_t v, int nb) {
  unsigned char t[8];
  for (int k = 0; k < nb; k++) t[k] = (v >> (8 * k)) & 0xff;
  put(b, len, cap, t, (size_t)nb);
}

/* Reference SQL feed. Empty = error; else [1] then rows: id u64, likes u64, (u32 len + bytes) x3 (body, created, author). */
LEAN_EXPORT lean_obj_res lean_td_feed_sql(lean_obj_arg w) {
  size_t len = 0, cap = 1024;
  unsigned char *b = malloc(cap);
  b[len++] = 1;
  for (;;) {
    i64 id = 0, likes = 0; const unsigned char *bd = 0, *ca = 0, *au = 0; int bl = 0, cl = 0, al = 0;
    int r = td_feed_sql_step(&id, &bd, &bl, &ca, &cl, &au, &al, &likes);
    if (r == 0) break;
    if (r < 0) { free(b); return lean_io_result_mk_ok(bytes(0, 0)); }
    put_u(&b, &len, &cap, (uint64_t)id, 8); put_u(&b, &len, &cap, (uint64_t)likes, 8);
    put_u(&b, &len, &cap, (uint32_t)bl, 4); if (bl) put(&b, &len, &cap, bd, (size_t)bl);
    put_u(&b, &len, &cap, (uint32_t)cl, 4); if (cl) put(&b, &len, &cap, ca, (size_t)cl);
    put_u(&b, &len, &cap, (uint32_t)al, 4); if (al) put(&b, &len, &cap, au, (size_t)al);
  }
  lean_object *a = bytes(b, len);
  free(b);
  return lean_io_result_mk_ok(a);
}

#ifdef __linux__
/* Lean's bundled glibc predates fcntl64, which objects built against the system glibc reference. */
#include <stdarg.h>
#include <unistd.h>
#include <sys/syscall.h>
int fcntl64(int fd, int cmd, ...) {
  va_list ap; va_start(ap, cmd);
  long arg = va_arg(ap, long);
  va_end(ap);
  return (int)syscall(SYS_fcntl, fd, cmd, arg);
}
#endif
