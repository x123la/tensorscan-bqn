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
ts_core_count ← lib ⟨"ts_core_count", "n>n"⟩
ts_usleep ← lib ⟨"ts_usleep", "n>"⟩

CoreCount ← ts_core_count 0

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

CounterMetrics ← ⟨UTIME, STIME, VOL_CTX_SWITCHES, NONVOL_CTX_SWITCHES,
  IO_READ_BYTES, IO_WRITE_BYTES⟩

⍝ Take one snapshot into a fresh buffer and return ⟨count, pids, matrix⟩.
Snapshot ← { rows cols;
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  count ← ts_snapshot buf rows cols pids
  ⟨count, count ↑ pids, count ↑ buf⟩
}

⍝ Capture T snapshots using fold. Returns a list of ⟨count, pids, matrix⟩.
Capture ← { t rows cols;
  step ← { acc _;
    ts_usleep 10000
    acc ∾ ⟨Snapshot rows cols⟩
  }
  ⟨⟩ step´ ↕t
}

⍝ Extract the processor/core-id column from a snapshot matrix.
CoreIds ← { mat proc_idx;
  proc_idx ⊏ ⍉ mat
}

⍝ One-hot encode core ids for a snapshot.
⍝ Output shape: P×C (P processes, C cores).
CoreOneHot ← { mat proc_idx cores;
  (CoreIds mat proc_idx) =⌜ ↕cores
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
  rows ← idx ⊏ mat0
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
  per_metric ← {i;
    sel ← i = PROCESSOR
    col ← i ⊏ ⍉ mat
    broad ← col ⌜⊣ ↕cores
    sel × core_hot + (1 - sel) × broad
  }¨ ↕M
  tmp ← (M‿P‿cores) ⥊ ∾ per_metric
  tmp ⍉ ⟨1,0,2⟩
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
    delta ← 0 ⌈ (di × pairC)
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
⍝ cols ← 11
⍝ buf ← rows⥊cols⥊0
⍝ pids ← rows⥊0
⍝ count ← ts_snapshot buf rows cols pids
