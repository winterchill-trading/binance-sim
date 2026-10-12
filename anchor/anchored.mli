(** Anchored symbols of a running {!Binance_sim.Server}: one {!Price_anchor.Anchor.t} per
    [-anchor] flag, stepped by the server's clock ({!Binance_sim.Server.on_step}) and fed
    by its reference source on the Async scheduler thread. Each reference item is applied
    to the engine, then the server publishes the events it produced to websocket clients
    ({!Binance_sim.Server.mutate}), so books, trades and marks reach clients as they would
    from simulated order flow. Every change goes through the engine's journaled calls: a
    {!Exchange_core_engine.Journal} replays an anchored run without the reference data. *)

open! Core
open! Async

module Config : sig
  type t =
    { source : Reference.Kind.t
    ; levels : int option (** shadow levels per side (anchor default 5) *)
    ; mark_interval : Time_ns.Span.t option (** anchor default 100ms *)
    ; max_staleness : Time_ns.Span.t option (** anchor default 5s *)
    ; noise_traders : int option
    (** noise traders kept on an anchored symbol (default 0) when the market simulation
        runs *)
    ; price_factor : float option
    ; size_factor : float option
    ; speed : float
    (** recorded sources: [1.] real time, [0.] as fast as websocket clients read; ignored
        for live sources *)
    }
  [@@deriving sexp_of]

  (** Live, the anchor's defaults, speed 1. *)
  val default : t

  (** [-anchor-levels], [-anchor-mark-interval-ms], [-anchor-max-staleness-ms],
      [-anchor-noise], [-anchor-price-factor], [-anchor-size-factor], [-anchor-raw],
      [-anchor-norm], [-anchor-from], [-anchor-to], [-anchor-speed]. *)
  val param : t Command.Param.t
end

type t

(** Creates the anchor of [spec] and starts its source in the background. [source]
    replaces the one [config] names (tests). Fails when the simulated symbol is not
    listed, or the source cannot be opened. *)
val start
  :  ?live_config:Binance_client.Config.Read_only.t
  -> ?market_sim:Exchange_core_engine.Market_sim.t
  -> ?source:Price_anchor.Source.t
  -> Binance_sim.Server.t
  -> Config.t
  -> Spec.t
  -> t Or_error.t Deferred.t

val spec : t -> Spec.t
val anchor : t -> Price_anchor.Anchor.t

(** Determined once the source has closed (end of a recorded range) and its last item has
    been applied and published. *)
val finished : t -> unit Deferred.t

(** The status of one anchor: [reference], [sim_symbol], [source], [state] ([fresh] or
    [stale]), [stale_reason], [stale_seconds] (simulated time spent stale so far),
    [went_stale], [gaps], [events], [ignored], [marks_set], [funding_rates_set],
    [reference_price], [shadow_levels_resting], [shadow] (placed, cancelled, skipped,
    consumed), [replay_fills], [replays_rejected], [source_finished]. *)
val status : t -> Yojson.Safe.t

(** Serves [GET /sim/anchor] with the status of every anchor, as a JSON array. *)
val serve_status : Binance_sim.Server.t -> t list -> unit

(** One info log line per anchor every [interval] (wall clock) with the main counters. *)
val log_status_every : Time_ns.Span.t -> t list -> unit
