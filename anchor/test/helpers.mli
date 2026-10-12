(** Shared setup for the anchor tests. *)

open! Core
open! Async

(** An anchored simulator: an exchange with the Binance configuration whose inputs are
    recorded, and a server on it with a fixed clock ([now]) unless [now] is given. *)
type sim =
  { server : Binance_sim.Server.t
  ; exchange : Exchange_core_engine.Exchange.t
  ; inputs : Exchange_core_engine.Input.t Queue.t
  }

val start_ns : int
val create_sim : ?now:(unit -> int) -> unit -> sim

(** Places a [LIMIT] order through the Binance adapter for account [key], credited first. *)
val place
  :  sim
  -> key:string
  -> side:string
  -> tif:string
  -> price:string
  -> qty:string
  -> unit

(** True when replaying [inputs] on a fresh exchange gives the same mark, book and
    [accounts]' open orders and positions. *)
val replay_matches : sim -> accounts:string list -> bool

(** The top [n] levels of the simulated book, one line per level. *)
val print_book : ?n:int -> sim -> unit

(** [status] without the fields that depend on the wall clock. *)
val print_status : Yojson.Safe.t -> unit
