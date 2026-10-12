open! Core
open! Binance_protocol
open! Binance_sim
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Market_sim = Exchange_core_engine.Market_sim

let run ~seed ~ticks =
  let adapt = Adapt.create () in
  let exchange = Adapt.exchange adapt in
  let sim =
    Market_sim.create
      { Market_sim.Config.default with
        seed
      ; noise_traders = 4
      ; initial_prices = Adapt.initial_prices
      }
      exchange
  in
  let counts = String.Table.create () in
  for i = 1 to ticks do
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    List.iter (Exchange.drain_events exchange) ~f:(fun e ->
      let user_events = Adapt.user_events adapt e in
      List.iter user_events ~f:(fun (_, u) ->
        Hashtbl.incr
          counts
          (match u with
           | Order_trade_update { order; _ } ->
             sprintf
               "ORDER_TRADE_UPDATE %s/%s"
               (Execution_type.to_wire order.execution_type)
               (Order_status.to_wire order.status)
           | Account_update _ -> "ACCOUNT_UPDATE"
           | Listen_key_expired _ | Unknown _ -> "other"));
      match e with
      | Order_rejected { reason; _ } ->
        Hashtbl.incr counts ("rejected: " ^ (Adapt.api_error_of_reject reason).msg)
      | _ -> ())
  done;
  adapt, sim, counts
;;

let%expect_test "noise traders keep two-sided books on the Binance universe" =
  let adapt, sim, counts = run ~seed:7 ~ticks:200 in
  List.iter (Adapt.universe adapt) ~f:(fun spec ->
    let depth =
      Option.value_exn (Adapt.depth adapt spec.symbol ~limit:5 ~last_update_id:0)
    in
    print_s
      [%message
        ""
          ~symbol:(spec.symbol : Symbol.t)
          ~reference:(Market_sim.reference_price sim spec.symbol : Price.t option)
          ~best_bid:(List.hd depth.bids : Book_level.t option)
          ~best_ask:(List.hd depth.asks : Book_level.t option)]);
  print_s
    [%sexp
      (Hashtbl.to_alist counts |> List.sort ~compare:[%compare: string * int]
       : (string * int) list)];
  [%expect
    {|
    ((symbol BTCUSDT) (reference (99798.5))
     (best_bid (((price 99764.9) (qty 0.019))))
     (best_ask (((price 99853.3) (qty 0.063)))))
    ((symbol ETHUSDT) (reference (3510.73))
     (best_bid (((price 3507.9) (qty 0.427))))
     (best_ask (((price 3509.21) (qty 0.026)))))
    ((symbol SOLUSDT) (reference (150.15)) (best_bid (((price 150.17) (qty 49))))
     (best_ask (((price 150.25) (qty 33)))))
    ((ACCOUNT_UPDATE 132) ("ORDER_TRADE_UPDATE CANCELED/CANCELED" 631)
     ("ORDER_TRADE_UPDATE EXPIRED/EXPIRED_IN_MATCH" 7)
     ("ORDER_TRADE_UPDATE NEW/NEW" 791) ("ORDER_TRADE_UPDATE TRADE/FILLED" 97)
     ("ORDER_TRADE_UPDATE TRADE/PARTIALLY_FILLED" 35)
     ("rejected: Order would immediately match against an order of the same account."
      13)
     ("rejected: Unable to fill." 2))
    |}]
;;

let%expect_test "same seed, same run" =
  let digest seed =
    let adapt, _, _ = run ~seed ~ticks:50 in
    List.map (Adapt.universe adapt) ~f:(fun spec -> Adapt.book_ticker adapt spec.symbol)
  in
  print_s [%sexp ([%equal: Book_ticker.t option list] (digest 3) (digest 3) : bool)];
  [%expect {| true |}];
  print_s [%sexp ([%equal: Book_ticker.t option list] (digest 3) (digest 4) : bool)];
  [%expect {| false |}]
;;
