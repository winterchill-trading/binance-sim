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
- **`PRICE_FILTER` min/max and `PERCENT_PRICE`** are published but not enforced.
- **Prices**: the index price equals the mark price; the mark is the engine's (market
  sim reference price when it runs, else last trade, else mid, else `0`). Funding uses
  the configured rate (not a premium index); `ACCOUNT_UPDATE` with `FUNDING_FEE` reports
  it.
- **`ACCOUNT_UPDATE`** carries the account's balances and position as of the end of the
  request that produced the fill, not as of each fill.
- **`aggTrade`** has one trade per aggregate (`a`, `f` and `l` are the trade id).
- **Client ids**: orders sent without `newClientOrderId` get `sim-<n>`.
- Numbers are encoded in their shortest form (`"0"` rather than `"0.00000"`).

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add exchange-core https://github.com/winterchill-trading/exchange-core.git --no-action
opam pin add binance-protocol https://github.com/winterchill-trading/binance-protocol.git --no-action
opam pin add order-book https://github.com/winterchill-trading/order-book.git --no-action
opam pin add exchange-core-engine https://github.com/winterchill-trading/exchange-core.git --no-action
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `fixed-decimal`, `exchange-core`,
`order-book` and `binance-protocol`, dune uses the sibling sources and the pins are not
needed.

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
| `Server` | cohttp-async server for `/fapi` and the `/ws` and `/stream` websockets (async_websocket); owns the engine, depth sequencing, listen keys and the market simulation timer |

All exchange access happens on the Async scheduler thread, so there is no locking.
Before each request the exchange clock is stepped to the wall clock (funding and
liquidation run then and on a 1s timer); events produced by a request are published to
websocket subscribers right after it.

## Tests

`dune test` runs expect tests of order lifecycles through `Adapt` (IOC expiry, FOK,
reduce-only, self-trade prevention, funding), a seeded market simulation on the Binance
universe, and the HTTP and websocket server on a free port with a fixed clock (market
data, orders, cancels, account views, rejections, batch orders, stream subscriptions with
depth sequencing, the user data stream and ping frames).
