# TensorScan FFI bridge (CBQN).
# ts_snapshot signature:
#   size_t ts_snapshot(double* out, size_t max_rows, size_t max_cols,
#                      double* pid_out)
# ts_core_count signature:
#   size_t ts_core_count(size_t ignored)
# Adjust the signature string if your CBQN build uses different type codes.

lib ← •FFI (•path) ∾ "/libtensorscan.so"

# "p" = pointer, "n" = size_t (native word). Return is size_t.
tsSnapshot ← Lib ⟨"ts_snapshot", "pnnp>n"⟩
tsSnapshotFiltered ← Lib ⟨"ts_snapshot_filtered", "pnnpffpnf>n"⟩
tsSnapshotDelta ← Lib ⟨"ts_snapshot_delta", "pnnp>n"⟩
tsCoreCount ← Lib ⟨"ts_core_count", "n>n"⟩
tsUsleep ← Lib ⟨"ts_usleep", "n>"⟩
tsGetMonotonicTime ← Lib ⟨"ts_get_monotonic_time", "n>f"⟩
tsGetMetricCount ← Lib ⟨"ts_get_metric_count", "n>n"⟩
tsGetTotalCpuTicks ← Lib ⟨"ts_get_total_cpu_ticks", "n>n"⟩
tsGetMemTotalBytes ← Lib ⟨"ts_get_mem_total_bytes", "n>n"⟩
tsReadComm ← Lib ⟨"ts_read_comm", "npn>n"⟩
tsReadCmdline ← Lib ⟨"ts_read_cmdline", "npn>n"⟩
tsReadCgroup ← Lib ⟨"ts_read_cgroup", "npn>n"⟩
tsGetMetricIndex ← Lib ⟨"ts_get_metric_index", "p>i"⟩
tsFreeThreadResources ← Lib ⟨"ts_free_thread_resources", "n>"⟩

GetMetricIndex ← { TsGetMetricIndex 𝕩 }

utime ← GetMetricIndex "utime"
stime ← GetMetricIndex "stime"
rss ← GetMetricIndex "rss"
vsize ← GetMetricIndex "vsize"
num_threads ← GetMetricIndex "num_threads"
vol_ctx ← GetMetricIndex "vol_ctx"
nonvol_ctx ← GetMetricIndex "nonvol_ctx"
processor ← GetMetricIndex "processor"
io_read ← GetMetricIndex "io_read"
io_write ← GetMetricIndex "io_write"
starttime ← GetMetricIndex "starttime"
uid ← GetMetricIndex "uid"
ppid ← GetMetricIndex "ppid"
priority ← GetMetricIndex "priority"
nice ← GetMetricIndex "nice"
minflt ← GetMetricIndex "minflt"
majflt ← GetMetricIndex "majflt"

counterMetrics ← ⟨utime, stime, vol_ctx, nonvol_ctx,
  io_read, io_write, minflt, majflt⟩

ReadComm ← {
  pid ← 𝕩
  buf ← 256 ⥊ 0
  n ← TsReadComm pid‿buf‿256
  @+ n ↑ buf
}

ReadCmdline ← {
  pid ← 𝕩
  buf ← 4096 ⥊ 0
  n ← TsReadCmdline pid‿buf‿4096
  @+ n ↑ buf
}

ReadCgroup ← {
  pid ← 𝕩
  buf ← 1024 ⥊ 0
  n ← TsReadCgroup pid‿buf‿1024
  @+ n ↑ buf
}

MetricCount ← {𝕊: TsGetMetricCount 0 }
CoreCount ← {𝕊: TsCoreCount 0 }
TotalCpuTicks ← {𝕊: TsGetTotalCpuTicks 0 }
MemTotalBytes ← {𝕊: TsGetMemTotalBytes 0 }

# Take one snapshot into a fresh buffer and return ⟨timestamp, count, pids, matrix⟩.
Snapshot ← {
  rows‿cols ← 𝕩
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  t ← TsGetMonotonicTime 0
  count ← TsSnapshot buf‿rows‿cols‿pids
  pids_s ← (rows⌊count) ↑ pids
  buf_s ← (rows⌊count) ↑ buf
  # Safety: filter out any rows with pid=0 or starttime=0 to prevent alignment pollution.
  keep ← (pids_s ≠ 0) ∧ (starttime ⊏ ⍉ buf_s) ≠ 0
  ⟨t, +´ keep, keep / pids_s, keep / buf_s⟩
}

# Filtered snapshot. Use ¯1 for pid_min/pid_max/only_uid to disable.
SnapshotFiltered ← {
  rows‿cols‿pid_min‿pid_max‿pid_whitelist‿only_uid ← 𝕩
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  t ← TsGetMonotonicTime 0
  count ← TsSnapshotFiltered buf‿rows‿cols‿pids‿pid_min‿pid_max‿pid_whitelist‿(≠pid_whitelist)‿only_uid
  pids_s ← (rows⌊count) ↑ pids
  buf_s ← (rows⌊count) ↑ buf
  keep ← (pids_s ≠ 0) ∧ (starttime ⊏ ⍉ buf_s) ≠ 0
  ⟨t, +´ keep, keep / pids_s, keep / buf_s⟩
}

# Delta-ready snapshot (counter metrics are deltas).
SnapshotDelta ← {
  rows‿cols ← 𝕩
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  t ← TsGetMonotonicTime 0
  count ← TsSnapshotDelta buf‿rows‿cols‿pids
  pids_s ← (rows⌊count) ↑ pids
  buf_s ← (rows⌊count) ↑ buf
  keep ← (pids_s ≠ 0) ∧ (starttime ⊏ ⍉ buf_s) ≠ 0
  ⟨t, +´ keep, keep / pids_s, keep / buf_s⟩
}

# Capture t snapshots using fold. Returns a list of ⟨count, pids, matrix⟩.
# Uses a monotonic clock to avoid timing drift.
# Now accepts 'interval' (in seconds) as an argument.
Capture ← {
  t‿rows‿cols‿interval ← 𝕩
  start ← TsGetMonotonicTime 0
  Step ← {
    acc‿next ← 𝕨
    wait ← 0 ⌈ next - TsGetMonotonicTime 0
    TsUsleep ⌊ 1e6 × wait
    ⟨acc ∾ ⟨Snapshot rows‿cols⟩, next + interval⟩
  }
  0 ⊑ ⟨⟨⟩, start + interval⟩ Step´ ↕t
}

# Extract the processor/core-id column from a snapshot matrix.
CoreIds ← {
  mat‿proc_idx ← 𝕩
  proc_idx ⊏ ⍉ mat
}

# One-hot encode core ids for a snapshot.
# Output shape: p×c (p processes, c cores).
CoreOneHot ← {
  mat‿proc_idx‿cores ← 𝕩
  ids ← CoreIds mat‿proc_idx
  valid ← (0 ≤ ids) ∧ (ids < cores)
  safe_ids ← (cores - 1) ⌊ 0 ⌈ ids
  (safe_ids =⌜ ↕cores) × (valid ⌜⊣ ↕cores)
}

# Build PID keys using ⟨pid, starttime⟩ pairs.
PidKeys ← {
  snap ← 𝕩
  pids ← 2 ⊑ snap
  mat ← 3 ⊑ snap
  start ← starttime ⊏ ⍉ mat
  ⍉ (pids‿start)
}

PidList ← { keys ← 𝕩 ⋄ 0 ⊏ ⍉ keys }
StartList ← { keys ← 𝕩 ⋄ 1 ⊏ ⍉ keys }

# Build a stable PID key axis from a list of snapshots.
AllKeys ← {
  snaps ← 𝕩
  keys ← ∾ (PidKeys¨ snaps)
  ((keys ⊐ keys) = (↕≠keys)) / keys
}

AllPids ← {
  snaps ← 𝕩
  PidList (AllKeys snaps)
}

# Align a single snapshot's matrix to the stable PID axis.
AlignSnapshot ← {
  snap‿all_keys ← 𝕩
  keys ← PidKeys snap
  mat ← 3 ⊑ snap
  (p‿m) ← ≢ mat
  idx ← keys ⊐ all_keys
  mat0 ← mat ∾ (1‿m) ⥊ 0
  miss ← (idx < 0) ∨ (idx ≥ p)
  safe_idx ← (idx × (1 - miss)) + (miss × p)
  rows ← safe_idx ⊏ mat0
  rows
}

# Align a list of snapshots to a stable PID axis.
AlignSeries ← {
  snaps ← 𝕩
  all_keys ← AllKeys snaps
  times ← {0 ⊏ 𝕩}¨ snaps
  mats ← {snap ← 𝕩 ⋄ AlignSnapshot snap‿all_keys}¨ snaps
  ⟨all_keys, times, mats⟩
}

# Build a t×p×m tensor from aligned matrices.
Tensor3D ← {
  snaps ← 𝕩
  all_keys‿times‿mats ← AlignSeries snaps
  t ← ≠mats
  (p‿m) ← ≢ (0 ⊑ mats)
  flat ← ∾ mats
  ⟨all_keys, times, (t‿p‿m) ⥊ flat⟩
}

# Expand one snapshot matrix to include a core axis.
# Output shape: p×m×c with processor metric replaced by one-hot.
ExpandCore ← {
  mat‿cores ← 𝕩
  (p‿m) ← ≢ mat
  core_hot ← CoreOneHot mat‿processor‿cores
  broad ← mat ⌜⊣ ↕cores
  broad_m ← broad ⍉ ⟨1,0,2⟩
  core_hot2 ← (1‿p‿cores) ⥊ core_hot
  before ← processor ↑ broad_m
  after ← (processor + 1) ↓ broad_m
  merged ← before ∾ core_hot2 ∾ after
  merged ⍉ ⟨1,0,2⟩
}

# Expand to full 4D tensor with core axis.
# Returns ⟨all_keys, times, tensor⟩ where tensor is t×p×m×c.
Tensor4D ← {
  snaps‿cores ← 𝕩
  all_keys‿times‿mats ← AlignSeries snaps
  t ← ≠mats
  (p‿m) ← ≢ (0 ⊑ mats)
  expanded ← {mat ← 𝕩 ⋄ ExpandCore mat‿cores}¨ mats
  flat ← ∾ expanded
  ⟨all_keys, times, (t‿p‿m‿cores) ⥊ flat⟩
}

# Extract one metric slice. Output: t×p×c.
MetricSlice ← {
  tensor‿metric_idx ← 𝕩
  metric_idx ⊏ (tensor ⍉ ⟨2,0,1,3⟩)
}

# Convert cumulative counters to per-interval deltas and normalize by time.
# Output shape is (t-1)×p×m×c.
ToDeltas ← {
  times‿tensor ← 𝕩
  (t‿p‿m‿c) ← ≢ tensor
  t1 ← 0 ⌈ (t - 1)
  dt ← (1 ↓ times) - (¯1 ↓ times)
  # Add small epsilon to dt to avoid div-by-zero, though unlikely with monotonic clock.
  dt ↩ dt + dt = 0
  d ← (1↓tensor) - (¯1↓tensor)
  g ← 1↓tensor
  presentC ← 0 < MetricSlice tensor‿starttime
  pairC ← (1↓presentC) ∧ (¯1↓presentC)
  per_metric ← {
    i ← 𝕩
    sel ← 0 < +´ (i = counterMetrics)
    di ← MetricSlice d‿i
    gi ← MetricSlice g‿i
    # Valid if neither previous nor current sample is -1 (IO sentinel)
    validC ← (¯1↓MetricSlice tensor‿i) ≠ ¯1
    pairC2 ← pairC ∧ validC ∧ (gi ≠ ¯1)
    raw_delta ← 0 ⌈ (di × pairC2)
    # Normalize by time elapsed (dt). Reshape dt for broadcasting: (t-1)×1×1.
    norm_delta ← raw_delta ÷ dt ⌜⊣ (↕p) ⌜⊣ (↕c)
    sel × norm_delta + (1 - sel) × gi
  }¨ ↕m
  tmp ← (m‿t1‿p‿c) ⥊ ∾ per_metric
  tmp ⍉ ⟨1,2,0,3⟩
}

# Move time axis to the last position.
TimeLast ← {
  tensor ← 𝕩
  tensor ⍉ ⟨1,2,3,0⟩
}

# Mean over time axis. Input: t×p×m×c. Output: p×m×c.
MeanT ← {
  tensor ← 𝕩
  tlast ← TimeLast tensor
  n ← ¯1 ⊑ ≢ tlast
  (+´ tlast) ÷ n
}

# Variance over time axis. Input: t×p×m×c. Output: p×m×c.
VarT ← {
  tensor ← 𝕩
  tlast ← TimeLast tensor
  n ← ¯1 ⊑ ≢ tlast
  mean ← (+´ tlast) ÷ n
  mean_full ← (≢ tlast) ⥊ mean
  d ← tlast - mean_full
  (+´ (d × d)) ÷ n
}

StdT ← { √ VarT 𝕩 }

# Micro-stutter mask: spikes high but low mean over time.
# Returns p×c boolean mask.
MicroStutterMask ← {
  times‿tensor‿metric_idx‿spike_thresh‿mean_thresh ← 𝕩
  metric ← MetricSlice (ToDeltas times‿tensor)‿metric_idx
  tlast ← metric ⍉ ⟨1,2,0⟩
  n ← ¯1 ⊑ ≢ tlast
  mean ← (+´ tlast) ÷ n
  mx ← ⌈´ tlast
  (mx > spike_thresh) ∧ (mean < mean_thresh)
}

# Stealth detection: z-score of per-(p,m,c) stddev vs global stddev.
StealthZ ← {
  times‿tensor ← 𝕩
  s ← StdT (ToDeltas times‿tensor)
  r ← ∾ s
  mu ← (+´ r) ÷ ≠ r
  sigma ← √ ((+´ ((r - mu) × (r - mu))) ÷ ≠ r)
  (s - mu) ÷ sigma
}

# IO burst but low CPU usage.
IOBurstLowCPU ← {
  times‿tensor‿io_thresh‿cpu_thresh ← 𝕩
  d ← ToDeltas times‿tensor
  io ← (MetricSlice d‿io_read) + (MetricSlice d‿io_write)
  cpu ← (MetricSlice d‿utime) + (MetricSlice d‿stime)
  io_tlast ← io ⍉ ⟨1,2,0⟩
  cpu_tlast ← cpu ⍉ ⟨1,2,0⟩
  n ← ¯1 ⊑ ≢ io_tlast
  io_peak ← ⌈´ io_tlast
  cpu_mean ← (+´ cpu_tlast) ÷ n
  (io_peak > io_thresh) ∧ (cpu_mean < cpu_thresh)
}

# CPU burst concentrated on a single core.
CpuSingleCoreBurst ← {
  times‿tensor‿spike_thresh‿other_thresh ← 𝕩
  d ← ToDeltas times‿tensor
  cpu ← (MetricSlice d‿utime) + (MetricSlice d‿stime)
  cpu_tlast ← cpu ⍉ ⟨1,2,0⟩
  peak ← ⌈´ cpu_tlast
  maxc ← ⌈´ peak
  other ← (+´ peak) - maxc
  valid ← (maxc > spike_thresh) ∧ (other < other_thresh)
  c ← 1 ⊑ ≢ peak
  core_mask ← peak =⌜ maxc
  validC ← valid ⌜⊣ ↕c
  core_mask ∧ validC
}

# Thread explosion: sudden large increases in thread count.
ThreadExplosion ← {
  tensor‿delta_thresh ← 𝕩
  threads ← MetricSlice tensor‿num_threads
  d ← (1↓threads) - (¯1↓threads)
  tlast ← d ⍉ ⟨1,2,0⟩
  peak ← ⌈´ tlast
  peak > delta_thresh
}

# Density rendering helpers.
gradient ← " .:-=+*#%@"

Normalize ← {
  vals ← 𝕩
  r ← ∾ vals
  r2 ← r ∾ (0 = ≠r) ⥊ 0
  mn ← ⌊´ r2
  mx ← ⌈´ r2
  den ← (mx - mn) + (mx = mn)
  (vals - mn) ÷ den
}

MapDensity ← {
  vals ← 𝕩
  g ← gradient
  n ← ≠ g
  idx ← ⌊ (Normalize vals) × (n - 1)
  g ⊏ idx
}

# Render a time×pid heatmap for a chosen metric.
DensityMatrix ← {
  times‿tensor‿metric_idx ← 𝕩
  metric ← MetricSlice (ToDeltas times‿tensor)‿metric_idx
  # Metric has shape t×p×c. Collapse c (take max) to get t×p.
  ⌈´ (metric ⍉ ⟨2,0,1⟩)
}

DensityView ← {
  times‿tensor‿metric_idx ← 𝕩
  •Show MapDensity DensityMatrix times‿tensor‿metric_idx
}

# Example usage:
# rows ← 4096
# cols ← MetricCount 0
# buf ← (rows‿cols) ⥊ 0
# pids ← rows ⥊ 0
# count ← TsSnapshot buf‿rows‿cols‿pids
