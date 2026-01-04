#ifndef TENSORSCAN_H
#define TENSORSCAN_H

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TS_METRIC_COUNT 13

enum ts_metric_index {
  TS_UTIME = 0,
  TS_STIME = 1,
  TS_RSS = 2,
  TS_VSIZE = 3,
  TS_NUM_THREADS = 4,
  TS_VOL_CTX_SWITCHES = 5,
  TS_NONVOL_CTX_SWITCHES = 6,
  TS_PROCESSOR = 7,
  TS_IO_READ_BYTES = 8,
  TS_IO_WRITE_BYTES = 9,
  TS_STARTTIME = 10,
  TS_UID = 11,
  TS_PPID = 12
};

/*
 * Fill a caller-provided buffer with current process stats.
 *
 * Layout: row-major matrix of shape [max_rows][max_cols].
 * Columns follow enum ts_metric_index. Values are stored as double.
 *
 * Returns the TOTAL number of successfully parsed processes found on
 * the system. If this is > max_rows, the data was truncated to max_rows.
 * If pid_out is non-NULL, it is filled with corresponding PIDs.
 */
size_t ts_snapshot(double *out, size_t max_rows, size_t max_cols,
                   double *pid_out);

/*
 * Filtered snapshot. Use negative values to disable pid range or uid filters.
 * If whitelist_count is zero or pid_whitelist is NULL, no whitelist is used.
 */
size_t ts_snapshot_filtered(double *out, size_t max_rows, size_t max_cols,
                            double *pid_out, double pid_min, double pid_max,
                            const double *pid_whitelist,
                            size_t whitelist_count, double only_uid);

/*
 * Delta-ready snapshot. Counter metrics return per-interval deltas if a
 * previous snapshot exists, otherwise 0. Non-counter metrics are absolute.
 */
size_t ts_snapshot_delta(double *out, size_t max_rows, size_t max_cols,
                         double *pid_out);

/* Return number of online processors; takes a dummy argument for FFI. */
size_t ts_core_count(size_t ignored);

/* Sleep for usec useconds. */
void ts_usleep(unsigned int usec);

/* Get monotonic time in seconds. */
double ts_get_monotonic_time(size_t ignored);

/* Get number of columns in metrics matrix. */
size_t ts_get_metric_count(size_t ignored);

/* Total CPU ticks across all cores (from /proc/stat). */
unsigned long long ts_get_total_cpu_ticks(size_t ignored);

/* Total system memory in bytes (from /proc/meminfo). */
unsigned long long ts_get_mem_total_bytes(size_t ignored);

/* Optional metadata helpers: read comm/cmdline/cgroup for a PID. */
size_t ts_read_comm(pid_t pid, char *out, size_t out_len);
size_t ts_read_cmdline(pid_t pid, char *out, size_t out_len);
size_t ts_read_cgroup(pid_t pid, char *out, size_t out_len);

/* Get index of a metric by name. Returns -1 if not found. */
int ts_get_metric_index(const char *name);

/* Free thread-local buffers. Call before thread exit to avoid leaks. */
void ts_free_thread_resources(size_t ignored);

#ifdef __cplusplus
}
#endif

#endif /* TENSORSCAN_H */
