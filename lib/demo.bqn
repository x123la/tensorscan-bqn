# Minimal TensorScan demo runner (CBQN).
ts ← •Import (•path) ∾ "/tensor.bqn"

rows ← 4096
cols ← ts.MetricCount 0
cores ← ts.CoreCount 0

buf ← (rows‿cols) ⥊ 0
pids ← rows ⥊ 0

count ← ts.TsSnapshot buf‿rows‿cols‿pids

show_rows ← count⌊rows

•Show "rows_filled"
•Show show_rows
•Show "sample_pids"
•Show show_rows ↑ pids
•Show "sample_metrics"
•Show show_rows ↑ buf

# Time-series capture + heatmap
snaps ← ts.Capture 5‿rows‿cols‿0.01
_keys‿times‿tensor ← ts.Tensor4D snaps‿cores
•Show "utime_density"
ts.DensityView times‿tensor‿ts.utime

# Clean up thread-local C buffers
ts.TsFreeThreadResources 0
