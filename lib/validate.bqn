⍝ TensorScan validation harness (CBQN).
ts ← •Import "./tensor.bqn"

rows ← 1024
cols ← ts.MetricCount
cores ← ts.CoreCount
t ← 3

snaps ← ts.Capture t rows cols
all_keys tensor ← ts.Tensor4D snaps cores

shape ← ≢ tensor
•Show "tensor_shape"
•Show shape

pcount ← 0 ⊑ ≢ all_keys
ok_shape ← shape ≡ t‿pcount‿cols‿cores
•Show "shape_ok"
•Show ok_shape

proc_idx ← ts.PROCESSOR
proc_slice ← ts.MetricSlice tensor proc_idx
core_sum ← +´ (proc_slice ⍉ ⟨1,2,0⟩)
hot_ok ← ∧´ (core_sum = 1) ∨ (core_sum = 0)
•Show "onehot_ok"
•Show hot_ok
