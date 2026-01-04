#define _POSIX_C_SOURCE 200809L
#include "driver.h"
#include <time.h>
#include <errno.h>
#include <string.h>

size_t ts_snapshot(double *out, size_t max_rows, size_t max_cols,
                    double *pid_out) {
  return ts_driver_snapshot(out, max_rows, max_cols, pid_out, NULL, 0);
}

size_t ts_snapshot_filtered(double *out, size_t max_rows, size_t max_cols,
                             double *pid_out, double pid_min, double pid_max,
                             const double *pid_whitelist,
                             size_t whitelist_count, double only_uid) {
  struct ts_filter filter;
  filter.pid_min = pid_min;
  filter.pid_max = pid_max;
  filter.only_uid = only_uid;
  filter.pid_whitelist = pid_whitelist;
  filter.whitelist_count = whitelist_count;

  return ts_driver_snapshot(out, max_rows, max_cols, pid_out, &filter, 0);
}

size_t ts_snapshot_delta(double *out, size_t max_rows, size_t max_cols,
                          double *pid_out) {
  return ts_driver_snapshot(out, max_rows, max_cols, pid_out, NULL, 1);
}

void ts_free_thread_resources(size_t ignored) {
  (void)ignored;
  ts_driver_free_thread_resources();
}

size_t ts_core_count(size_t ignored) {
  (void)ignored;
  return ts_driver_core_count();
}

void ts_usleep(unsigned int usec) {
  struct timespec req, rem;
  req.tv_sec = (time_t)(usec / 1000000);
  req.tv_nsec = (long)((usec % 1000000) * 1000);
  while (nanosleep(&req, &rem) == -1 && errno == EINTR) {
    req = rem;
  }
}

double ts_get_monotonic_time(size_t ignored) {
  struct timespec ts;
  (void)ignored;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
  }
  return 0.0;
}

size_t ts_get_metric_count(size_t ignored) {
  (void)ignored;
  return TS_METRIC_COUNT;
}

unsigned long long ts_get_total_cpu_ticks(size_t ignored) {
  (void)ignored;
  return ts_driver_get_total_cpu_ticks();
}

unsigned long long ts_get_mem_total_bytes(size_t ignored) {
  (void)ignored;
  return ts_driver_get_mem_total_bytes();
}

size_t ts_read_comm(pid_t pid, char *out, size_t out_len) {
  return ts_driver_read_comm(pid, out, out_len);
}

size_t ts_read_cmdline(pid_t pid, char *out, size_t out_len) {
  return ts_driver_read_cmdline(pid, out, out_len);
}

size_t ts_read_cgroup(pid_t pid, char *out, size_t out_len) {
  return ts_driver_read_cgroup(pid, out, out_len);
}

int ts_get_metric_index(const char *name) {
  if (!name) return -1;
  const char *metrics[] = {
      "utime", "stime", "rss", "vsize", "num_threads",
      "vol_ctx", "nonvol_ctx", "processor", "io_read",
      "io_write", "starttime", "uid", "ppid",
      "priority", "nice", "minflt", "majflt"
  };
  for (int i = 0; i < TS_METRIC_COUNT; ++i) {
    if (strcmp(name, metrics[i]) == 0) {
      return i;
    }
  }
  return -1;
}
