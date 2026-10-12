open! Core
open! Async
open! Exchange_core
open! Exchange_core_engine
open Binance_sim

type sim =
  { server : Server.t
  ; exchange : Exchange.t
  ; inputs : Input.t Queue.t
  }

let start_ns = 1_700_000_000_000_000_000
let config = Adapt.config ()

let create_sim ?(now = fun () -> start_ns) () =
  let exchange = Exchange.create ~config () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  let server = Server.create ~now (Adapt.create ~exchange ()) in
  { server; exchange; inputs }
;;

let api_error e = Yojson.Safe.to_string (Binance_protocol.Api_error.yojson_of_t e)

let place sim ~key ~side ~tif ~price ~qty =
  let account = Account.of_string key in
  Server.ensure_account sim.server account;
  let request =
    Params.new_order
      [ "symbol", "BTCUSDT"
      ; "side", side
      ; "type", "LIMIT"
      ; "timeInForce", tif
      ; "price", price
      ; "quantity", qty
      ]
    |> Result.map_error ~f:api_error
    |> Result.ok_or_failwith
  in
  match Server.mutate sim.server ~f:(fun a -> Adapt.new_order a account request) with
  | Ok _ -> ()
  | Error err -> failwith (api_error err)
;;

let btc = Symbol.of_string "BTCUSDT"

let view exchange ~accounts =
  [%sexp
    { mark : Price.t option = Exchange.mark exchange btc
    ; book : L2.t option = Exchange.l2 exchange btc
    ; accounts : (string * Open_order.t list * Account_view.t) list =
        List.map accounts ~f:(fun key ->
          let account = Account.of_string key in
          ( key
          , Exchange.open_orders exchange account
          , Exchange.account_view exchange account ))
    }]
;;

let replay_matches sim ~accounts =
  let replayed = Journal.replay ~config (Queue.to_list sim.inputs) in
  Sexp.equal (view sim.exchange ~accounts) (view replayed ~accounts)
;;

let print_book ?(n = 3) sim =
  match Exchange.l2 ~n_levels:n sim.exchange btc with
  | None -> print_endline "no book"
  | Some l2 -> print_s [%sexp (l2 : L2.t)]
;;

let print_status json =
  let json =
    match json with
    | `Assoc fields ->
      `Assoc
        (List.filter fields ~f:(fun (key, _) ->
           not (List.mem [ "stale_seconds" ] key ~equal:String.equal)))
    | json -> json
  in
  print_endline (Yojson.Safe.pretty_to_string json)
;;
