#!/usr/bin/env bqn

# Opinionated TUI: Live "Top" view using ANSI escapes.
# Usage: bqn lib/top.bqn --rows 1024 --history 50 --interval 0.1

ts ← •Import (•path) ∾ "tensor.bqn"
args ← •Args

# --- Configuration ---
ParseArg ← { key default;
  idx ← args ⊐ ⟨key⟩
  idx < ≠args ? •ParseFloat (idx+1) ⊑ args ; default
}

rows     ← ParseArg "--rows"     1024
history  ← ParseArg "--history"  40    # Number of columns in the heatmap
interval ← ParseArg "--interval" 0.2   # Refresh rate

cols  ← ts.MetricCount
cores ← ts.CoreCount

# --- ANSI Helpers ---
ClearScreen ← { •Out "\033[2J" }
CursorHome  ← { •Out "\033[H" }
HideCursor  ← { •Out "\033[?25l" }
ShowCursor  ← { •Out "\033[?25h" }
ResetColor  ← "\033[0m"

# --- State Initialization ---
# We pre-allocate a list of "history" empty snapshots
# A snapshot is ⟨time, count, pids, matrix⟩
EmptySnap ← ⟨0, 0, ⟨⟩, (0‿cols)⥊0⟩
buffer ← history ⥊ ⟨EmptySnap⟩

# --- The Render Loop ---
Render ← {
  CursorHome 0
  
  # 1. Convert Buffer to Tensor
  # Note: This is computationally heavy. In a C++ app we'd optimize.
  # In BQN, we rely on the interpreter's array speed.
  _ times tensor ← ts.Tensor4D buffer cores
  
  # 2. Header
  cpu_ticks ← ts.TotalCpuTicks 0
  mem_bytes ← ts.MemTotalBytes 0
  header ← "TensorScan Live | Interval: "∾(•Fmt interval)∾"s | History: "∾(•Fmt history)
  •Out header ∾ " | Memory: " ∾ (•Fmt ⌊mem_bytes÷1024÷1024) ∾ " MB"
  •Out (80⥊"-")

  # 3. Visualization: UTIME Heatmap
  # We select UTIME (0). You could toggle this with input later.
  •Out "Metric: UTIME (CPU Usage Density)"
  ts.DensityView (times‿tensor) ts.UTIME
  
  # 4. Visualization: IO Heatmap
  •Out ""
  •Out "Metric: IO_READ_BYTES (Disk Activity)"
  ts.DensityView (times‿tensor) ts.IO_READ_BYTES
  
  •Out ResetColor
}

# --- Main Loop ---
Run ← {
  ClearScreen 0
  HideCursor 0
  
  # Clean up cursor on exit
  _ ← { ShowCursor 0 } •OnExit 0

  •Out "Initializing buffer..."
  
  Loop ← { buf;
    # 1. Capture one frame
    new_snap ← ts.Snapshot rows cols
    
    # 2. Rotate buffer (Drop first, append new)
    next_buf ← (1 ↓ buf) ∾ ⟨new_snap⟩
    
    # 3. Update global buffer for the renderer
    buffer ↩ next_buf
    
    # 4. Render
    Render 0
    
    # 5. Wait
    ts.ts_usleep ⌊ interval × 1e6
    Loop next_buf
  }
  Loop buffer
}

Run 0
