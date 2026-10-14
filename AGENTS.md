# AGENTS.md

## Purpose

A local Binance USD-M Futures simulator: REST under `/fapi`, market streams on `/ws` and
`/stream`, and the listen-key user data stream, built on the shared exchange engine. Clients
such as `binance-client` run against it in tests and in local development.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `binance_sim`: `Adapt` (rules and order objects), `Params`, `Server` (see `lib/AGENTS.md`) |
| `anchor/` | Package `binance-sim-anchor`: the `-anchor` flags, reference sources and anchored state (see `anchor/AGENTS.md`) |
| `bin/` | `binance-sim` executable, default port 3300 (see `bin/AGENTS.md`) |
| `test/` | Expect tests of order lifecycles, HTTP and websocket server tests (see `test/AGENTS.md`) |
| `scripts/` | `anchor-demo.sh`: a short anchored run (see `scripts/AGENTS.md`) |
| `.github/` | CI workflow (see `.github/AGENTS.md`) |
| `binance-sim.opam`, `binance-sim-anchor.opam`, `dune-project` | Two opam packages, generated from `dune-project` |

## Build, test, docs

Run from this directory. The workspace root `..` holds the sibling checkouts and the shared
`dune-workspace`.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @binance-sim/all
opam exec --switch 5.2.0+ox -- dune build --root .. @binance-sim/runtest
DUNE_BUILD_DIR=_build-binance-sim opam exec --switch 5.2.0+ox -- dune build --root .. @binance-sim/all
```

The last line is for parallel work: a private build directory avoids the lock shared with
other repositories in the workspace.

Run the simulator: `dune exec binance-sim -- -port 3300`. Anchored to live Binance mainnet
public streams (no keys): `dune exec binance-sim -- -anchor binance:BTCUSDT=BTCUSDT`.

Standalone (outside the workspace), pin the siblings from GitHub as the CI workflow does, then:

```sh
opam pin add -n -y fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git
# repeat for the other pins in .github/workflows/ci.yml
opam install . --deps-only --with-test
dune build && dune test
```

## Conventions

- Formatting: `dune build --root .. @binance-sim/fmt --auto-promote`, run after the tests pass.
  Never `dune fmt` at the workspace root; it reformats every sibling repository.
- Every module has an `.mli`. Use `open! Core`, labelled arguments and `ppx_jane`.
- `lib/` must not depend on `binance-client`; only `anchor/` does. Its tests depend on this
  library, so a cycle would break the build.
- Simulator behaviour changes are described in `../design/simulators.md` and the README; update
  them with the code.
- Use the `-anchor` flags to test against recorded or live reference data instead of inventing
  market shapes.
- Add a short comment at any non-obvious choice, for example why a publish happens before and
  after each engine mutation.
- Document every public value in its `.mli` with odoc comments.

## Dependencies and dependents

- Depends on: `fixed-decimal`, `exchange-core`, `exchange-core-engine`, `binance-protocol`,
  `order-book`. `anchor/` also needs `market-data`, `price-anchor` and `binance-client`.
- Used by: `binance-client` (tests); `market-maker -venue binance -network local`.
- CI pin order: `fixed-decimal`, `exchange-core`, `parquet`, `market-data`, `order-book`,
  `exchange-core-engine`, `venue-net`, `binance-protocol`, `mm-core`, `price-anchor`,
  `binance-client`.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` action with the pins above (its opam switch is
cached between runs), then `dune build` and `dune test`. The `obj-magic` job calls the shared
reusable workflow. To check a run: `gh run list --limit 1`, then at most one
`gh run watch <id> --exit-status`. Do not poll in a loop.

## Pitfalls

- Binance depth sequencing (`U = pu + 1`) needs events published both before and after each
  engine mutation, or `GET /depth` lags the book.
- Flush pending order book deltas before a new websocket subscriber registers, or its first
  message is a delta instead of the snapshot.
- In this Async version `Bus.iter_exn` does not exist; use `Bus.subscribe_permanently_exn`.
- `Cohttp.Code.meth` has no `equal`; use `Poly.equal`.
- Per-connection ping timers stop on close: `Clock_ns.every ~start ~stop:(Pipe.closed w)`.
- The simulator does not check signatures, rate limits or ban state. Do not write tests that
  rely on them failing.

## Where to read more

- `README.md` (endpoints, anchoring, differences from Binance, known gaps).
- `../specs/repos/binance-sim.md` and `../specs/design/simulators.md`.
- `../specs/design/price-anchor.md` for the anchoring design.
- Skills in `../oxcaml-claude-skills/skills/`: `async-http-websocket`, `janestreet-ocaml-style`.
- `../oxcaml-claude-skills/AGENTS.md`: the workspace-wide guide.
- `../oxcaml-claude-skills/GOTCHAS.md`: the dated log these pitfalls come from.

## Never do

- Run `opam install`, `opam upgrade` or `opam pin` on the shared `5.2.0+ox` switch without a
  dry run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`. Abort if the plan touches
  `ocaml-variants`, `core`, `base`, `async` or `ppx_jane`.
- Publish, tag or release a version from this repository without the maintainers asking.
- Commit credentials or print secrets.
- Poll CI in a loop.
