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

static __thread int ts_warned_io_perm = 0;
static long ts_page_size = -1;

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
        *processor = -1; /* Parsing failed but we don't necessarily abort */
      }
    }
    field++;
    if (field > 39) {
      break;
    }
  }

  return found >= 5; /* 5 if processor failed, 6 if worked */
}

static void ts_read_status(pid_t pid, unsigned long long *num_threads,
                           unsigned long long *vol_ctx,
                           unsigned long long *nonvol_ctx) {
  char path[TS_PATH_MAX];
  char buf[512];
  FILE *f = NULL;

  *num_threads = 0;
  *vol_ctx = 0;
  *nonvol_ctx = 0;

  snprintf(path, sizeof(path), "/proc/%d/status", pid);
  f = fopen(path, "r");
  if (!f) {
    /* Any failure to open results in -1 to distinguish from zeroed counters */
    *num_threads = (unsigned long long)-1;
    *vol_ctx = (unsigned long long)-1;
    *nonvol_ctx = (unsigned long long)-1;
    return;
  }

  while (fgets(buf, sizeof(buf), f)) {
    if (strncmp(buf, "Threads:", 8) == 0) {
      *num_threads = strtoull(buf + 8, NULL, 10);
    } else if (strncmp(buf, "voluntary_ctxt_switches:", 24) == 0) {
      *vol_ctx = strtoull(buf + 24, NULL, 10);
    } else if (strncmp(buf, "nonvoluntary_ctxt_switches:", 27) == 0) {
      *nonvol_ctx = strtoull(buf + 27, NULL, 10);
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
    if (errno == EACCES || errno == EPERM) {
      if (!ts_warned_io_perm) {
        fprintf(stderr, "TensorScan: /proc/[pid]/io requires permission; "
                        "I/O metrics set to -1.\n");
        ts_warned_io_perm = 1;
      }
    }
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

static int ts_cmp_pids(const void *a, const void *b) {
  pid_t pa = *(const pid_t *)a;
  pid_t pb = *(const pid_t *)b;
  return (pa < pb) ? -1 : (pa > pb);
}

size_t ts_snapshot(double *out, size_t max_rows, size_t max_cols,
                   double *pid_out) {
  DIR *dir = NULL;
  struct dirent *ent = NULL;
  pid_t *pids = NULL;
  size_t pids_cap = 1024;
  size_t pids_count = 0;
  size_t found_successes = 0;
  size_t row = 0;
  size_t i;

  if (ts_page_size < 0) {
    ts_page_size = sysconf(_SC_PAGESIZE);
  }

  if (!out || max_cols < TS_METRIC_COUNT) {
    return 0;
  }

  dir = opendir("/proc");
  if (!dir) {
    return 0;
  }

  pids = malloc(pids_cap * sizeof(pid_t));
  if (!pids) {
    closedir(dir);
    return 0;
  }

  while ((ent = readdir(dir)) != NULL) {
    if (!ts_is_numeric(ent->d_name)) {
      continue;
    }
    if (pids_count >= pids_cap) {
      pids_cap *= 2;
      pid_t *tmp = realloc(pids, pids_cap * sizeof(pid_t));
      if (!tmp) {
        break;
      }
      pids = tmp;
    }
    pids[pids_count++] = (pid_t)strtol(ent->d_name, NULL, 10);
  }
  closedir(dir);

  qsort(pids, pids_count, sizeof(pid_t), ts_cmp_pids);

  for (i = 0; i < pids_count; ++i) {
    unsigned long long utime = 0, stime = 0, starttime = 0, vsize = 0;
    long long rss_pages = 0;
    int processor = -1;
    unsigned long long num_threads = 0, vol_ctx = 0, nonvol_ctx = 0;
    long long read_bytes = 0, write_bytes = 0;
    pid_t pid = pids[i];

    if (ts_read_stat(pid, &utime, &stime, &vsize, &rss_pages, &processor,
                     &starttime)) {
      found_successes++;

      if (row < max_rows) {
        ts_read_status(pid, &num_threads, &vol_ctx, &nonvol_ctx);
        ts_read_io(pid, &read_bytes, &write_bytes);

        double *row_ptr = out + (row * max_cols);
        row_ptr[TS_UTIME] = (double)utime;
        row_ptr[TS_STIME] = (double)stime;
        row_ptr[TS_RSS] = (double)rss_pages * (double)ts_page_size;
        row_ptr[TS_VSIZE] = (double)vsize;
        row_ptr[TS_NUM_THREADS] = (double)num_threads;
        row_ptr[TS_VOL_CTX_SWITCHES] = (double)vol_ctx;
        row_ptr[TS_NONVOL_CTX_SWITCHES] = (double)nonvol_ctx;
        row_ptr[TS_PROCESSOR] = (double)processor;
        row_ptr[TS_IO_READ_BYTES] = (double)read_bytes;
        row_ptr[TS_IO_WRITE_BYTES] = (double)write_bytes;
        row_ptr[TS_STARTTIME] = (double)starttime;

        if (pid_out) {
          pid_out[row] = (double)pid;
        }
        row++;
      }
    }
  }

  free(pids);
  return found_successes;
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

size_t ts_core_count(size_t ignored) {
  long n = 0;
  (void)ignored;
  n = sysconf(_SC_NPROCESSORS_ONLN);
  if (n < 1) {
    n = 1;
  }
  return (size_t)n;
}
