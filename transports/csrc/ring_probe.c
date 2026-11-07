/* Probe: can this machine create an io_uring? Raw io_uring_setup syscalls, no liburing.
 * Reports; never fails on a block, because a block is itself the finding. Exit 1 only when
 * the control (entries=0 must give EINVAL) does not behave, since then the probe is not
 * reporting what the kernel said. Linux only. */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#ifdef __linux__
#include <errno.h>
#include <linux/io_uring.h>
#include <sys/syscall.h>

static const char *ename(int e) {
  switch (e) {
  case EPERM: return "EPERM";
  case EACCES: return "EACCES";
  case ENOSYS: return "ENOSYS";
  case EINVAL: return "EINVAL";
  case ENOMEM: return "ENOMEM";
  case EMFILE: return "EMFILE";
  default: return "other";
  }
}
static void proc_line(const char *path, const char *key) {
  FILE *f = fopen(path, "r");
  char l[256];
  if (!f) { printf("%s: unreadable\n", path); return; }
  while (fgets(l, sizeof l, f)) {
    if (!key || strncmp(l, key, strlen(key)) == 0) { l[strcspn(l, "\n")] = 0; printf("%s %s\n", key ? "" : path, l); break; }
  }
  fclose(f);
}
static int setup(const char *label, unsigned entries, unsigned flags) {
  struct io_uring_params p;
  memset(&p, 0, sizeof p);
  p.flags = flags;
  long fd = syscall(__NR_io_uring_setup, entries, &p);
  int e = errno;
  if (fd >= 0) {
    printf("io_uring_setup %s entries=%u: ok fd=%ld sq_entries=%u cq_entries=%u features=0x%x\n", label, entries, fd, p.sq_entries, p.cq_entries, p.features);
    close((int)fd);
    return 0;
  }
  printf("io_uring_setup %s entries=%u: failed errno=%d (%s)\n", label, entries, e, ename(e));
  return e;
}
int main(void) {
  printf("io_uring_disabled (0 on, 1 unprivileged blocked, 2 off for all):\n");
  proc_line("/proc/sys/kernel/io_uring_disabled", 0);
  proc_line("/proc/self/status", "Seccomp:");
  printf("uid=%d\n", (int)getuid());
  int c = setup("control-zero-entries", 0, 0);
  setup("plain", 8, 0);
  setup("sqpoll", 8, IORING_SETUP_SQPOLL);
  if (c != EINVAL) { printf("FAIL: the control did not read back EINVAL, so the probe is not reporting the kernel's answer\n"); return 1; }
  puts("control: entries=0 read back EINVAL");
  return 0;
}
#else
int main(void) { puts("not linux: no io_uring_setup"); return 0; }
#endif
