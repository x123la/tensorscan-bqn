⍝ TensorScan FFI bridge (CBQN).
⍝ ts_snapshot signature:
⍝   size_t ts_snapshot(double* out, size_t max_rows, size_t max_cols,
⍝                      double* pid_out)
⍝ ts_core_count signature:
⍝   size_t ts_core_count(size_t ignored)
⍝ Adjust the signature string if your CBQN build uses different type codes.

lib ← •FFI "./libtensorscan.so"

⍝ "p" = pointer, "n" = size_t (native word). Return is size_t.
ts_snapshot ← lib ⟨"ts_snapshot", "pnnp>n"⟩
ts_snapshot_filtered ← lib ⟨"ts_snapshot_filtered", "pnnpffpnf>n"⟩
ts_snapshot_delta ← lib ⟨"ts_snapshot_delta", "pnnp>n"⟩
ts_core_count ← lib ⟨"ts_core_count", "n>n"⟩
ts_usleep ← lib ⟨"ts_usleep", "n>"⟩
ts_get_monotonic_time ← lib ⟨"ts_get_monotonic_time", ">f"⟩
ts_get_metric_count ← lib ⟨"ts_get_metric_count", ">n"⟩
ts_get_total_cpu_ticks ← lib ⟨"ts_get_total_cpu_ticks", ">n"⟩
ts_get_mem_total_bytes ← lib ⟨"ts_get_mem_total_bytes", ">n"⟩

MetricCount ← ts_get_metric_count 0
CoreCount ← ts_core_count 0
TotalCpuTicks ← ts_get_total_cpu_ticks 0
MemTotalBytes ← ts_get_mem_total_bytes 0

⍝ Metric indices (mirror tensorscan.h)
UTIME ← 0
STIME ← 1
RSS ← 2
VSIZE ← 3
NUM_THREADS ← 4
VOL_CTX_SWITCHES ← 5
NONVOL_CTX_SWITCHES ← 6
PROCESSOR ← 7
IO_READ_BYTES ← 8
IO_WRITE_BYTES ← 9
STARTTIME ← 10
UID ← 11
PPID ← 12

CounterMetrics ← ⟨UTIME, STIME, VOL_CTX_SWITCHES, NONVOL_CTX_SWITCHES,
  IO_READ_BYTES, IO_WRITE_BYTES⟩

⍝ Take one snapshot into a fresh buffer and return ⟨count, pids, matrix⟩.
Snapshot ← { rows cols;
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  count ← ts_snapshot buf rows cols pids
  _ ← {count > rows ? •stderr "TensorScan: Buffer full! "∾(•Fmt count)∾" processes found, but rows="∾(•Fmt rows)∾".\n" ; 0} 0
  pids_s ← (rows⌊count) ↑ pids
  buf_s ← (rows⌊count) ↑ buf
  ⍝ Safety: filter out any rows with pid=0 or starttime=0 to prevent alignment pollution.
  keep ← (pids_s ≠ 0) ∧ (STARTTIME ⊏ ⍉ buf_s) ≠ 0
  ⟨+´ keep, keep / pids_s, keep / buf_s⟩
}

⍝ Filtered snapshot. Use ¯1 for pid_min/pid_max/only_uid to disable.
SnapshotFiltered ← { rows cols pid_min pid_max pid_whitelist only_uid;
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  count ← ts_snapshot_filtered buf rows cols pids pid_min pid_max pid_whitelist (≠pid_whitelist) only_uid
  _ ← {count > rows ? •stderr "TensorScan: Buffer full! "∾(•Fmt count)∾" processes found, but rows="∾(•Fmt rows)∾".\n" ; 0} 0
  pids_s ← (rows⌊count) ↑ pids
  buf_s ← (rows⌊count) ↑ buf
  keep ← (pids_s ≠ 0) ∧ (STARTTIME ⊏ ⍉ buf_s) ≠ 0
  ⟨+´ keep, keep / pids_s, keep / buf_s⟩
}

⍝ Delta-ready snapshot (counter metrics are deltas).
SnapshotDelta ← { rows cols;
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  count ← ts_snapshot_delta buf rows cols pids
  _ ← {count > rows ? •stderr "TensorScan: Buffer full! "∾(•Fmt count)∾" processes found, but rows="∾(•Fmt rows)∾".\n" ; 0} 0
  pids_s ← (rows⌊count) ↑ pids
  buf_s ← (rows⌊count) ↑ buf
  keep ← (pids_s ≠ 0) ∧ (STARTTIME ⊏ ⍉ buf_s) ≠ 0
  ⟨+´ keep, keep / pids_s, keep / buf_s⟩
}

⍝ Capture T snapshots using fold. Returns a list of ⟨count, pids, matrix⟩.
⍝ Uses a monotonic clock to avoid timing drift.
Capture ← { t rows cols;
  interval ← 0.01 ⍝ 10ms
  start ← ts_get_monotonic_time 0
  step ← { ⟨acc, next⟩ _;
    wait ← 0 ⌈ next - ts_get_monotonic_time 0
    ts_usleep ⌊ 1e6 × wait
    ⟨acc ∾ ⟨Snapshot rows cols⟩, next + interval⟩
  }
  0 ⊑ ⟨⟨⟩, start + interval⟩ step´ ↕t
}

⍝ Extract the processor/core-id column from a snapshot matrix.
CoreIds ← { mat proc_idx;
  proc_idx ⊏ ⍉ mat
}

⍝ One-hot encode core ids for a snapshot.
⍝ Output shape: P×C (P processes, C cores).
CoreOneHot ← { mat proc_idx cores;
  ids ← CoreIds mat proc_idx
  valid ← (0 ≤ ids) ∧ (ids < cores)
  safe_ids ← (cores - 1) ⌊ 0 ⌈ ids
  (safe_ids =⌜ ↕cores) × (valid ⌜⊣ ↕cores)
}

⍝ Build PID keys using ⟨pid, starttime⟩ pairs.
PidKeys ← { snap;
  pids ← 1 ⊑ snap
  mat ← 2 ⊑ snap
  start ← STARTTIME ⊏ ⍉ mat
  ⍉ (pids‿start)
}

PidList ← { keys; 0 ⊏ ⍉ keys }
StartList ← { keys; 1 ⊏ ⍉ keys }

⍝ Build a stable PID key axis from a list of snapshots.
AllKeys ← { snaps;
  ∪ ∾ (PidKeys¨ snaps)
}

AllPids ← { snaps;
  PidList (AllKeys snaps)
}

⍝ Align a single snapshot's matrix to the stable PID axis.
AlignSnapshot ← { snap all_keys;
  keys ← PidKeys snap
  mat ← 2 ⊑ snap
  (P‿M) ← ≢ mat
  idx ← keys ⊐ all_keys
  mat0 ← mat ∾ (1‿M) ⥊ 0
  miss ← (idx < 0) ∨ (idx ≥ P)
  safe_idx ← (idx × (1 - miss)) + (miss × P)
  rows ← safe_idx ⊏ mat0
  rows
}

⍝ Align a list of snapshots to a stable PID axis.
AlignSeries ← { snaps;
  all_keys ← AllKeys snaps
  mats ← {snap; AlignSnapshot snap all_keys}¨ snaps
  ⟨all_keys, mats⟩
}

⍝ Build a T×P×M tensor from aligned matrices.
Tensor3D ← { snaps;
  all_keys mats ← AlignSeries snaps
  T ← ≠mats
  (P‿M) ← ≢ (0 ⊑ mats)
  flat ← ∾ mats
  ⟨all_keys, (T‿P‿M) ⥊ flat⟩
}

⍝ Expand one snapshot matrix to include a core axis.
⍝ Output shape: P×M×C with processor metric replaced by one-hot.
ExpandCore ← { mat cores;
  (P‿M) ← ≢ mat
  core_hot ← CoreOneHot mat PROCESSOR cores
  broad ← mat ⌜⊣ ↕cores
  broad_m ← broad ⍉ ⟨1,0,2⟩
  core_hot2 ← (1‿P‿cores) ⥊ core_hot
  before ← PROCESSOR ↑ broad_m
  after ← (PROCESSOR + 1) ↓ broad_m
  merged ← before ∾ core_hot2 ∾ after
  merged ⍉ ⟨1,0,2⟩
}

⍝ Expand to full 4D tensor with core axis.
⍝ Returns ⟨all_keys, tensor⟩ where tensor is T×P×M×C.
Tensor4D ← { snaps cores;
  all_keys mats ← AlignSeries snaps
  T ← ≠mats
  (P‿M) ← ≢ (0 ⊑ mats)
  expanded ← {mat; ExpandCore mat cores}¨ mats
  flat ← ∾ expanded
  ⟨all_keys, (T‿P‿M‿cores) ⥊ flat⟩
}

⍝ Extract one metric slice. Output: T×P×C.
MetricSlice ← { tensor metric_idx;
  metric_idx ⊏ (tensor ⍉ ⟨2,0,1,3⟩)
}

⍝ Convert cumulative counters to per-interval deltas.
⍝ Output shape is (T-1)×P×M×C.
ToDeltas ← { tensor;
  (T‿P‿M‿C) ← ≢ tensor
  t1 ← 0 ⌈ (T - 1)
  d ← (1↓tensor) - (¯1↓tensor)
  g ← 1↓tensor
  presentC ← 0 < MetricSlice tensor STARTTIME
  pairC ← (1↓presentC) ∧ (¯1↓presentC)
  per_metric ← {i;
    sel ← 0 < +´ (i = CounterMetrics)
    di ← MetricSlice d i
    gi ← MetricSlice g i
    ⍝ Valid if neither previous nor current sample is -1 (IO sentinel)
    validC ← (¯1↓MetricSlice tensor i) ≠ ¯1
    pairC2 ← pairC ∧ validC ∧ (gi ≠ ¯1)
    delta ← 0 ⌈ (di × pairC2)
    sel × delta + (1 - sel) × gi
  }¨ ↕M
  tmp ← (M‿t1‿P‿C) ⥊ ∾ per_metric
  tmp ⍉ ⟨1,2,0,3⟩
}

⍝ Move time axis to the last position.
TimeLast ← { tensor;
  tensor ⍉ ⟨1,2,3,0⟩
}

⍝ Mean over time axis. Input: T×P×M×C. Output: P×M×C.
MeanT ← { tensor;
  tlast ← TimeLast tensor
  n ← ¯1 ⊑ ≢ tlast
  (+´ tlast) ÷ n
}

⍝ Variance over time axis. Input: T×P×M×C. Output: P×M×C.
VarT ← { tensor;
  tlast ← TimeLast tensor
  n ← ¯1 ⊑ ≢ tlast
  mean ← (+´ tlast) ÷ n
  mean_full ← (≢ tlast) ⥊ mean
  d ← tlast - mean_full
  (+´ (d × d)) ÷ n
}

StdT ← { tensor; √ VarT tensor }

⍝ Micro-stutter mask: spikes high but low mean over time.
⍝ Returns P×C boolean mask.
MicroStutterMask ← { tensor metric_idx spike_thresh mean_thresh;
  metric ← MetricSlice (ToDeltas tensor) metric_idx
  tlast ← metric ⍉ ⟨1,2,0⟩
  n ← ¯1 ⊑ ≢ tlast
  mean ← (+´ tlast) ÷ n
  mx ← ⌈´ tlast
  (mx > spike_thresh) ∧ (mean < mean_thresh)
}

⍝ Stealth detection: z-score of per-(P,M,C) stddev vs global stddev.
StealthZ ← { tensor;
  s ← StdT (ToDeltas tensor)
  r ← ∾ s
  mu ← (+´ r) ÷ ≠ r
  sigma ← √ ((+´ ((r - mu) × (r - mu))) ÷ ≠ r)
  (s - mu) ÷ sigma
}

⍝ IO burst but low CPU usage.
IOBurstLowCPU ← { tensor io_thresh cpu_thresh;
  d ← ToDeltas tensor
  io ← (MetricSlice d IO_READ_BYTES) + (MetricSlice d IO_WRITE_BYTES)
  cpu ← (MetricSlice d UTIME) + (MetricSlice d STIME)
  io_tlast ← io ⍉ ⟨1,2,0⟩
  cpu_tlast ← cpu ⍉ ⟨1,2,0⟩
  n ← ¯1 ⊑ ≢ io_tlast
  io_peak ← ⌈´ io_tlast
  cpu_mean ← (+´ cpu_tlast) ÷ n
  (io_peak > io_thresh) ∧ (cpu_mean < cpu_thresh)
}

⍝ CPU burst concentrated on a single core.
CpuSingleCoreBurst ← { tensor spike_thresh other_thresh;
  d ← ToDeltas tensor
  cpu ← (MetricSlice d UTIME) + (MetricSlice d STIME)
  cpu_tlast ← cpu ⍉ ⟨1,2,0⟩
  peak ← ⌈´ cpu_tlast
  maxc ← ⌈´ peak
  other ← (+´ peak) - maxc
  valid ← (maxc > spike_thresh) ∧ (other < other_thresh)
  C ← 1 ⊑ ≢ peak
  core_mask ← peak =⌜ maxc
  validC ← valid ⌜⊣ ↕C
  core_mask ∧ validC
}

⍝ Thread explosion: sudden large increases in thread count.
ThreadExplosion ← { tensor delta_thresh;
  threads ← MetricSlice tensor NUM_THREADS
  d ← (1↓threads) - (¯1↓threads)
  tlast ← d ⍉ ⟨1,2,0⟩
  peak ← ⌈´ tlast
  peak > delta_thresh
}

⍝ Density rendering helpers.
Gradient ← " .:-=+*#%@"

Normalize ← { vals;
  r ← ∾ vals
  r2 ← r ∾ (0 = ≠r) ⥊ 0
  mn ← ⌊´ r2
  mx ← ⌈´ r2
  den ← (mx - mn) + (mx = mn)
  (vals - mn) ÷ den
}

MapDensity ← { vals;
  g ← Gradient
  n ← ≠ g
  idx ← ⌊ (Normalize vals) × (n - 1)
  g ⊏ idx
}

⍝ Render a time×pid heatmap for a chosen metric.
DensityMatrix ← { tensor metric_idx;
  metric ← MetricSlice (ToDeltas tensor) metric_idx
  ⍝ Metric has shape T×P×C. Collapse C (take max) to get T×P.
  ⌈´ (metric ⍉ ⟨2,0,1⟩)
}

DensityView ← { tensor metric_idx;
  •Show MapDensity DensityMatrix tensor metric_idx
}

⍝ Example usage:
⍝ rows ← 4096
⍝ cols ← MetricCount
⍝ buf ← (rows‿cols) ⥊ 0
⍝ pids ← rows ⥊ 0
⍝ count ← ts_snapshot buf rows cols pids
