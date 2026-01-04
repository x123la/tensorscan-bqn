# TensorScan Tensor Schema (Draft)

This file defines the canonical tensor layout and metric catalog for
TensorScan. It is the contract between the C shim and the BQN analysis layer.

## Tensor Layout

Shape: Time × PID × Metric × Core

- Axis 0 (Time): Sequential snapshots; each snapshot is an interval of fixed
  duration (e.g., 10ms). Stored as index 0..T-1.
- Axis 1 (PID): All active processes observed at snapshot time. The ordering
  is defined by ascending PID within each snapshot.
- Axis 2 (Metric): Metric catalog below; fixed order and stable indices.
- Axis 3 (Core): CPU core index (0..N-1). Metrics that are not per-core are
  broadcast across Core or stored in a separate "core=0" lane; see below.

## PID Ordering and Missing Data

- PID ordering: ascending numeric PID per snapshot.
- Missing PIDs: if a PID disappears between snapshots, its row is absent in the
  snapshot. BQN will align per-snapshot PID lists when constructing a stable
  tensor for analysis.
- PID list: each snapshot is accompanied by a PID vector of length P_t that
  maps rows to real PIDs.

## Metric Catalog (Initial 10)

Index | Name                       | Source                    | Unit
----- | -------------------------- | ------------------------- | ------------------------
0     | utime                      | /proc/[pid]/stat          | clock ticks
1     | stime                      | /proc/[pid]/stat          | clock ticks
2     | rss                        | /proc/[pid]/stat          | bytes
3     | vsize                      | /proc/[pid]/stat          | bytes
4     | num_threads                | /proc/[pid]/status        | count
5     | voluntary_ctxt_switches    | /proc/[pid]/status        | count
6     | nonvoluntary_ctxt_switches | /proc/[pid]/status        | count
7     | processor                  | /proc/[pid]/stat          | core id
8     | io_read_bytes              | /proc/[pid]/io            | bytes
9     | io_write_bytes             | /proc/[pid]/io            | bytes

## Core Axis Policy (Draft)

The "Core" axis represents physical or logical CPU cores. For the initial
implementation, most process metrics are scalar. The policy is:

- Scalar metrics: broadcast across Core when constructing the 4D tensor.
- Core-specific metrics (e.g., processor): stored as one-hot along Core.
  Example: processor = 3 => core lane 3 gets 1, others 0.

This allows core-aware analysis without losing scalar data.

## Normalization Notes (Draft)

Normalization is handled in BQN:
- utime/stime can be converted to CPU time deltas between snapshots.
- io_* metrics can be converted to per-interval deltas.
- rss/vsize are absolute at snapshot time.

## C Shim Contract (Current)

The current C shim (`tensorscan/src/tensorscan.c`) provides a 2D matrix:

- Shape: PID × Metric (row-major)
- Metric order: matches the catalog above
- PID list: optional `int* pid_out` of length P

The time axis will be layered on top by the BQN pipeline in the next phase.
