#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#include "tensorscan.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if !defined(__linux__)
#error "TensorScan shim requires Linux /proc"
#endif

#ifndef PATH_MAX
#define TS_PATH_MAX 4096
#else
#define TS_PATH_MAX PATH_MAX
#endif

static long ts_page_size = -1;
static __thread pid_t *ts_pid_buf = NULL;
static __thread size_t ts_pid_cap = 0;

struct ts_prev_row {
  pid_t pid;
  unsigned long long starttime;
  double metrics[TS_METRIC_COUNT];
};

static __thread struct ts_prev_row *ts_prev_rows = NULL;
static __thread size_t ts_prev_cap = 0;
static __thread size_t ts_prev_count = 0;
static __thread struct ts_prev_row *ts_curr_rows = NULL;
static __thread size_t ts_curr_cap = 0;

static int ts_is_numeric(const char *s) {
  if (!s || *s == '\0') {
    return 0;
  }
  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
    if (!isdigit(*p)) {
      return 0;
    }
  }
  return 1;
}

static int ts_parse_pid(const char *s, pid_t *pid_out) {
  char *endptr = NULL;
  long val = 0;

  errno = 0;
  val = strtol(s, &endptr, 10);
  if (errno != 0 || endptr == s || *endptr != '\0') {
    return 0;
  }
  if (val <= 0 || val > INT_MAX) {
    return 0;
  }
  *pid_out = (pid_t)val;
  return 1;
}

static int ts_cmp_pids(const void *a, const void *b) {
  pid_t pa = *(const pid_t *)a;
  pid_t pb = *(const pid_t *)b;
  return (pa < pb) ? -1 : (pa > pb);
}

static int ts_ensure_pid_capacity(size_t needed) {
  if (needed <= ts_pid_cap) {
    return 1;
  }
  size_t new_cap = ts_pid_cap ? ts_pid_cap : 1024;
  while (new_cap < needed) {
    new_cap *= 2;
  }
  pid_t *tmp = realloc(ts_pid_buf, new_cap * sizeof(pid_t));
  if (!tmp) {
    return 0;
  }
  ts_pid_buf = tmp;
  ts_pid_cap = new_cap;
  return 1;
}

static int ts_read_stat(pid_t pid, unsigned long long *utime,
                        unsigned long long *stime, unsigned long long *vsize,
                        long long *rss_pages, int *processor,
                        unsigned long long *starttime) {
  char path[TS_PATH_MAX];
  char buf[4096];
  FILE *f = NULL;
  char *line = NULL;
  char *rest = NULL;
  char *token = NULL;
  int field = 3;
  int found = 0;

  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  f = fopen(path, "r");
  if (!f) {
    return 0;
  }

  if (!fgets(buf, sizeof(buf), f)) {
    fclose(f);
    return 0;
  }
  /* Check if newline exists to ensure buffer wasn't too small to read the line.
   * If not found, it might mean truncation, but we only need fields up to 39.
   * We proceed but verify 'found' later. */
  fclose(f);

  line = strrchr(buf, ')');
  if (!line) {
    return 0;
  }
  line++; /* move past ')' */
  if (*line == ' ') {
    line++;
  }

  rest = line;
  while ((token = strsep(&rest, " ")) != NULL) {
    if (*token == '\0') {
      continue;
    }
    if (field == 14) {
      *utime = strtoull(token, NULL, 10);
      found++;
    } else if (field == 15) {
      *stime = strtoull(token, NULL, 10);
      found++;
    } else if (field == 22) {
      *starttime = strtoull(token, NULL, 10);
      found++;
    } else if (field == 23) {
      *vsize = strtoull(token, NULL, 10);
      found++;
    } else if (field == 24) {
      *rss_pages = strtoll(token, NULL, 10);
      found++;
    } else if (field == 39) {
      char *endptr = NULL;
      *processor = (int)strtol(token, &endptr, 10);
      if (endptr != token) {
        found++;
      } else {
        *processor = -1;
      }
    }
    field++;
    if (field > 39) {
      break;
    }
  }

  return found >= 5; /* 5 if processor failed, 6 if worked */
}

static void ts_read_status(pid_t pid, long long *num_threads,
                           long long *vol_ctx, long long *nonvol_ctx,
                           long long *uid, long long *ppid) {
  char path[TS_PATH_MAX];
  char buf[512];
  FILE *f = NULL;

  *num_threads = -1;
  *vol_ctx = -1;
  *nonvol_ctx = -1;
  *uid = -1;
  *ppid = -1;

  snprintf(path, sizeof(path), "/proc/%d/status", pid);
  f = fopen(path, "r");
  if (!f) {
    return;
  }

  while (fgets(buf, sizeof(buf), f)) {
    if (strncmp(buf, "Threads:", 8) == 0) {
      *num_threads = strtoll(buf + 8, NULL, 10);
    } else if (strncmp(buf, "voluntary_ctxt_switches:", 24) == 0) {
      *vol_ctx = strtoll(buf + 24, NULL, 10);
    } else if (strncmp(buf, "nonvoluntary_ctxt_switches:", 27) == 0) {
      *nonvol_ctx = strtoll(buf + 27, NULL, 10);
    } else if (strncmp(buf, "Uid:", 4) == 0) {
      *uid = strtoll(buf + 4, NULL, 10);
    } else if (strncmp(buf, "PPid:", 5) == 0) {
      *ppid = strtoll(buf + 5, NULL, 10);
    }
  }

  fclose(f);
}

static void ts_read_io(pid_t pid, long long *read_bytes,
                       long long *write_bytes) {
  char path[TS_PATH_MAX];
  char buf[512];
  FILE *f = NULL;

  *read_bytes = -1;
  *write_bytes = -1;

  snprintf(path, sizeof(path), "/proc/%d/io", pid);
  f = fopen(path, "r");
  if (!f) {
    return;
  }

  *read_bytes = 0;
  *write_bytes = 0;
  while (fgets(buf, sizeof(buf), f)) {
    if (strncmp(buf, "read_bytes:", 11) == 0) {
      *read_bytes = strtoll(buf + 11, NULL, 10);
    } else if (strncmp(buf, "write_bytes:", 12) == 0) {
      *write_bytes = strtoll(buf + 12, NULL, 10);
    }
  }

  fclose(f);
}

struct ts_filter {
  double pid_min;
  double pid_max;
  double only_uid;
  const double *pid_whitelist;
  size_t whitelist_count;
};

static int ts_pid_in_whitelist(pid_t pid, const double *list, size_t count) {
  if (!list || count == 0) {
    return 1;
  }
  for (size_t i = 0; i < count; ++i) {
    if ((pid_t)list[i] == pid) {
      return 1;
    }
  }
  return 0;
}

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

static size_t ts_snapshot_impl(double *out, size_t max_rows, size_t max_cols,
                               double *pid_out, const struct ts_filter *filter,
                               int delta_mode) {
  DIR *dir = NULL;
  struct dirent *ent = NULL;
  size_t found_successes = 0;
  size_t pids_count = 0;
  size_t prev_i = 0;
  size_t curr_count = 0;
  size_t row = 0;

  if (!out || max_cols < TS_METRIC_COUNT) {
    return 0;
  }

  if (ts_page_size < 0) {
    ts_page_size = sysconf(_SC_PAGESIZE);
    if (ts_page_size <= 0) {
      ts_page_size = 4096;
    }
  }

  dir = opendir("/proc");
  if (!dir) {
    return 0;
  }

  while ((ent = readdir(dir)) != NULL) {
    pid_t pid = 0;
    if (!ts_is_numeric(ent->d_name)) {
      continue;
    }
    if (!ts_parse_pid(ent->d_name, &pid)) {
      continue;
    }
    if (!ts_ensure_pid_capacity(pids_count + 1)) {
      break;
    }
    ts_pid_buf[pids_count++] = pid;
  }
  closedir(dir);

  qsort(ts_pid_buf, pids_count, sizeof(pid_t), ts_cmp_pids);

  if (delta_mode) {
    if (!ts_ensure_rows_capacity(&ts_curr_rows, &ts_curr_cap, pids_count)) {
      delta_mode = 0;
    }
  }

  for (size_t i = 0; i < pids_count; ++i) {
    unsigned long long utime = 0, stime = 0, starttime = 0, vsize = 0;
    long long rss_pages = 0;
    int processor = -1;
    long long num_threads = -1, vol_ctx = -1, nonvol_ctx = -1;
    long long read_bytes = -1, write_bytes = -1;
    long long uid = -1, ppid = -1;
    pid_t pid = ts_pid_buf[i];
    double metrics[TS_METRIC_COUNT];
    double deltas[TS_METRIC_COUNT];
    double *row_ptr = NULL;
    int have_prev = 0;
    const struct ts_prev_row *prev = NULL;

    if (filter) {
      if (filter->pid_min >= 0 && pid < (pid_t)filter->pid_min) {
        continue;
      }
      if (filter->pid_max >= 0 && pid > (pid_t)filter->pid_max) {
        continue;
      }
      if (!ts_pid_in_whitelist(pid, filter->pid_whitelist,
                               filter->whitelist_count)) {
        continue;
      }
    }

    if (!ts_read_stat(pid, &utime, &stime, &vsize, &rss_pages, &processor,
                      &starttime)) {
      continue;
    }

    ts_read_status(pid, &num_threads, &vol_ctx, &nonvol_ctx, &uid, &ppid);

    if (filter && filter->only_uid >= 0) {
      if (uid < 0 || uid != (long long)filter->only_uid) {
        continue;
      }
    }

    ts_read_io(pid, &read_bytes, &write_bytes);

    metrics[TS_UTIME] = (double)utime;
    metrics[TS_STIME] = (double)stime;
    metrics[TS_RSS] = (double)rss_pages * (double)ts_page_size;
    metrics[TS_VSIZE] = (double)vsize;
    metrics[TS_NUM_THREADS] = (double)num_threads;
    metrics[TS_VOL_CTX_SWITCHES] = (double)vol_ctx;
    metrics[TS_NONVOL_CTX_SWITCHES] = (double)nonvol_ctx;
    metrics[TS_PROCESSOR] = (double)processor;
    metrics[TS_IO_READ_BYTES] = (double)read_bytes;
    metrics[TS_IO_WRITE_BYTES] = (double)write_bytes;
    metrics[TS_STARTTIME] = (double)starttime;
    metrics[TS_UID] = (double)uid;
    metrics[TS_PPID] = (double)ppid;

    found_successes++;

    if (delta_mode) {
      while (prev_i < ts_prev_count && ts_prev_rows[prev_i].pid < pid) {
        prev_i++;
      }
      if (prev_i < ts_prev_count && ts_prev_rows[prev_i].pid == pid &&
          ts_prev_rows[prev_i].starttime == starttime) {
        have_prev = 1;
        prev = &ts_prev_rows[prev_i];
      }

      for (size_t m = 0; m < TS_METRIC_COUNT; ++m) {
        deltas[m] = metrics[m];
      }

      const int counter_metrics[] = {TS_UTIME, TS_STIME, TS_VOL_CTX_SWITCHES,
                                     TS_NONVOL_CTX_SWITCHES, TS_IO_READ_BYTES,
                                     TS_IO_WRITE_BYTES};
      for (size_t c = 0; c < sizeof(counter_metrics) / sizeof(counter_metrics[0]);
           ++c) {
        int idx = counter_metrics[c];
        double curr = metrics[idx];
        if (curr < 0) {
          deltas[idx] = -1;
          continue;
        }
        if (!have_prev || !prev || prev->metrics[idx] < 0) {
          deltas[idx] = 0;
          continue;
        }
        double delta = curr - prev->metrics[idx];
        if (delta < 0) {
          delta = 0;
        }
        deltas[idx] = delta;
      }
    }

    if (row < max_rows) {
      row_ptr = out + (row * max_cols);
      if (delta_mode) {
        for (size_t m = 0; m < TS_METRIC_COUNT; ++m) {
          row_ptr[m] = deltas[m];
        }
      } else {
        for (size_t m = 0; m < TS_METRIC_COUNT; ++m) {
          row_ptr[m] = metrics[m];
        }
      }
      if (pid_out) {
        pid_out[row] = (double)pid;
      }
      row++;
    }

    if (delta_mode) {
      if (curr_count < ts_curr_cap) {
        ts_curr_rows[curr_count].pid = pid;
        ts_curr_rows[curr_count].starttime = starttime;
        for (size_t m = 0; m < TS_METRIC_COUNT; ++m) {
          ts_curr_rows[curr_count].metrics[m] = metrics[m];
        }
        curr_count++;
      }
    }
  }

  if (delta_mode) {
    struct ts_prev_row *tmp = ts_prev_rows;
    ts_prev_rows = ts_curr_rows;
    ts_curr_rows = tmp;
    ts_prev_count = curr_count;
  }

  return found_successes;
}

size_t ts_snapshot(double *out, size_t max_rows, size_t max_cols,
                   double *pid_out) {
  return ts_snapshot_impl(out, max_rows, max_cols, pid_out, NULL, 0);
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

  return ts_snapshot_impl(out, max_rows, max_cols, pid_out, &filter, 0);
}

size_t ts_snapshot_delta(double *out, size_t max_rows, size_t max_cols,
                         double *pid_out) {
  return ts_snapshot_impl(out, max_rows, max_cols, pid_out, NULL, 1);
}

void ts_usleep(unsigned int usec) {
  struct timespec req, rem;
  req.tv_sec = (time_t)(usec / 1000000);
  req.tv_nsec = (long)((usec % 1000000) * 1000);
  while (nanosleep(&req, &rem) == -1 && errno == EINTR) {
    req = rem;
  }
}

double ts_get_monotonic_time(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
  }
  return 0.0;
}

size_t ts_get_metric_count(void) { return TS_METRIC_COUNT; }

unsigned long long ts_get_total_cpu_ticks(void) {
  FILE *f = fopen("/proc/stat", "r");
  if (!f) {
    return 0;
  }
  char buf[512];
  unsigned long long total = 0;
  if (fgets(buf, sizeof(buf), f)) {
    if (strncmp(buf, "cpu ", 4) == 0) {
      char *rest = buf + 4;
      char *token = NULL;
      while ((token = strsep(&rest, " ")) != NULL) {
        if (*token == '\0') {
          continue;
        }
        total += strtoull(token, NULL, 10);
      }
    }
  }
  fclose(f);
  return total;
}

unsigned long long ts_get_mem_total_bytes(void) {
  FILE *f = fopen("/proc/meminfo", "r");
  if (!f) {
    return 0;
  }
  char buf[256];
  unsigned long long kb = 0;
  while (fgets(buf, sizeof(buf), f)) {
    if (strncmp(buf, "MemTotal:", 9) == 0) {
      kb = strtoull(buf + 9, NULL, 10);
      break;
    }
  }
  fclose(f);
  return kb * 1024ULL;
}

static size_t ts_read_file_trim(const char *path, char *out, size_t out_len,
                                int replace_nul) {
  FILE *f = fopen(path, "r");
  if (!f || !out || out_len == 0) {
    if (f) {
      fclose(f);
    }
    return 0;
  }
  size_t n = fread(out, 1, out_len - 1, f);
  fclose(f);
  if (n == 0) {
    out[0] = '\0';
    return 0;
  }
  for (size_t i = 0; i < n; ++i) {
    if (out[i] == '\n') {
      out[i] = ' ';
    } else if (replace_nul && out[i] == '\0') {
      out[i] = ' ';
    }
  }
  while (n > 0 && out[n - 1] == ' ') {
    n--;
  }
  out[n] = '\0';
  return n;
}

size_t ts_read_comm(pid_t pid, char *out, size_t out_len) {
  char path[TS_PATH_MAX];
  snprintf(path, sizeof(path), "/proc/%d/comm", pid);
  return ts_read_file_trim(path, out, out_len, 0);
}

size_t ts_read_cmdline(pid_t pid, char *out, size_t out_len) {
  char path[TS_PATH_MAX];
  snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
  return ts_read_file_trim(path, out, out_len, 1);
}

size_t ts_read_cgroup(pid_t pid, char *out, size_t out_len) {
  char path[TS_PATH_MAX];
  snprintf(path, sizeof(path), "/proc/%d/cgroup", pid);
  return ts_read_file_trim(path, out, out_len, 0);
}

size_t ts_core_count(size_t ignored) {
  long n = 0;
  (void)ignored;
  n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 1) {
    n = 1;
  }
  return (size_t)n;
}

void ts_free_thread_resources(void) {
  if (ts_pid_buf) {
    free(ts_pid_buf);
    ts_pid_buf = NULL;
  }
  ts_pid_cap = 0;

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
