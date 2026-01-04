#ifndef TS_DRIVER_H
#define TS_DRIVER_H

#include "tensorscan.h"

struct ts_filter {
  double pid_min;
  double pid_max;
  double only_uid;
  const double *pid_whitelist;
  size_t whitelist_count;
};

/* The core function that OS-specific files must implement */
size_t ts_driver_snapshot(double *out, size_t max_rows, size_t max_cols,
                          double *pid_out, const struct ts_filter *filter,
                          int delta_mode);

/* OS-specific resource cleanup */
void ts_driver_free_thread_resources(void);

/* OS-specific utility functions */
size_t ts_driver_core_count(void);
unsigned long long ts_driver_get_total_cpu_ticks(void);
unsigned long long ts_driver_get_mem_total_bytes(void);
size_t ts_driver_read_comm(pid_t pid, char *out, size_t out_len);
size_t ts_driver_read_cmdline(pid_t pid, char *out, size_t out_len);
size_t ts_driver_read_cgroup(pid_t pid, char *out, size_t out_len);

#endif /* TS_DRIVER_H */
