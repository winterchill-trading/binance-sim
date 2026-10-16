# Changes

Notable changes to the two packages of this repository (`binance-sim` and
`binance-sim-anchor`). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) (before 1.0.0, a minor version may break the API).

## Unreleased

### Added

- The engine's price collar and halt rule as flags: `-collar-bps N` or `-collar-ticks N`,
  `-collar-reference last|mid|mark` (default last, mark with `-anchor`),
  `-collar-action reject|reprice`, `-halt-levels PERCENT:DURATION,...` (e.g.
  `7:15m,13:15m,20:reopen`) and `-halt-scope market|symbol`. All off by default.
- `Guard`: the flag settings, applying them to an exchange through its recorded calls, and
  the guard status JSON.
- `GET /sim/guard` (collar bounds, halt rule, halted symbols, counters, the last 50 guard
  events) and `POST /sim/reopen[?symbol=...]`.
- `Server.guard_events`; the server drains the engine's guard log on every mutation and
  logs each event.
- Collar rejections are `-4016 Limit price can't be higher than <bound>.` (buy) and
  `-4024 Limit price can't be lower than <bound>.` (sell); halt rejections are
  `-2010 Trading is halted.`.
- With a basis-point collar, `PERCENT_PRICE` in `exchangeInfo` shows its band.
- `scripts/collar-e2e.sh`: market-maker against a collared simulator, then a check of the
  `-4016` mapping.
- Tests: guard flags, error mapping, status, reopening, and journal replays of the guard
  log (plain and anchored to a recorded minute).

### Compatibility

- Without the new flags, responses, `exchangeInfo` and journals are unchanged.

## 0.1.0 (not yet tagged)

First release: the `/fapi` REST API, market and user data websocket streams, a seeded
market simulation, and anchoring to live or recorded Binance data.
