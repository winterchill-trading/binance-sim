(** Binance USD-M Futures front end of the venue-neutral engine
    ({!Exchange_core_engine.Exchange}): Binance's universe and trading rules, request
    validation with Binance error codes, and conversions from the engine's results, views
    and events to {!Binance_protocol} records.

    The engine counts time in nanoseconds; every Binance-facing timestamp is reported in
    milliseconds. Accounts are identified by their API key ({!Exchange_core.Account.t}).

    Unlike the engine, Binance reports order attributes the engine does not keep (order
    type, time in force, reduce-only, cumulative quote, a client order id for every order)
    and streams cumulative fill state in [ORDER_TRADE_UPDATE]. {!t} keeps that per-order
    state next to the exchange; it must see every engine event once, in order, through
    {!user_events}. *)

open! Core
open! Binance_protocol
module Exchange := Exchange_core_engine.Exchange
module Event := Exchange_core_engine.Event
module Account_id := Exchange_core.Account

(** {2 Universe} *)

module Spec : sig
  (** Binance trading rules of one symbol. *)
  type t =
    { symbol : Symbol.t
    ; base_asset : string
    ; tick_size : Price.t (** [PRICE_FILTER.tickSize] *)
    ; min_price : Price.t
    ; max_price : Price.t
    ; step_size : Size.t (** [LOT_SIZE.stepSize], a power of ten *)
    ; min_qty : Size.t
    ; max_qty : Size.t (** limit orders *)
    ; market_max_qty : Size.t (** [MARKET_LOT_SIZE.maxQty] *)
    ; min_notional : Usd.t (** [MIN_NOTIONAL.notional]; reduce-only orders are exempt *)
    ; price_precision : int (** more decimals than this is [-1111] *)
    ; quantity_precision : int
    ; max_leverage : int
    }
  [@@deriving sexp_of]

  (** BTCUSDT (tick 0.1, step 0.001, min notional 100, precision 2/3, 125x), ETHUSDT
      (0.01, 0.001, 20, 2/3, 100x), SOLUSDT (0.01, 1, 5, 4/0, 100x). *)
  val default_universe : t list

  (** Size decimals from the step size, the tick, no significant-figure limit, {!fees}. *)
  val instrument : t -> Exchange_core.Instrument.t
end

(** Binance's base (VIP 0) USD-M fees: taker 5 bps, maker 2 bps. *)
val fees : Exchange_core.Fee_schedule.t

(** Funding every 8 hours. *)
val funding_interval_ns : int

(** {!Exchange_core_engine.Exchange.Config.default} with the instruments of [universe]
    (default {!Spec.default_universe}), 8-hourly funding at 0.01%, and no engine-wide
    minimum order value (Binance's minimum is per symbol and checked here). *)
val config : ?universe:Spec.t list -> unit -> Exchange.Config.t

type t

(** [exchange] must use the instruments of [universe] (default {!Spec.default_universe});
    without [exchange] a fresh one is created with {!config}. *)
val create : ?universe:Spec.t list -> ?exchange:Exchange.t -> unit -> t

val exchange : t -> Exchange.t
val universe : t -> Spec.t list
val spec : t -> Symbol.t -> Spec.t option

(** Current exchange time in milliseconds. *)
val now_ms : t -> Timestamp_ms.t

(** {2 Orders} *)

(** Validates the request against the symbol's rules, then places it on the engine.

    - [LIMIT] needs [price] and [timeInForce]: [GTC], [IOC], [FOK] (checked against the
      book's depth up to the limit price, then sent as IOC) and [GTX] (post only). [GTD]
      and [RPI] are rejected with [-1115].
    - [MARKET] is an IOC order priced 5% through the best opposite price.
    - Without [newClientOrderId] an id ["sim-<n>"] is generated.

    The response is the order's state right after matching (as with
    [newOrderRespType=RESULT]): [NEW], [PARTIALLY_FILLED], [FILLED] or, for an IOC/FOK/
    market remainder, [EXPIRED], with [avgPrice] and [cumQuote]. Rejections are
    {!Api_error.t}s and are recorded in the engine's event log. *)
val new_order
  :  t
  -> Account_id.t
  -> New_order.Request.t
  -> (Order.t, Api_error.t) Result.t

(** Cancels a resting order; [-2011 Unknown order sent.] if it is not one. *)
val cancel_order
  :  t
  -> Account_id.t
  -> Cancel_order.Request.t
  -> (Order.t, Api_error.t) Result.t

(** Cancels every resting order of the account in [symbol]. *)
val cancel_all
  :  t
  -> Account_id.t
  -> Symbol.t
  -> (Cancel_all.Response.t, Api_error.t) Result.t

(** Resting orders, oldest first. *)
val open_orders : ?symbol:Symbol.t -> t -> Account_id.t -> Open_order.t list

(** Trades of the account in [symbol], oldest first: those of [order_id] if given, from
    trade id [from_id] if given, the last [limit] (default 500) otherwise. *)
val user_trades
  :  ?order_id:Order_id.t
  -> ?from_id:int
  -> ?limit:int
  -> t
  -> Account_id.t
  -> symbol:Symbol.t
  -> User_trade.t list

(** {2 Rejections} *)

(** The Binance error for an engine rejection: [-1121] unknown symbol, [-1111] invalid
    size, [-4014] off-tick price, [-4116] duplicate client order id, [-2022] reduce-only,
    [-4164] min notional, [-2010] insufficient margin, [-2020] IOC/market without
    liquidity, [-2010] self-trade, [-5022] GTX would match, [-2011] unknown order. *)
val api_error_of_reject : Exchange_core.Reject_reason.t -> Api_error.t

val error : Api_error.Code.t -> string -> Api_error.t

(** {2 Account} *)

(** [GET /fapi/v2/account]: one USDT asset and one position per symbol (flat ones
    included). Initial margin includes margin held by resting orders, and
    [availableBalance] is margin balance minus all initial margin. *)
val account : t -> Account_id.t -> Account.t

(** [GET /fapi/v2/positionRisk]: one entry per symbol (or just [symbol]), cross margin. *)
val position_risk : ?symbol:Symbol.t -> t -> Account_id.t -> Position_risk.t list

(** {2 Market data} *)

(** [lastUpdateId] is supplied by the caller (the server's book sequence). *)
val depth : t -> Symbol.t -> limit:int -> last_update_id:int -> Depth.t option

val depth_of_l2
  :  Exchange_core.L2.t
  -> last_update_id:int
  -> now:Timestamp_ms.t
  -> Depth.t

val book_ticker : t -> Symbol.t -> Book_ticker.t option

(** Mark price (the engine's: last [set_mark], else last trade, else mid; ["0"] when the
    book has never traded), index price equal to the mark, the last funding rate charged
    (or the configured rate) and the next 8-hour boundary. *)
val premium_index : t -> Symbol.t -> Premium_index.t option

val exchange_info : t -> Exchange_info.t

(** {2 Streams} *)

(** The [aggTrade] event of a fill (one aggregate trade per fill; [a], [f] and [l] are the
    trade id). *)
val agg_trade : Order_book.Fill.t -> Agg_trade.t

val book_ticker_event : t -> Symbol.t -> update_id:int -> Book_ticker_event.t option
val mark_price_update : t -> Symbol.t -> Mark_price_update.t option

(** [depthUpdate] with absolute quantities at [prices] on each side (zero for an empty
    level). *)
val depth_update
  :  t
  -> Symbol.t
  -> bids:Price.t list
  -> asks:Price.t list
  -> first_update_id:int
  -> final_update_id:int
  -> prev_final_update_id:int
  -> Depth_update.t

(** The top [levels] of the book as a [depthUpdate] (partial depth stream). *)
val partial_depth
  :  t
  -> Symbol.t
  -> levels:int
  -> first_update_id:int
  -> final_update_id:int
  -> prev_final_update_id:int
  -> Depth_update.t

(** The user data events an engine event produces, per account, in order:
    [ORDER_TRADE_UPDATE] ([NEW] when an order first appears, [TRADE] per fill, [CANCELED],
    [EXPIRED] for IOC remainders and [EXPIRED_IN_MATCH] for self-trade prevention) and
    [ACCOUNT_UPDATE] (reason [ORDER] after fills and liquidations, [FUNDING_FEE] after
    funding). Rejections produce nothing. Must be called once per event, in order: it
    updates the per-order fill state and the last funding rates. Events are only built for
    accounts satisfying [interested] (default: all), e.g. those with an open user data
    stream. *)
val user_events
  :  ?interested:(Account_id.t -> bool)
  -> t
  -> Event.t
  -> (Account_id.t * User_event.t) list
