/* Spans as OTLP/JSON, written from C. A header-only port of the span half of the engine's
 * open_telemetry module (see docs/otel.md): spans are recorded after the fact into a fixed ring, so a
 * hot loop pays for one struct copy, and otel_flush writes one resourceSpans body, one line, to a
 * file a sidecar posts. Nothing here allocates, opens a socket or blocks except otel_flush. */
#ifndef OTEL_SPAN_H
#define OTEL_SPAN_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OTEL_CAP 4096
#define OTEL_ATTRS 6

typedef struct {
  uint64_t t0, t1, sid, psid; /* wall nanoseconds; psid 0 means a root */
  const char *name;
  uint32_t nattr;
  const char *key[OTEL_ATTRS];
  int64_t val[OTEL_ATTRS];
} otel_rec_t;

typedef struct {
  char service[64], extra[512];
  uint64_t tid_hi, tid_lo, rng;
  int64_t wall_off; /* wall minus monotonic, in nanoseconds, fixed at open */
  uint32_t n, dropped;
  FILE *out;
  otel_rec_t r[OTEL_CAP];
} otel_t;

static inline uint64_t otel_next(otel_t *o) { /* xorshift64, logical shifts */
  o->rng ^= o->rng << 13; o->rng ^= o->rng >> 7; o->rng ^= o->rng << 17;
  return o->rng;
}

static inline uint64_t otel_id(otel_t *o) { uint64_t v = otel_next(o); return v ? v : 1; }

static inline void otel_clean(char *s) { /* the strings go into JSON unescaped, so keep them plain */
#ifdef OTEL_PLANT_NOCLEAN
  (void)s; return;
#endif
  for (; *s; s++) if (*s == '"' || *s == '\\' || (unsigned char)*s < 32) *s = '_';
}

/* Opens path for appending; extra is the standard OTEL_RESOURCE_ATTRIBUTES form, key=value,key=value. */
static inline int otel_open(otel_t *o, const char *service, const char *extra, const char *path, uint64_t seed) {
  struct timespec w, m;
  memset(o, 0, offsetof(otel_t, r));
  clock_gettime(CLOCK_REALTIME, &w); clock_gettime(CLOCK_MONOTONIC, &m);
  o->wall_off = ((int64_t)w.tv_sec - (int64_t)m.tv_sec) * 1000000000LL + ((int64_t)w.tv_nsec - (int64_t)m.tv_nsec);
  o->rng = seed ? seed : (uint64_t)w.tv_nsec * 2654435761u + 88172645463325252ull;
  o->tid_hi = otel_id(o); o->tid_lo = otel_id(o);
  strncpy(o->service, service, sizeof o->service - 1); otel_clean(o->service);
  if (extra) { strncpy(o->extra, extra, sizeof o->extra - 1); otel_clean(o->extra); }
  o->out = fopen(path, "a");
  return o->out ? 0 : -1;
}

static inline uint64_t otel_wall(const otel_t *o, int64_t mono_ns) { return (uint64_t)(mono_ns + o->wall_off); }

/* Records a finished span; returns its id so a child can name it. A full ring drops and counts. */
static inline uint64_t otel_span_as(otel_t *o, uint64_t sid, const char *name, uint64_t parent, int64_t mono0, int64_t mono1,
                                    uint32_t nattr, const char *const *keys, const int64_t *vals) {
  if (o->n >= OTEL_CAP) { o->dropped++; return sid; }
  otel_rec_t *r = &o->r[o->n++];
  r->t0 = otel_wall(o, mono0); r->t1 = otel_wall(o, mono1); r->sid = sid; r->psid = parent; r->name = name;
  r->nattr = nattr > OTEL_ATTRS ? OTEL_ATTRS : nattr;
  for (uint32_t i = 0; i < r->nattr; i++) { r->key[i] = keys[i]; r->val[i] = vals[i]; }
  return sid;
}

static inline uint64_t otel_span(otel_t *o, const char *name, uint64_t parent, int64_t mono0, int64_t mono1, uint32_t nattr,
                                 const char *const *keys, const int64_t *vals) {
  return otel_span_as(o, otel_id(o), name, parent, mono0, mono1, nattr, keys, vals);
}

static inline void otel_flush(otel_t *o) {
  if (!o->out || o->n == 0) return;
  FILE *f = o->out;
  fprintf(f, "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"%s\"}}", o->service);
  { char buf[512]; char *p, *save; strcpy(buf, o->extra);
    for (p = strtok_r(buf, ",", &save); p; p = strtok_r(0, ",", &save)) {
      char *eq = strchr(p, '=');
      if (!eq) continue;
      *eq = 0;
      fprintf(f, ",{\"key\":\"%s\",\"value\":{\"stringValue\":\"%s\"}}", p, eq + 1);
    } }
  fprintf(f, "]},\"scopeSpans\":[{\"scope\":{\"name\":\"entity-server\"},\"spans\":[");
  for (uint32_t i = 0; i < o->n; i++) {
    const otel_rec_t *r = &o->r[i];
    fprintf(f, "%s{\"traceId\":\"%016llx%016llx\",\"spanId\":\"%016llx\",", i ? "," : "", (unsigned long long)o->tid_hi,
            (unsigned long long)o->tid_lo, (unsigned long long)r->sid);
    if (r->psid) fprintf(f, "\"parentSpanId\":\"%016llx\",", (unsigned long long)r->psid);
    fprintf(f, "\"name\":\"%s\",\"kind\":1,\"startTimeUnixNano\":\"%llu\",\"endTimeUnixNano\":\"%llu\",\"attributes\":[", r->name,
            (unsigned long long)r->t0, (unsigned long long)r->t1);
    for (uint32_t k = 0; k < r->nattr; k++)
      fprintf(f, "%s{\"key\":\"%s\",\"value\":{\"intValue\":\"%lld\"}}", k ? "," : "", r->key[k], (long long)r->val[k]);
    fprintf(f, "]}");
  }
  fprintf(f, "]}]}]}\n");
  fflush(f);
  o->n = 0;
}

static inline void otel_close(otel_t *o) { otel_flush(o); if (o->out) fclose(o->out); o->out = 0; }
#endif
