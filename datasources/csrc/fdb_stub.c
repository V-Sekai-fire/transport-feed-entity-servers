/* Built instead of datasources/store/fdb_vfs.c where the FoundationDB client headers are absent (e.g. a Mac
 * checkout). It defines the two entry points csrc/shim.c calls, and both refuse, so an "fdb:" path
 * fails to open with an error instead of the build failing to link. */
#include "weft_fdb_vfs.h"
int weft_fdb_start(const char *cluster_file) { (void)cluster_file; return -1; }
int weft_vfs_register(int make_default) { (void)make_default; return -1; }
void weft_fdb_stop(void) {}
