# Changelog

## Unreleased

- Fixed `ts_snapshot_delta` buffer overrun when the caller's `max_rows` is
  smaller than the number of processes.
- Corrected `ts_snapshot_delta` parsing in the FFI layer and documented the
  `pid_out` requirement for delta snapshots.
- Updated BQN analysis helpers to pass `times‿tensor` to `ToDeltas`.
- Improved macOS driver safety (buffer length checks, whitelist filtering,
  and sentinel values for missing counters).
- Switched BQN line comments to `#` for CBQN compatibility.
- Updated BQN helpers to follow CBQN naming roles and list-style arguments.
- Expanded documentation to cover the full 17-metric catalog and platform
  notes.
