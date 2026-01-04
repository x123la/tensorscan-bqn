#ifndef TENSORSCAN_H
#define TENSORSCAN_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TS_METRIC_COUNT 11

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
  TS_STARTTIME = 10
};

/*
 * Fill a caller-provided buffer with current process stats.
 *
 * Layout: row-major matrix of shape [max_rows][max_cols].
 * Columns follow enum ts_metric_index. Values are stored as double.
 *
 * Returns the number of rows filled. If pid_out is non-NULL, it is filled
 * with the corresponding PIDs (length max_rows), as doubles.
 */
size_t ts_snapshot(double *out, size_t max_rows, size_t max_cols,
                   double *pid_out);

/* Return number of online processors; takes a dummy argument for FFI. */
size_t ts_core_count(size_t ignored);

#ifdef __cplusplus
}
#endif

#endif /* TENSORSCAN_H */
