# binance-sim

Binance USD-M Futures exchange simulator

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core,
Async). binance-sim is a Binance adapter over the venue-neutral engine in
[exchange-core](https://github.com/winterchill-trading/exchange-core)
(`exchange-core-engine`: matching, clearinghouse, margin, funding, liquidation and
synthetic order flow), the Binance counterpart of
[hl-sim](https://github.com/winterchill-trading/hl-sim). Requests and responses use the
wire types from [binance-protocol](https://github.com/winterchill-trading/binance-protocol).

## Running

```sh
dune exec binance-sim -- -port 3300
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `-port` | 3300 | HTTP and websocket port |
| `-seed` | 0 | market simulation random seed |
| `-vol-bps` | 5 | reference price volatility per second, in basis points |
| `-symbols` | all | comma-separated symbols the noise traders trade, e.g. `BTCUSDT,ETHUSDT` |
| `-noise-traders` | 10 | noise trader accounts; 0 disables the market simulation |
| `-initial-balance` | 1000000 | USDT credited to any API key on first use |
| `-log-level` | info | `debug`, `info`, `warn` or `error` |
| `-anchor VENUE:SYMBOL=SIM` | none | follow a reference market (repeatable), see [Anchoring](#anchoring-to-a-reference-market) |
| `-anchor-levels` | 5 | reference levels resting per side |
| `-anchor-mark-interval-ms` | 100 | minimum time between two mark price updates |
| `-anchor-max-staleness-ms` | 5000 | a reference silent for longer is stale |
| `-anchor-noise` | 0 | noise traders kept on anchored symbols |
| `-anchor-price-factor`, `-anchor-size-factor` | 1 | simulated price and size per reference unit |
| `-anchor-raw DIR`, `-anchor-norm DIR` | live | recorded source: raw minute files or event logs |
| `-anchor-from T`, `-anchor-to T` | | recorded range: ISO 8601 time with zone, or a UTC date (a whole day) |
| `-anchor-speed` | 1 | recorded pace: 1 real time, 0 as fast as websocket clients read |
| `-collar-bps N`, `-collar-ticks N` | off | price collar band on every symbol, see [Price collar and halts](#price-collar-and-halts) |
| `-collar-reference` | `last`, `mark` with `-anchor` | `last`, `mid` or `mark`: the price the band is centred on |
| `-collar-action` | `reject` | `reject` or `reprice` an aggressive limit order beyond the band |
| `-halt-levels SPEC` | off | circuit-breaker levels `PERCENT:DURATION,...`, e.g. `7:15m,13:15m,20:reopen` |
| `-halt-scope` | `market` | `market` (a trigger halts every symbol) or `symbol` (only the one that moved) |

Logs go to stderr: fills and liquidations at `info`; every event, request and websocket
request at `debug`.

The universe is BTCUSDT, ETHUSDT and SOLUSDT (see `GET /fapi/v1/exchangeInfo`):

| Symbol | tickSize | stepSize | minNotional | pricePrecision | quantityPrecision | max leverage |
| --- | --- | --- | --- | --- | --- | --- |
| BTCUSDT | 0.1 | 0.001 | 100 | 2 | 3 | 125 |
| ETHUSDT | 0.01 | 0.001 | 20 | 2 | 3 | 100 |
| SOLUSDT | 0.01 | 1 | 5 | 4 | 0 | 100 |

Fees are Binance's base tier (taker 5 bps, maker 2 bps), funding is charged every 8
hours at 0.01% unless changed, and every account trades cross margin in one-way mode at
20x.

### Authentication

Signatures are not verified. The `X-MBX-APIKEY` header is the account: any value is
accepted, and a key seen for the first time is credited `-initial-balance` USDT, so a
client can trade without a deposit flow.

- Signed endpoints (`TRADE`, `USER_DATA`) need the header and a `timestamp` parameter;
  without the header the answer is 401 `-2014`, without `timestamp` 400 `-1102`.
  `recvWindow` and `signature` are accepted and ignored, so a real Binance client that
  signs its requests works unchanged.
- `listenKey` endpoints need only the header.
- Market data endpoints need nothing.

Parameters come from the query string and, for `POST`, `PUT` and `DELETE`, also from an
`application/x-www-form-urlencoded` body; when a key appears in both the query string
wins, as on Binance.

### REST

```sh
curl -s 'localhost:3300/fapi/v1/exchangeInfo'
curl -s 'localhost:3300/fapi/v1/depth?symbol=BTCUSDT&limit=5'
curl -s 'localhost:3300/fapi/v1/ticker/bookTicker?symbol=BTCUSDT'
curl -s 'localhost:3300/fapi/v1/premiumIndex?symbol=BTCUSDT'

# Rest a post-only bid for 0.01 BTC at 99000
curl -s -X POST localhost:3300/fapi/v1/order -H 'X-MBX-APIKEY: alice' \
  -d 'symbol=BTCUSDT&side=BUY&type=LIMIT&timeInForce=GTX&price=99000&quantity=0.01&timestamp=1'

# Buy 0.01 BTC at market
curl -s -X POST localhost:3300/fapi/v1/order -H 'X-MBX-APIKEY: alice' \
  -d 'symbol=BTCUSDT&side=BUY&type=MARKET&quantity=0.01&timestamp=1'

# Two orders at once
curl -s -X POST localhost:3300/fapi/v1/batchOrders -H 'X-MBX-APIKEY: alice' \
  --data-urlencode 'batchOrders=[{"symbol":"BTCUSDT","side":"SELL","type":"LIMIT","timeInForce":"GTC","price":"101000","quantity":"0.01"},{"symbol":"BTCUSDT","side":"SELL","type":"LIMIT","timeInForce":"GTC","price":"102000","quantity":"0.01"}]' \
  -d timestamp=1

curl -s -H 'X-MBX-APIKEY: alice' 'localhost:3300/fapi/v1/openOrders?symbol=BTCUSDT&timestamp=1'
curl -s -X DELETE -H 'X-MBX-APIKEY: alice' 'localhost:3300/fapi/v1/order?symbol=BTCUSDT&orderId=1&timestamp=1'
curl -s -X DELETE -H 'X-MBX-APIKEY: alice' 'localhost:3300/fapi/v1/allOpenOrders?symbol=BTCUSDT&timestamp=1'
curl -s -H 'X-MBX-APIKEY: alice' 'localhost:3300/fapi/v1/userTrades?symbol=BTCUSDT&timestamp=1'
curl -s -H 'X-MBX-APIKEY: alice' 'localhost:3300/fapi/v2/account?timestamp=1'
curl -s -H 'X-MBX-APIKEY: alice' 'localhost:3300/fapi/v2/positionRisk?timestamp=1'
curl -s -X POST -H 'X-MBX-APIKEY: alice' localhost:3300/fapi/v1/listenKey
```

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/fapi/v1/ping`, `/fapi/v1/time` | |
| GET | `/fapi/v1/exchangeInfo` | `PRICE_FILTER`, `LOT_SIZE`, `MARKET_LOT_SIZE`, `MAX_NUM_ORDERS`, `MAX_NUM_ALGO_ORDERS`, `MIN_NOTIONAL`, `PERCENT_PRICE` |
| GET | `/fapi/v1/depth` | `limit` 5, 10, 20, 50, 100, 500 (default) or 1000 |
| GET | `/fapi/v1/ticker/bookTicker`, `/fapi/v1/premiumIndex` | one object with `symbol`, an array without |
| POST | `/fapi/v1/order` | `LIMIT` (`GTC`, `IOC`, `FOK`, `GTX`) and `MARKET`; `reduceOnly`, `newClientOrderId` |
| POST | `/fapi/v1/batchOrders` | up to 5; one order or `{code, msg}` per item |
| DELETE | `/fapi/v1/order` | by `orderId` or `origClientOrderId` |
| DELETE | `/fapi/v1/allOpenOrders` | |
| GET | `/fapi/v1/openOrders` | `symbol` optional |
| GET | `/fapi/v1/userTrades` | `symbol`; `orderId`, `fromId`, `limit` |
| GET | `/fapi/v2/account`, `/fapi/v2/positionRisk` | |
| POST, PUT, DELETE | `/fapi/v1/listenKey` | |

Errors are `{"code": ..., "msg": ...}` with Binance's codes and wording: `-1102` missing
parameter, `-1111` precision, `-1115` time in force, `-1116` order type, `-1117` side,
`-1121` symbol, `-1125` listen key, `-1130` invalid parameter, `-2010` insufficient
margin or self-trade, `-2011` unknown order on cancel, `-2022` reduce-only, `-4003`/`-4005` quantity bounds, `-4014` tick
size, `-4116` duplicate client order id, `-4164` min notional, `-5021` FOK, `-5022` GTX.

### Websocket

Websockets are served on the same port:

```sh
websocat 'ws://localhost:3300/ws/btcusdt@depth@100ms'
websocat 'ws://localhost:3300/stream?streams=btcusdt@aggTrade/btcusdt@bookTicker'
websocat ws://localhost:3300/ws
{"method": "SUBSCRIBE", "params": ["btcusdt@depth5", "ethusdt@markPrice@1s"], "id": 1}
{"method": "LIST_SUBSCRIPTIONS", "id": 2}
{"method": "UNSUBSCRIBE", "params": ["btcusdt@depth5"], "id": 3}

# User data: the key from POST /fapi/v1/listenKey
websocat "ws://localhost:3300/ws/$LISTEN_KEY"
```

`/ws/...` connections get raw payloads, `/stream?streams=...` connections get
`{"stream": ..., "data": ...}`. Requests are answered with `{"result": ..., "id": ...}`,
malformed ones with `{"code": 2 or 3, "msg": ...}`. The server sends a ping frame every
3 minutes.

| Stream | Sent |
| --- | --- |
| `<symbol>@depth`, `@depth@100ms` (also `@250ms`, `@500ms`) | `depthUpdate` diffs, every 100ms when the book changed |
| `<symbol>@depth5`, `@depth10`, `@depth20` (any speed suffix) | top N levels as a `depthUpdate`, with the diffs |
| `<symbol>@aggTrade` | one `aggTrade` per fill, as it happens |
| `<symbol>@bookTicker` | `bookTicker` whenever the best bid or ask changes |
| `<symbol>@markPrice@1s`, `@markPrice` | `markPriceUpdate` every second, every 3 seconds |
| `<listenKey>` | `ORDER_TRADE_UPDATE` and `ACCOUNT_UPDATE` of the key's account |

**Depth sequencing.** Each symbol has an update id that every book-changing engine event
increments; `GET /fapi/v1/depth` returns it as `lastUpdateId`. A diff event covers the
updates since the previous one: `pu` is the previous event's `u`, `U = pu + 1`, `u` the
current update id, and `b`/`a` carry the absolute quantity of every level touched in
between (zero for an emptied level). Binance's local order book procedure applies as
documented: drop events with `u < lastUpdateId`, start at the event with
`U <= lastUpdateId <= u`, then require `pu` to equal the previous `u`. As on Binance, an
idle book sends nothing, so a snapshot taken while idle has no event satisfying the start
rule until the next change, whose `U` is `lastUpdateId + 1`; strict clients fetch the
snapshot again then.

## Anchoring to a reference market

`-anchor binance:BTCUSDT=BTCUSDT` ties the simulated BTCUSDT to Binance's real one through
[price-anchor](https://github.com/winterchill-trading/price-anchor): the mark price and
funding rate follow the reference, the reference's top levels rest in the simulated book
(account `anchor:binance:BTCUSDT`), and simulated resting orders fill when the reference
trades at or through them (IOC orders from `anchor-taker:binance:BTCUSDT`). Clients see
the reference book, trades and marks on the usual REST endpoints and streams. Anchored
symbols get no noise traders unless `-anchor-noise N`; the other symbols keep theirs.
Everything goes through the engine's journaled calls, so the run replays without the
reference data.

```sh
# Live, from Binance mainnet's public streams (no keys)
dune exec binance-sim -- -anchor binance:BTCUSDT=BTCUSDT -anchor binance:ETHUSDT=ETHUSDT

# A recorded hour of market-recorder raw minute files, at real time
dune exec binance-sim -- -anchor binance:BTCUSDT=BTCUSDT \
  -anchor-raw /data/recorder -anchor-from 2026-10-12T09:00:00Z -anchor-to 2026-10-12T10:00:00Z

# A recorded day of normalized event logs, as fast as websocket clients read
dune exec binance-sim -- -anchor binance:BTCUSDT=BTCUSDT \
  -anchor-norm /data/recorder/norm -anchor-from 2026-10-12 -anchor-to 2026-10-12 -anchor-speed 0

curl -s localhost:3300/sim/anchor
```

- **Sources.** Live uses binance-client's `Live_feed` (aggTrade, diff depth with REST
  snapshots, markPrice@1s). `-anchor-raw DIR` reads the recorder's data directory
  (`DIR/raw/binance/...`) through binance-client's `Raw_normalizer`; a recorded disconnect
  makes the anchor stale until the next snapshot. `-anchor-norm DIR` reads `Event_log`
  files of the UTC days the range covers. Only Binance references are linked so far.
- **Time.** The anchor runs on the Async scheduler thread: each reference item is applied,
  then its engine events are published, and every clock step of the server (each request,
  the 1 s timer) calls `Anchor.step` after stepping the exchange. With a recorded source
  the server's clock runs at `-anchor-speed` times the wall clock (frozen at 0, where only
  the reference's `recv_ts` moves time), so funding, staleness and timestamps stay in
  recorded time. Timestamps of a slowed replay fall behind the wall clock; clients that
  check data age need a larger limit (the demo raises market-maker's `max_data_age_ms`).
- **Status.** `GET /sim/anchor` returns one object per anchor: `state` (`fresh` or
  `stale`), `stale_reason`, `stale_seconds` (simulated time spent stale), `went_stale`,
  `gaps`, `events`, `marks_set`, `funding_rates_set`, `reference_price`,
  `shadow_levels_resting`, `shadow` (placed, cancelled, skipped, consumed),
  `replay_fills`, `replays_rejected` and `source_finished`. Fresh/stale transitions are
  logged at `info` as they happen, and an `anchor status` line every 30 s.

```json
[{"reference":"binance:BTCUSDT","sim_symbol":"BTCUSDT","source":"live","state":"fresh",
  "stale_reason":null,"stale_seconds":1.16,"went_stale":1,"gaps":0,"events":105,
  "ignored":0,"marks_set":6,"funding_rates_set":1,"reference_price":"82912.3",
  "shadow_levels_resting":10,"shadow":{"placed":142,"cancelled":132,"skipped":0,
  "consumed":0},"replay_fills":0,"replays_rejected":0,"source_finished":false}]
```

`scripts/anchor-demo.sh [SECONDS]` runs the simulator anchored to the recorded BTCUSDT
minute in `anchor/test/fixtures` (about 6.5 s of trading, slowed to a quarter), connects
market-maker to it, and prints once a second the reference price, the simulated best bid
and ask, and the maker's best quotes. `LIVE=1` anchors to mainnet instead. A run:

```
time     state  reference   sim bid / ask           maker bid / ask         replay fills
+0s      fresh  82613.6     82613.5 / 82613.6       82588.8 / 82638.4       0
+9s      fresh  82620.2     82613.5 / 82613.6       82588.8 / 82638.4       0
+10s     fresh  82620.2     82619.3 / 82619.4       82588.8 / 82638.4       0
+11s     fresh  82620.2     82628.8 / 82628.9       82604 / 82654.9         0
+14s     fresh  82628.9     82635.1 / 82635.2       82604 / 82654.9         0
+17s     fresh  82635.2     82625.1 / 82625.2       82604 / 82654.9         0
```

The reference price is the venue's mark (from markPrice@1s), so it can differ from the
book's mid by a few ticks.

## Price collar and halts

The engine's price collar and halt rule (`Price_collar`, `Halt_rule` in
[exchange-core](https://github.com/winterchill-trading/exchange-core)) are off unless their
flags are given; without them the simulator behaves as before.

```sh
# Aggressive orders more than 0.5% from the last trade are refused; moves of 7% and 13%
# from the session reference halt every symbol for 15 minutes, 20% until reopened.
dune exec binance-sim -- -collar-bps 50 -halt-levels 7:15m,13:15m,20:reopen
```

- **Collar.** A limit order that would trade beyond the band around the reference price
  (last trade by default, the mark when anchored) is rejected, or with
  `-collar-action reprice` stops at the band. Market orders are never rejected: their
  protection price is clamped to the band. Post-only orders are not checked. With a bps
  band, `PERCENT_PRICE` in `exchangeInfo` shows it (`-collar-bps 50`: `multiplierUp`
  1.0050, `multiplierDown` 0.9950); otherwise it stays 1.05/0.95.
- **Halts.** Each symbol's mark is compared with its session reference (the first mark
  seen). A move past a level halts trading for the level's duration (`15m`, `90s`, ...) or
  until `POST /sim/reopen` (`reopen`). While halted, orders that would trade are refused;
  passive orders rest and cancels work. Each level triggers once.
- **`GET /sim/guard`** answers the collar per symbol (reference, band, action, current
  reference price and bounds), the halt rule with the session references, the halted
  symbols (`{"state": "halted", "until": ms}`, `untilReopen`, `reopenPending`), the
  counters (`collarRejected`, `collarRepriced`, `collarUnreferenced`, `haltRejected`,
  `halts`, `reopens`) and the last 50 guard events. Every guard event is also logged at
  `info`.
- **`POST /sim/reopen[?symbol=BTCUSDT]`** lifts the halt of one symbol, or of all of them,
  and answers the same status.

Rejections use Binance's errors:

| Engine outcome | Binance error |
| --- | --- |
| collar, buy beyond the upper bound | `-4016 Limit price can't be higher than <bound>.` (PERCENT_PRICE) |
| collar, sell beyond the lower bound | `-4024 Limit price can't be lower than <bound>.` (PERCENT_PRICE) |
| halted | `-2010 Trading is halted.` (sim-chosen: Binance publishes no halt code for USD-M; `-2010` is its generic order rejection) |

The collar is told apart from an off-tick price (both `Invalid_price` in the engine) by the
engine's guard counter; an off-tick price stays `-4014`.

`scripts/collar-e2e.sh [SECONDS]` runs `market-maker` against a collared simulator, then
checks that an order 2% through the ask gets `-4016`.

## Differences from Binance

- **Auth**: no signature or `recvWindow` checks, no rate limits, no IP or key bans.
  Listen keys never expire (no `listenKeyExpired`).
- **Order types**: only `LIMIT` and `MARKET`; stop, take-profit and trailing orders are
  `-1116`. `GTD` and `RPI` are `-1115`. `priceMatch` and `selfTradePreventionMode` are
  ignored. One-way mode only: `positionSide` `LONG`/`SHORT` is `-4061`. No
  modify/amend, leverage, margin type or order query endpoints.
- **Responses** always carry the post-matching state (as with
  `newOrderRespType=RESULT`), including `avgPrice` and `cumQuote`.
- **IOC/market orders with no fill** get an `EXPIRED` response with `executedQty` `0` and
  a real order id, and the user stream sends nothing for them (they never rest). With a
  partial fill the user stream sends `TRADE` events followed by `EXPIRED`.
- **FOK** is checked against the book's depth up to the limit price, then sent as IOC.
- **Self-trade prevention** is "expire taker": an order whose first match would be
  against the same account is rejected with `-2010`; if it already filled partly, the
  rest expires with `EXPIRED_IN_MATCH`.
- **Insufficient margin** is `-2010 Account has insufficient balance for requested
  action.`; live USD-M may answer `-2019 Margin is insufficient.`
- **Market orders** are IOC orders priced 5% through the best opposite price, and
  `MIN_NOTIONAL` for them is checked at the mark price (skipped when there is none).
- **Reduce-only** orders are clipped to the position size, and reported with the clipped
  `origQty`.
- **`PRICE_FILTER` min/max** are published but not enforced. `PERCENT_PRICE` is enforced
  only with a collar (`-collar-bps`), on the aggressor's side, around one reference price
  (Binance checks the limit against the mark price on both sides).
- **Prices**: the index price equals the mark price; the mark is the engine's (the
  anchor's reference price on anchored symbols, the market sim reference price when it
  runs, else last trade, else mid, else `0`). Funding uses the configured rate (the
  reference's, converted to 8 hours, on anchored symbols), not a premium index;
  `ACCOUNT_UPDATE` with `FUNDING_FEE` reports it.
- **`ACCOUNT_UPDATE`** carries the account's balances and position as of the end of the
  request that produced the fill, not as of each fill.
- **`aggTrade`** has one trade per aggregate (`a`, `f` and `l` are the trade id).
- **Client ids**: orders sent without `newClientOrderId` get `sim-<n>`.
- Numbers are encoded in their shortest form (`"0"` rather than `"0.00000"`).

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
for repo in fixed-decimal exchange-core parquet market-data order-book; do
  opam pin add $repo https://github.com/winterchill-trading/$repo.git --no-action
done
opam pin add exchange-core-engine https://github.com/winterchill-trading/exchange-core.git --no-action
for repo in venue-net binance-protocol mm-core price-anchor binance-client; do
  opam pin add $repo https://github.com/winterchill-trading/$repo.git --no-action
done
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains the siblings, dune uses their sources and the
pins are not needed.

The repository has two opam packages. `binance-sim` is the library (`Adapt`, `Params`,
`Server`) and depends on neither price-anchor nor binance-client, because binance-client's
tests run against it. `binance-sim-anchor` holds the `Binance_sim_anchor` library (the
`-anchor` flags and sources) and the `binance-sim` binary, which links binance-client for
the live feed and the raw-file normalizer.

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## Modules

All modules live under `Binance_sim`. The engine (`Exchange`, `Clearinghouse`, `Event`,
`Market_sim`, ...) is `Exchange_core_engine` from exchange-core; its design notes are in
the [exchange-core README](https://github.com/winterchill-trading/exchange-core).

| Module | Description |
| --- | --- |
| `Adapt` | Binance view of the engine: universe and trading rules, order validation with Binance error codes, order objects, `User_trade`, `Account` (v2), `Position_risk`, `Depth`, `Book_ticker`, `Premium_index`, `Exchange_info`, stream payloads, and the per-order state behind `ORDER_TRADE_UPDATE` |
| `Params` | Query-string and form parameters to `New_order.Request`, `Cancel_order.Request` and batch items, with Binance's parameter errors |
| `Guard` | the `-collar-*` and `-halt-*` flags, applying them to the engine, and the `GET /sim/guard` status |
| `Server` | cohttp-async server for `/fapi` and the `/ws` and `/stream` websockets (async_websocket); owns the engine, depth sequencing, listen keys and the market simulation timer; clock step hooks, extra `GET` routes and websocket `pushback` for the anchor |

`Binance_sim_anchor` (package `binance-sim-anchor`):

| Module | Description |
| --- | --- |
| `Spec` | an `-anchor VENUE:SYMBOL=SIM` value |
| `Reference` | live (`Live_feed`), raw (`Raw_normalizer`) and norm reference sources as `Price_anchor.Source.t`, and the `-anchor-from`/`-anchor-to` time syntax |
| `Anchored` | the anchor flags, the server clock for a replay speed, running an anchor on the server (step hook, apply then publish, client-paced replay at speed 0), `GET /sim/anchor` and the periodic status line |

All exchange access happens on the Async scheduler thread, so there is no locking.
Before each request the exchange clock is stepped to the wall clock (funding and
liquidation run then and on a 1s timer); events produced by a request are published to
websocket subscribers right after it.

## Tests

`dune test` runs expect tests of order lifecycles through `Adapt` (IOC expiry, FOK,
reduce-only, self-trade prevention, funding), a seeded market simulation on the Binance
universe, and the HTTP and websocket server on a free port with a fixed clock (market
data, orders, cancels, account views, rejections, batch orders, stream subscriptions with
depth sequencing, the user data stream and ping frames). `test_guard.ml` covers the
collar and halt flags, the `-4016`/`-4024`/`-2010` errors, `PERCENT_PRICE`, `/sim/guard`,
`/sim/reopen`, and the input journal replaying the guard log.

`anchor/test` checks the anchor flags and the server clock per replay speed, a live anchor
to a second binance-sim on a local port (the reference book rests in the anchored book, a
reference trade fills a client order it trades through, the journal replays the run), and
a recorded Binance minute (`anchor/test/fixtures`, copied from binance-client's fixtures
as raw minute files): two trade-replay fills of a client order, a journal replay that
matches, the same run from event logs rebuilt from those files, and the minute with a
2 bps collar on the mark and a tight halt rule, whose guard log the journal replays.
