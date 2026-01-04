⍝ TensorScan validation harness (CBQN).
ts ← •Import (•path) ∾ "tensor.bqn"

rows ← 1024
cols ← ts.MetricCount
cores ← ts.CoreCount
t ← 3

snaps ← ts.Capture t rows cols 0.01
all_keys times tensor ← ts.Tensor4D snaps cores

shape ← ≢ tensor
•Show "tensor_shape"
•Show shape

pcount ← 0 ⊑ ≢ all_keys
ok_shape ← shape ≡ t‿pcount‿cols‿cores
•Show "shape_ok"
•Show ok_shape

proc_idx ← ts.PROCESSOR
proc_slice ← ts.MetricSlice (ts.ToDeltas times‿tensor) proc_idx
core_sum ← +´ (proc_slice ⍉ ⟨1,2,0⟩)
hot_ok ← ∧´ (core_sum = 1) ∨ (core_sum = 0)
•Show "onehot_ok"
•Show hot_ok

⍝ Clean up
ts.ts_free_thread_resources 0
