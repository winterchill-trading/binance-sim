(** Where an anchor's reference data comes from: the [-anchor-raw], [-anchor-norm] and
    live sources, opened as a {!Price_anchor.Source.t}. *)

open! Core
open! Async

module Kind : sig
  type t =
    | Live (** the venue client's [Live_feed] *)
    | Raw of
        { dir : string (** the recorder's data directory, containing [raw/] *)
        ; from : Time_ns.t
        ; to_ : Time_ns.t (** exclusive *)
        }
    | Norm of
        { dir : string (** a [norm/] event log directory *)
        ; from : Time_ns.t
        ; to_ : Time_ns.t (** exclusive; whole UTC days are read *)
        }
  [@@deriving sexp_of]

  (** ["live"], ["raw"] or ["norm"]. *)
  val name : t -> string
end

(** Parses a [-anchor-from] / [-anchor-to] value: an ISO 8601 time with a zone
    ([2026-10-12T09:15:00Z]) or a UTC date ([2026-10-12]), which means its first instant
    for [`Start] and the next day's first instant for [`End] (so
    [-anchor-from D -anchor-to D] is the whole day). *)
val parse_time : [ `Start | `End ] -> string -> Time_ns.t Or_error.t

(** The venue's raw frame decoder; only Binance is linked into this binary. *)
val normalizer : Market_data.Venue.t -> Market_data.Normalizer.t Or_error.t

type t =
  { source : Price_anchor.Source.t
  ; close : unit -> unit Deferred.t
  (** stops the source: closes a live feed's connections, or the pipe of a recorded one *)
  }

(** Opens the source of [instrument]. [Live] subscribes to trades, L2 and funding through
    {!Binance_client.Live_feed} with [live_config] (default: mainnet, no keys); other
    venues' live feeds are not linked. *)
val open_
  :  ?live_config:Binance_client.Config.Read_only.t
  -> Kind.t
  -> Market_data.Instrument.t
  -> t Or_error.t Deferred.t

(** A source that {!t.close} closes by closing its pipe. *)
val of_source : Price_anchor.Source.t -> t
