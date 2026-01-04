#include "driver.h"

#if defined(__APPLE__)

#include <libproc.h>
#include <sys/sysctl.h>
#include <sys/proc_info.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <errno.h>

// Helper to get number of procs
int get_proc_list(pid_t **pids) {
    int count = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (count <= 0) return 0;
    
    // Add margin for new processes
    *pids = malloc((count + 128) * sizeof(pid_t));
    if (!*pids) return 0;
    
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, *pids, (count + 128) * sizeof(pid_t));
    if (bytes <= 0) {
        free(*pids);
        return 0;
    }
    return bytes / sizeof(pid_t);
}

// macOS Implementation of the Snapshot
size_t ts_driver_capture_absolute(double *out, size_t max_rows, size_t max_cols,
                                  double *pid_out, const struct ts_filter *filter) {
    pid_t *pids = NULL;
    int count = get_proc_list(&pids);
    if (count == 0) return 0;

    size_t row = 0;

    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;

        // --- Filters ---
        if (filter) {
            if (filter->pid_min >= 0 && pid < (pid_t)filter->pid_min) continue;
            if (filter->pid_max >= 0 && pid > (pid_t)filter->pid_max) continue;
            // Whitelist logic omitted for brevity
        }

        struct proc_taskinfo ti;
        struct proc_bsdinfo bi;
        
        int ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti));
        if (ret <= 0) continue;
        
        ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof(bi));
        if (ret <= 0) continue;

        if (row >= max_rows) break;

        double *r = out + (row * max_cols);
        
        // --- Mapping macOS structs to TensorScan Metrics ---
        r[TS_UTIME] = (double)ti.pti_total_user;
        r[TS_STIME] = (double)ti.pti_total_system;
        r[TS_RSS]   = (double)ti.pti_resident_size;
        r[TS_VSIZE] = (double)ti.pti_virtual_size;
        r[TS_NUM_THREADS] = (double)ti.pti_threadnum;
        r[TS_VOL_CTX_SWITCHES] = (double)ti.pti_csw;
        r[TS_NONVOL_CTX_SWITCHES] = 0; // Not easily available on mach
        r[TS_PROCESSOR] = (double)ti.pti_policy; // Not exactly core ID, but scheduling policy
        r[TS_IO_READ_BYTES] = 0; // Requires root/DTrace
        r[TS_IO_WRITE_BYTES] = 0;
        r[TS_STARTTIME] = (double)bi.pbi_start_tvsec;
        r[TS_UID] = (double)bi.pbi_uid;
        r[TS_PPID] = (double)bi.pbi_ppid;
        r[TS_PRIORITY] = (double)ti.pti_priority;
        r[TS_NICE] = (double)bi.pbi_nice;
        r[TS_MINFLT] = (double)ti.pti_faults;
        r[TS_MAJFLT] = (double)ti.pti_pageins;

        if (pid_out) pid_out[row] = (double)pid;
        row++;
    }
    
    free(pids);
    
    return row;
}

// Helpers
void ts_driver_free_thread_resources(void) { /* No-op for this simple impl */ }

size_t ts_driver_core_count(void) {
    int count;
    size_t size = sizeof(count);
    if (sysctlbyname("hw.ncpu", &count, &size, NULL, 0) == 0) return count;
    return 1;
}

unsigned long long ts_driver_get_total_cpu_ticks(void) { return 0; /* TODO: host_cpu_load_info */ }
unsigned long long ts_driver_get_mem_total_bytes(void) { 
    uint64_t mem; 
    size_t len = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &len, NULL, 0) == 0) return mem;
    return 0;
}

// Stubs for string helpers
size_t ts_driver_read_comm(pid_t pid, char *out, size_t out_len) {
    struct proc_bsdinfo bi;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof(bi)) > 0) {
        strncpy(out, bi.pbi_comm, out_len);
        return strlen(out);
    }
    return 0;
}
size_t ts_driver_read_cmdline(pid_t pid, char *out, size_t out_len) { 
    (void)pid; (void)out; (void)out_len; 
    return 0; 
}
size_t ts_driver_read_cgroup(pid_t pid, char *out, size_t out_len) { 
    (void)pid; (void)out; (void)out_len;
    return 0; 
}

#endif /* __APPLE__ */
