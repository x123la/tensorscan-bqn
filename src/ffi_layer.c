#define _POSIX_C_SOURCE 200809L
#include "driver.h"
#include <time.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

/* Delta Logic State */
struct ts_prev_row {
  double pid;
  double starttime;
  double metrics[TS_METRIC_COUNT];
};

static __thread struct ts_prev_row *ts_prev_rows = NULL;
static __thread size_t ts_prev_cap = 0;
static __thread size_t ts_prev_count = 0;
static __thread struct ts_prev_row *ts_curr_rows = NULL;
static __thread size_t ts_curr_cap = 0;

static int ts_ensure_rows_capacity(struct ts_prev_row **rows, size_t *cap,
                                   size_t needed) {
  if (needed <= *cap) {
    return 1;
  }
  size_t new_cap = *cap ? *cap : 1024;
  while (new_cap < needed) {
    new_cap *= 2;
  }
  struct ts_prev_row *tmp = realloc(*rows, new_cap * sizeof(*tmp));
  if (!tmp) {
    return 0;
  }
  *rows = tmp;
  *cap = new_cap;
  return 1;
}

size_t ts_snapshot(double *out, size_t max_rows, size_t max_cols,
                    double *pid_out) {
  return ts_driver_capture_absolute(out, max_rows, max_cols, pid_out, NULL);
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

  return ts_driver_capture_absolute(out, max_rows, max_cols, pid_out, &filter);
}

size_t ts_snapshot_delta(double *out, size_t max_rows, size_t max_cols,
                          double *pid_out) {
  /* 
   * Buffer Strategy:
   * 1. Capture current absolute snapshot into a temp buffer (or directly if filtering is tricky).
   *    Since we need to match PIDs, we'll allocate a temporary buffer for the raw capture.
   *    However, to avoid large mallocs on every frame, we can reuse 'ts_curr_rows'.
   *    But 'ts_curr_rows' is structured. The driver writes to flat double arrays.
   *    So we simply call the driver with a pointer to a scratch buffer?
   *    Better: Let's allocate a scratch flat buffer.
   */
  
  /* For simplicity in this FFI layer, we will capture to a large static thread-local buffer?
   * No, that's unsafe for size. We'll malloc a buffer for the raw snapshot.
   * Or better, we can just use the user-provided 'out' buffer for the raw capture,
   * then process it in-place? 
   * No, 'out' is likely 'max_rows' which might be smaller than total system PIDs.
   * The driver truncates. This is fine. We only delta what we captured.
   */

  if (!pid_out) {
    ts_prev_count = 0;
    return 0;
  }

  /* Capturing absolute metrics first */
  size_t count = ts_driver_capture_absolute(out, max_rows, max_cols, pid_out, NULL);

  if (count == 0 || max_cols < TS_METRIC_COUNT) return 0;

  size_t rows = count;
  if (rows > max_rows) {
    rows = max_rows;
  }
  if (rows == 0) {
    ts_prev_count = 0;
    return count;
  }

  /* Ensure capacity for CURRENT rows (structured) */
  if (!ts_ensure_rows_capacity(&ts_curr_rows, &ts_curr_cap, rows)) {
      /* Memory failure fallback: Return 0 to avoid reporting spikes from absolute values */
      return 0;
  }
  
  size_t processed_count = 0;
  size_t prev_i = 0;

  for (size_t i = 0; i < rows; ++i) {
    double *row_ptr = out + (i * max_cols);
    double pid = pid_out[i];
    double starttime = row_ptr[TS_STARTTIME];

    /* Store current for next time */
    ts_curr_rows[processed_count].pid = pid;
    ts_curr_rows[processed_count].starttime = starttime;
    for (size_t m = 0; m < TS_METRIC_COUNT; ++m) {
      ts_curr_rows[processed_count].metrics[m] = row_ptr[m];
    }

    /* Find previous */
    int have_prev = 0;
    struct ts_prev_row *prev = NULL;

    /* Since both current and prev are sorted by PID (driver guarantees sort),
     * we can scan linearly */
    while (prev_i < ts_prev_count && ts_prev_rows[prev_i].pid < pid) {
      prev_i++;
    }
    if (prev_i < ts_prev_count && ts_prev_rows[prev_i].pid == pid &&
        ts_prev_rows[prev_i].starttime == starttime) {
      have_prev = 1;
      prev = &ts_prev_rows[prev_i];
    }

    /* Compute Deltas */
    const int counter_metrics[] = {TS_UTIME, TS_STIME, TS_VOL_CTX_SWITCHES,
                                   TS_NONVOL_CTX_SWITCHES, TS_IO_READ_BYTES,
                                   TS_IO_WRITE_BYTES, TS_MINFLT, TS_MAJFLT};

    for (size_t c = 0; c < sizeof(counter_metrics) / sizeof(counter_metrics[0]); ++c) {
      int idx = counter_metrics[c];
      double curr = row_ptr[idx];
      double delta = 0;

      if (curr < 0) {
        delta = -1;
      } else if (!have_prev || !prev || prev->metrics[idx] < 0) {
        delta = 0;
      } else {
        delta = curr - prev->metrics[idx];
        if (delta < 0) delta = 0;
      }
      row_ptr[idx] = delta;
    }

    processed_count++;
  }

  /* Swap buffers */
  struct ts_prev_row *tmp = ts_prev_rows;
  ts_prev_rows = ts_curr_rows;
  ts_curr_rows = tmp;
  ts_prev_count = processed_count;

  return count;
}


void ts_free_thread_resources(size_t ignored) {
  (void)ignored;
  ts_driver_free_thread_resources();
  
  if (ts_prev_rows) {
    free(ts_prev_rows);
    ts_prev_rows = NULL;
  }
  ts_prev_cap = 0;
  ts_prev_count = 0;

  if (ts_curr_rows) {
    free(ts_curr_rows);
    ts_curr_rows = NULL;
  }
  ts_curr_cap = 0;
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
