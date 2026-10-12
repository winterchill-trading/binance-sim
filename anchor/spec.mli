(** One [-anchor] flag: a reference instrument and the simulated symbol that follows it. *)

open! Core

type t =
  { reference : Market_data.Instrument.t (** e.g. [binance:BTCUSDT] *)
  ; sim_symbol : Exchange_core.Symbol.t (** e.g. [BTCUSDT] *)
  }
[@@deriving sexp_of, equal]

(** Parses [<venue>:<symbol>=<sim-symbol>], e.g. ["binance:BTCUSDT=BTCUSDT"]. The venue is
    case-insensitive; the reference symbol is kept as written (the venue's own name). *)
val of_string : string -> t Or_error.t

(** Inverse of {!of_string}. *)
val to_string : t -> string

val arg_type : t Command.Arg_type.t
