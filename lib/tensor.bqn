⍝ TensorScan FFI bridge (CBQN).
⍝ ts_snapshot signature:
⍝   size_t ts_snapshot(double* out, size_t max_rows, size_t max_cols, int* pid_out)
⍝ Adjust the signature string if your CBQN build uses different type codes.

lib ← •FFI "./libtensorscan.so"

⍝ "p" = pointer, "n" = size_t (native word). Return is size_t.
ts_snapshot ← lib ⟨"ts_snapshot", "pnnP>n"⟩

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

⍝ Take one snapshot into a fresh buffer and return ⟨count, pids, matrix⟩.
Snapshot ← { rows cols;
  buf ← (rows‿cols) ⥊ 0
  pids ← rows ⥊ 0
  count ← ts_snapshot buf rows cols pids
  ⟨count, count ↑ pids, count ↑ buf⟩
}

⍝ Capture T snapshots using fold. Returns a list of ⟨count, pids, matrix⟩.
Capture ← { t rows cols;
  step ← { acc _; acc ∾ ⟨Snapshot rows cols⟩ }
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

⍝ Build a stable PID axis from a list of snapshots.
AllPids ← { snaps;
  ∪ ∾ (1 ⊑¨ snaps)
}

⍝ Align a single snapshot's matrix to the stable PID axis.
AlignSnapshot ← { snap all_pids;
  pids ← 1 ⊑ snap
  mat ← 2 ⊑ snap
  idx ← pids ⊐ all_pids
  valid ← idx < ≠pids
  safe_idx ← idx × valid
  rows ← safe_idx ⊏ mat
  valid × rows
}

⍝ Align a list of snapshots to a stable PID axis.
AlignSeries ← { snaps;
  all_pids ← AllPids snaps
  mats ← {snap; AlignSnapshot snap all_pids}¨ snaps
  ⟨all_pids, mats⟩
}

⍝ Build a T×P×M tensor from aligned matrices.
Tensor3D ← { snaps;
  all_pids mats ← AlignSeries snaps
  T ← ≠mats
  (P‿M) ← ≢ (0 ⊑ mats)
  flat ← ∾ mats
  ⟨all_pids, (T‿P‿M) ⥊ flat⟩
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
⍝ Returns ⟨all_pids, tensor⟩ where tensor is T×P×M×C.
Tensor4D ← { snaps cores;
  all_pids mats ← AlignSeries snaps
  T ← ≠mats
  (P‿M) ← ≢ (0 ⊑ mats)
  expanded ← {mat; ExpandCore mat cores}¨ mats
  flat ← ∾ expanded
  ⟨all_pids, (T‿P‿M‿cores) ⥊ flat⟩
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

⍝ Extract one metric slice. Output: T×P×C.
MetricSlice ← { tensor metric_idx;
  metric_idx ⊏ (tensor ⍉ ⟨2,0,1,3⟩)
}

⍝ Micro-stutter mask: spikes high but low mean over time.
⍝ Returns P×C boolean mask.
MicroStutterMask ← { tensor metric_idx spike_thresh mean_thresh;
  metric ← MetricSlice tensor metric_idx
  tlast ← metric ⍉ ⟨1,2,0⟩
  n ← ¯1 ⊑ ≢ tlast
  mean ← (+´ tlast) ÷ n
  mx ← ⌈´ tlast
  (mx > spike_thresh) ∧ (mean < mean_thresh)
}

⍝ Stealth detection: z-score of per-(P,M,C) stddev vs global stddev.
StealthZ ← { tensor;
  s ← StdT tensor
  r ← ∾ s
  mu ← (+´ r) ÷ ≠ r
  sigma ← √ ((+´ ((r - mu) × (r - mu))) ÷ ≠ r)
  (s - mu) ÷ sigma
}

⍝ Density rendering helpers.
Gradient ← " .:-=+*#%@"

Normalize ← { vals;
  r ← ∾ vals
  mn ← ⌊´ r
  mx ← ⌈´ r
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
  metric ← MetricSlice tensor metric_idx
  +´ metric
}

DensityView ← { tensor metric_idx;
  •Show MapDensity DensityMatrix tensor metric_idx
}

⍝ Example usage:
⍝ rows ← 4096
⍝ cols ← 10
⍝ buf ← rows⥊cols⥊0
⍝ pids ← rows⥊0
⍝ count ← ts_snapshot buf rows cols pids
