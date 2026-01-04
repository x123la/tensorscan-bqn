# 🌌 TensorScan-BQN

**Multidimensional Per-Process Observability via C/BQN Synergy**

TensorScan-BQN is a high-performance system monitoring toolkit that bridges the gap between low-level OS telemetry and high-level tensor analysis. By combining a zero-allocation C shim with the array-oriented power of BQN, TensorScan transforms raw `/proc` and `libproc` snapshots into structured, 4D time-series tensors for advanced diagnostic modeling.

---

## 🏗️ Technical Architecture

TensorScan is designed as a layered pipeline, ensuring minimal overhead at the collection layer and maximum flexibility at the analysis layer.

```mermaid
graph TD
    subgraph "OS Layer"
        Linux["/proc File System"]
        macOS["libproc / proc_info"]
    end

    subgraph "Data Acquisition (C Shim)"
        C["libtensorscan.so"]
        Drivers["Platform Drivers (Linux/macOS)"]
        FFI["FFI Layer (C API)"]
    end

    subgraph "Analysis Engine (BQN)"
        BQN["lib/tensor.bqn"]
        Align["PID×StartTime Alignment"]
        Tensor["4D Tensor Construction (T×P×M×C)"]
        Normalization["Time-Delta Normalization"]
    end

    subgraph "Visualization & TUI"
        TUI["lib/top.bqn"]
        Heatmap["DensityView Heatmaps"]
    end

    OS Layer --> Data Acquisition
    Drivers --> FFI
    FFI --> BQN
    BQN --> Visualization & TUI
```

---

## 📊 The Tensor Schema

At the heart of TensorScan is the **4D Tensor**, a multidimensional array that captures the state of the entire system over time.

### **Shape: `Time × PID×StartTime × Metric × Core`**

| Axis | Description | Rationale |
| :--- | :--- | :--- |
| **0: Time** | Sequential snapshots (T) | Enables time-series analysis and delta computation. |
| **1: Identity** | PID paired with StartTime | Prevents PID-reuse collisions; provides stable process identity. |
| **2: Metric** | The 17-gauge metric catalog | Standardized layout for vectorized operations. |
| **3: Core** | CPU Core Affinity (N) | One-hot encoded processor affinity for core-aware diagnostics. |

### **The Metric Catalog**

TensorScan tracks 17 critical metrics per process:

| Index | Metric | Description | Unit |
| :---: | :--- | :--- | :--- |
| `0-1` | `utime`, `stime` | User/System CPU Time | Nanoseconds (Deltas) |
| `2-3` | `rss`, `vsize` | Resident/Virtual Memory | Bytes (Absolute) |
| `4-6` | `threads`, `ctx` | Thread counts & Context Switches | Count |
| `7` | `processor` | Current CPU Core ID | ID (One-hot encoded) |
| `8-9` | `io_r`, `io_w` | Disk Read/Write Bytes | Bytes (Deltas) |
| `10` | `starttime` | Process Start Time | Boot-relative ns |
| `11-12` | `uid`, `ppid` | User/Parent Identifiers | ID |
| `13-16` | `stat` | Priority, Nice, Faults | Various |

---

## 🚀 Getting Started

### **Prerequisites**
- **C Compiler**: `gcc`, `clang`, or `cc`
- **BQN Interpreter**: [CBQN](https://github.com/dzaima/CBQN) recommended.
- **Platforms**: Linux (optimized) or macOS (compatible).

### **Installation**
```bash
git clone https://github.com/Tensorscan-BQN/tensorscan-bqn.git
cd tensorscan-bqn
make
```

### **Running the Live TUI**
Experience real-time multidimensional heatmaps of your system:
```bash
bqn lib/top.bqn --rows 1024 --history 50 --interval 0.2
```

---

## 🧠 BQN API & Analysis

The BQN layer provides powerful primitives for manipulating system tensors.

```bqn
ts ← •Import "lib/tensor.bqn"

# Capture 10 snapshots of 1024 processes
snaps ← ts.Capture 10‿1024‿ts.MetricCount 0‿0.1

# Construct a 4D Tensor with Core expansion
cores ← ts.CoreCount 0
_keys‿times‿tensor ← ts.Tensor4D snaps‿cores

# Detect "Micro-Stutters" (High variance, low mean CPU usage)
mask ← ts.MicroStutterMask times‿tensor‿ts.utime‿1e6‿1e5
```

---

## 💻 Implementation Details

### **C Shim (The "Collector")**
- **Zero-Allocation**: Uses caller-provided buffers to avoid heap fragmentation during high-frequency sampling.
- **Platform Drivers**:
    - **Linux**: Direct parsing of `/proc/[pid]/stat`, `status`, and `io`. Faster than `top` or `ps`.
    - **macOS**: Utilizes `libproc` and `proc_pid_rusage`.

### **BQN Layer (The "Brain")**
- **Stable Alignment**: Processes appear and disappear; the BQN layer aligns them using a composite key `⟨PID, StartTime⟩`.
- **Vectorized Normalization**: Converts cumulative counters (like CPU ticks) into normalized per-second rates using SIMD-friendly array operations.
- **One-Hot Cores**: Scalar core IDs are expanded into a boolean core axis, allowing for simple `+´` reductions to calculate per-core load.

---

## 📜 License
MIT © Tensorscan-BQN Contributors
