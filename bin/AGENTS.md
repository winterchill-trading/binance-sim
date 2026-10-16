# AGENTS.md (bin/)

`binance-sim` executable. Flags are listed in the README and the spec; the default port is
3300. Add a flag in `main.ml` and in the README in the same commit.

- Check the port before starting: a stray listener on 3000 or 3300 makes the new process fail
  silently. Use `lsof -iTCP:3300 -sTCP:LISTEN`.
- Guard flags (`Guard.Config.param`) are applied right after the exchange is created, so an
  input journal attached later must not miss them; keep them off by default.
- Build: `dune build --root .. @binance-sim/all` from the repository root.
