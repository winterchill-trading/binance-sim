open! Core

type t =
  { reference : Market_data.Instrument.t
  ; sim_symbol : Exchange_core.Symbol.t
  }
[@@deriving sexp_of, equal]

let of_string s =
  let error msg = Or_error.error_s [%message msg ~anchor:(s : string)] in
  match String.lsplit2 s ~on:'=' with
  | None -> error "expected <venue>:<symbol>=<sim-symbol>"
  | Some (reference, sim_symbol) ->
    (match String.lsplit2 reference ~on:':' with
     | None -> error "expected <venue>:<symbol> before '='"
     | Some (venue, symbol) ->
       if String.is_empty symbol || String.is_empty sim_symbol
       then error "empty symbol"
       else (
         match Market_data.Venue.of_string_opt (String.lowercase venue) with
         | None -> error "unknown venue"
         | Some venue ->
           Ok
             { reference = Market_data.Instrument.create venue symbol
             ; sim_symbol = Exchange_core.Symbol.of_string sim_symbol
             }))
;;

let to_string t =
  Market_data.Instrument.to_string t.reference
  ^ "="
  ^ Exchange_core.Symbol.to_string t.sim_symbol
;;

let arg_type = Command.Arg_type.create (fun s -> Or_error.ok_exn (of_string s))
