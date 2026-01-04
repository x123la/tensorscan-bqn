⍝ Minimal TensorScan demo runner (CBQN).
ts ← •Import "./tensor.bqn"

rows ← 4096
cols ← ts.MetricCount
cores ← ts.CoreCount

buf ← (rows‿cols) ⥊ 0
pids ← rows ⥊ 0

count ← ts.ts_snapshot buf rows cols pids

show_rows ← count⌊rows

•Show "rows_filled"
•Show show_rows
•Show "sample_pids"
•Show show_rows ↑ pids
•Show "sample_metrics"
•Show show_rows ↑ buf

⍝ Time-series capture + heatmap
snaps ← ts.Capture 5 rows cols
_keys tensor ← ts.Tensor4D snaps cores
•Show "utime_density"
ts.DensityView tensor ts.UTIME
