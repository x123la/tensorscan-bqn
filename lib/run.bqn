#!/usr/bin/env bqn

# Opinionated CLI: Uses specific flags rather than positional chaos.
# Usage: bqn lib/run.bqn --rows 4096 --duration 5 --interval 0.01

ts ← •Import (•path) ∾ "/tensor.bqn"

# 1. Parse Arguments
raw_args ← •Args
ParseArg ← {
  key‿default ← 𝕩
  idx ← raw_args ⊐ ⟨key⟩
  idx < ≠raw_args ? •ParseFloat (idx+1) ⊑ raw_args ; default
}

rows     ← ParseArg "--rows"‿4096
duration ← ParseArg "--duration"‿5     # Seconds
interval ← ParseArg "--interval"‿0.01  # Seconds

# 2. Derive Parameters
cols  ← ts.MetricCount 0
cores ← ts.CoreCount 0
steps ← ⌊ duration ÷ interval

•Show "TensorScan Config:"
•Show ⟨"Rows:", rows, "Duration:", duration, "Interval:", interval, "Steps:", steps⟩

# 3. Execution
•Show "Starting Capture..."
snaps ← ts.Capture steps‿rows‿cols‿interval

# 4. Processing (Standard Pipeline)
_keys‿times‿tensor ← ts.Tensor4D snaps‿cores

•Show "Capture Complete. Generating Density View for utime..."
ts.DensityView times‿tensor‿ts.utime

ts.TsFreeThreadResources 0
