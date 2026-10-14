# AGENTS.md (lib/)

Library `binance_sim`: the Binance-shaped front end over the shared engine.

- `Adapt` maps engine outcomes to Binance order objects and error codes. Put a new Binance rule
  here, not in the engine.
- `Params` parses query strings and forms into typed requests and reports Binance's parameter
  errors.
- `Server` runs cohttp-async, the depth sequencing and listen keys. Clock step hooks are the
  only way the anchor drives time.
- No dependency on `binance-client`; the anchor package carries that.
- Build: `dune build --root .. @binance-sim/all` from the repository root.
