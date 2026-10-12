(** HTTP and websocket front end for the venue-neutral engine
    ({!Exchange_core_engine.Exchange}, translated by {!Adapt}), speaking Binance's USD-M
    Futures API on a single port.

    REST (JSON responses, errors as [{"code", "msg"}] with status 400, or 401 without an
    API key):
    - public: [GET /fapi/v1/ping], [/fapi/v1/time], [/fapi/v1/exchangeInfo],
      [/fapi/v1/depth], [/fapi/v1/ticker/bookTicker], [/fapi/v1/premiumIndex];
    - signed: [POST]/[DELETE /fapi/v1/order], [POST /fapi/v1/batchOrders],
      [DELETE /fapi/v1/allOpenOrders], [GET /fapi/v1/openOrders], [/fapi/v1/userTrades],
      [/fapi/v2/account], [/fapi/v2/positionRisk];
    - user stream: [POST]/[PUT]/[DELETE /fapi/v1/listenKey].

    Authentication: the [X-MBX-APIKEY] header names the account; any key is accepted and
    credited [Config.initial_balance] on first use. Signatures are not verified, but
    signed endpoints require a [timestamp] parameter ([-1102] otherwise). Parameters come
    from the query string and, except for [GET], from a form-encoded body (the query
    string wins).

    Websocket (same port, [Upgrade: websocket]):
    - [/ws/<stream>[/<stream>...]] sends raw payloads, [/stream?streams=<a>/<b>] wraps
      them as [{"stream", "data"}]; [/ws] alone starts with no stream;
    - [SUBSCRIBE], [UNSUBSCRIBE] and [LIST_SUBSCRIPTIONS] requests;
    - streams [<symbol>@depth[@100ms|@250ms|@500ms]] (diff depth),
      [<symbol>@depth<5|10|20>[@...]] (partial depth), [<symbol>@aggTrade],
      [<symbol>@bookTicker], [<symbol>@markPrice[@1s]];
    - a listen key as a stream name ([/ws/<listenKey>]) delivers that account's
      [ORDER_TRADE_UPDATE] and [ACCOUNT_UPDATE] events;
    - the server sends a ping frame every [Config.ping_interval].

    Depth sequencing: every engine event that touches a book increments that symbol's
    update id; [GET /fapi/v1/depth] reports it as [lastUpdateId]. Diff depth events are
    flushed every [Config.depth_interval] with [U = pu + 1], [u] the current update id,
    [pu] the previous event's [u], and the absolute quantity of every level touched since
    the previous event (all depth streams of a symbol share one flush).

    The exchange is owned by the server and mutated only from the Async scheduler thread;
    every mutation goes through {!mutate}. *)

open! Core
open! Async
open! Binance_protocol

module Config : sig
  type t =
    { initial_balance : Usd.t (** credited to each API key on first use *)
    ; depth_interval : Time_ns.Span.t (** diff and partial depth flush period *)
    ; mark_price_interval : Time_ns.Span.t
    (** period of [@markPrice@1s]; [@markPrice] gets every third *)
    ; step_interval : Time_ns.Span.t
    (** period of the clock step that charges funding and liquidates *)
    ; ping_interval : Time_ns.Span.t (** websocket ping frames *)
    }
  [@@deriving sexp_of]

  (** $1,000,000, 100ms, 1s, 1s, 3 minutes. *)
  val default : t
end

type t

(** [now] returns the current time in nanoseconds since the epoch (default: the wall
    clock). The exchange is stepped to [now ()] before each request. Tests pass a constant
    to make timestamps deterministic. *)
val create : ?config:Config.t -> ?now:(unit -> int) -> Adapt.t -> t

val config : t -> Config.t
val adapt : t -> Adapt.t

(** Credits [initial_balance] to [account] unless it has been seen before. *)
val ensure_account : t -> Exchange_core.Account.t -> unit

(** Steps the exchange clock, publishes pending events, runs [f], then publishes the
    events it produced (book sequence numbers, websocket streams, user data streams). *)
val mutate : t -> f:(Adapt.t -> 'a) -> 'a

(** The book sequence number reported as [lastUpdateId]. *)
val last_update_id : t -> Symbol.t -> int

(** {2 Network} *)

(** Starts the HTTP/websocket server; [port] 0 picks a free port (see {!port}). Does not
    start the periodic tasks. *)
val listen
  :  t
  -> port:int
  -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t

val port : (Socket.Address.Inet.t, int) Cohttp_async.Server.t -> int

(** Starts the periodic tasks: mark price broadcasts and clock steps. *)
val start_periodic : t -> unit

(** Calls {!Exchange_core_engine.Market_sim.tick} every [tick_interval] through {!mutate}. *)
val run_market_sim : t -> Exchange_core_engine.Market_sim.t -> unit

val num_ws_connections : t -> int
