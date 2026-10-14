# AGENTS.md (anchor/)

Package `binance-sim-anchor`: makes the simulator follow a reference market.

- `Spec` parses the `-anchor VENUE:SYMBOL=SIM` flags; `Reference` builds the sources (live feed,
  raw minute files, normalized logs); `Anchored` steps one `Price_anchor.Anchor.t` per flag on
  the server clock.
- A recorded source steps the clock at `-anchor-speed` times wall time, so funding and staleness
  stay in recorded time. Keep that rule when you change the clock hook.
- `test/` runs against a recorded minute under `test/fixtures/raw/`. Fixtures are data.
- Build: `dune build --root .. @binance-sim/all` from the repository root.
