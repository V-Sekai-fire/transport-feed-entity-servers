/* Runtime interface shared by the transport, the SQLite access layer and the generated
 * application code (gen/app_gen.c). Everything is compiled as one translation unit
 * (runtime/server.c), so these are static definitions rather than a linked ABI. */
#ifndef RT_H
#define RT_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#ifndef SQLITE_AMALGAMATION   /* the amalgamation, included first, defines the same names */
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef unsigned long long u64;
typedef long long i64;
#endif

/* ---- fatal path ------------------------------------------------------------------------- */
/* Standalone: print and exit(1), as before. Hosted (NIF or C node): the host sets rt_fatal_jmp on the
 * thread that runs the server, and a fatal error returns there with rt_fatal_msg filled in, so no
 * runtime call ends the host's process. */
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
static _Thread_local jmp_buf *rt_fatal_jmp;
static _Thread_local char rt_fatal_msg[256];
static void rt_fatal(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void rt_fatal(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  (void)vsnprintf(rt_fatal_msg, sizeof rt_fatal_msg, fmt, ap);
  va_end(ap);
  if (rt_fatal_jmp != NULL) {
    longjmp(*rt_fatal_jmp, 1);
  } else {
    (void)fprintf(stderr, "fatal: %s\n", rt_fatal_msg);
    exit(1);
  }
}
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

/* ---- requests --------------------------------------------------------------------------- */

enum { M_OTHER = 0, M_GET = 1, M_POST = 2 };

typedef struct {
  u8 method;
  u8 close;            /* client asked for Connection: close (or HTTP/1.0 without keep-alive) */
  u8 has_auth;
  const u8 *path; u32 path_len;      /* without the query string */
  const u8 *auth; u32 auth_len;      /* Authorization header value */
  const u8 *body; u32 body_len;
} req_t;

/* ---- responses -------------------------------------------------------------------------- */

/* A response is either a static constant (generated) or bytes in an owned buffer. The owned
 * buffer reserves HDR_ROOM bytes in front of the body so the header can be written right
 * before it once the body length is known. */
#define HDR_ROOM 96

typedef struct obuf {
  struct obuf *next;   /* per-connection send queue */
  const u8 *data;      /* first byte to send */
  u32 len;             /* bytes to send */
  u32 cap;             /* capacity of mem (0 = static data, nothing to free) */
  u8 *mem;             /* owned allocation (HDR_ROOM + body capacity) */
} obuf;

typedef struct {
  u8 *p, *end;         /* write cursor into the body area */
  u8 *start;           /* first body byte */
  obuf *b;
} out_t;

/* ---- jobs ------------------------------------------------------------------------------- */

typedef struct job {
  u8 kind;             /* generated job kinds; 0 = response already decided */
  u8 is_write;
  u8 close_after;
  u32 conn;            /* global connection index */
  u32 gen;             /* connection generation */
  i64 id;              /* post id argument */
  i64 uid;             /* authenticated user id */
  const u8 *name; u32 name_len;   /* authenticated username (decoded, JSON-ready bytes) */
  u8 *text; u32 text_len;         /* decoded + trimmed post body (owned, freed after the batch) */
  obuf *resp;
} job_t;

#endif
