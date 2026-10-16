# AGENTS.md (test/)

Tests for `binance_sim`: order lifecycles through `Adapt` (IOC expiry, FOK, post-only), the
market simulation, and the HTTP and websocket server on a free port.

- The server tests use a fixed clock; keep it fixed so outputs do not depend on wall time.
- `test_guard.ml` drives halts by `Exchange.set_mark` through `Server.mutate` and lifts timed
  halts with a mutable clock; the replay check compares `Server.guard_events` with the
  replayed exchange's drained guard log.
- Run: `dune build --root .. @binance-sim/runtest` from the repository root.
- Promote expect output with `dune promote` only after reading the diff.
