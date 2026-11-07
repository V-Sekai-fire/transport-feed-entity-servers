#ifndef ENTITY_CPUS_H
#define ENTITY_CPUS_H
#include <stdio.h>
#include <string.h>
#define ET_CPUS_LEN 256

static inline void et_cpus_allowed(char *out, size_t n) {
  FILE *f = fopen("/proc/self/status", "r");
  char line[256];
  snprintf(out, n, "n/a");
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
#endif
