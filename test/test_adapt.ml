open! Core
open! Binance_protocol
open! Binance_sim
module Exchange = Exchange_core_engine.Exchange
module Account_id = Exchange_core.Account

let acct n = Account_id.of_string (sprintf "key-%d" n)
let btc = Symbol.of_string "BTCUSDT"

let fresh () =
  let adapt = Adapt.create () in
  List.iter [ 1; 2; 3 ] ~f:(fun n ->
    Exchange.deposit (Adapt.exchange adapt) (acct n) (Usd.of_int 100_000));
  adapt
;;

let limit ?(tif = Time_in_force.Gtc) ?reduce_only ?cid side px qty =
  New_order.Request.limit
    ~time_in_force:tif
    ?reduce_only
    ?client_order_id:(Option.map cid ~f:Client_order_id.of_string)
    btc
    side
    ~price:(Price.of_string px)
    ~quantity:(Size.of_string qty)
;;

let place adapt n req =
  match Adapt.new_order adapt (acct n) req with
  | Ok (o : Order.t) ->
    printf
      "order %s %s %s qty=%s executed=%s avg=%s\n"
      (Order_id.to_string o.order_id)
      (Client_order_id.to_string o.client_order_id)
      (Order_status.to_wire o.status)
      (Size.to_string o.orig_qty)
      (Size.to_string o.executed_qty)
      (Option.value_map o.avg_price ~default:"-" ~f:Price.to_string)
  | Error (e : Api_error.t) -> printf "error %d %s\n" (Api_error.Code.to_int e.code) e.msg
;;

(* One line per user data event. *)
let print_events adapt =
  List.iter
    (Exchange.drain_events (Adapt.exchange adapt))
    ~f:(fun event ->
      List.iter (Adapt.user_events adapt event) ~f:(fun (account, u) ->
        match u with
        | Order_trade_update { order = o; _ } ->
          printf
            "%s ORDER_TRADE_UPDATE i=%s c=%s x=%s X=%s l=%s z=%s ap=%s n=%s rp=%s\n"
            (Account_id.to_string account)
            (Order_id.to_string o.order_id)
            (Client_order_id.to_string o.client_order_id)
            (Execution_type.to_wire o.execution_type)
            (Order_status.to_wire o.status)
            (Size.to_string o.last_filled_qty)
            (Size.to_string o.cum_filled_qty)
            (Price.to_string o.avg_price)
            (Option.value_map o.commission ~default:"-" ~f:Decimal.to_string)
            (Usd.to_string o.realized_profit)
        | Account_update a ->
          printf
            "%s ACCOUNT_UPDATE %s wb=%s %s\n"
            (Account_id.to_string account)
            (Account_update.Reason.to_wire a.reason)
            (Usd.to_string (List.hd_exn a.balances).wallet_balance)
            (List.map a.positions ~f:(fun p ->
               sprintf
                 "%s:%s@%s"
                 (Symbol.to_string p.symbol)
                 (Size.to_string p.position_amt)
                 (Price.to_string p.entry_price))
             |> String.concat ~sep:" ")
        | Listen_key_expired _ | Unknown _ -> ()))
;;

let%expect_test "IOC remainder expires, FOK fills or is rejected, reduce-only" =
  let adapt = fresh () in
  place adapt 1 (limit Sell "100000" "0.01" ~cid:"maker-1");
  place adapt 1 (limit Sell "100100" "0.01");
  place adapt 2 (limit ~tif:Ioc Buy "100000" "0.02");
  [%expect
    {|
    order 1 maker-1 NEW qty=0.01 executed=0 avg=0
    order 2 sim-1 NEW qty=0.01 executed=0 avg=0
    order 3 sim-2 EXPIRED qty=0.02 executed=0.01 avg=100000
    |}];
  print_events adapt;
  [%expect
    {|
    key-1 ORDER_TRADE_UPDATE i=1 c=maker-1 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    key-1 ORDER_TRADE_UPDATE i=2 c=sim-1 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    key-2 ORDER_TRADE_UPDATE i=3 c=sim-2 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    key-2 ORDER_TRADE_UPDATE i=3 c=sim-2 x=TRADE X=PARTIALLY_FILLED l=0.01 z=0.01 ap=100000 n=0.5 rp=0
    key-2 ACCOUNT_UPDATE ORDER wb=99999.5 BTCUSDT:0.01@100000
    key-1 ORDER_TRADE_UPDATE i=1 c=maker-1 x=TRADE X=FILLED l=0.01 z=0.01 ap=100000 n=0.2 rp=0
    key-1 ACCOUNT_UPDATE ORDER wb=99999.8 BTCUSDT:-0.01@100000
    key-2 ORDER_TRADE_UPDATE i=3 c=sim-2 x=EXPIRED X=EXPIRED l=0 z=0.01 ap=100000 n=- rp=0
    |}];
  place adapt 3 (limit ~tif:Fok Buy "100100" "0.02");
  place adapt 3 (limit ~tif:Fok Buy "100100" "0.01");
  place adapt 2 (limit ~reduce_only:true Buy "100000" "0.01");
  place adapt 2 (limit ~reduce_only:true Sell "90000" "0.05");
  [%expect
    {|
    error -5021 Due to the order could not be filled immediately, the FOK order has been rejected. The order will not be recorded in the order history
    order 4 sim-3 FILLED qty=0.01 executed=0.01 avg=100100
    error -2022 ReduceOnly Order is rejected.
    order 6 sim-5 NEW qty=0.01 executed=0 avg=0
    |}];
  print_events adapt;
  [%expect
    {|
    key-3 ORDER_TRADE_UPDATE i=4 c=sim-3 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    key-3 ORDER_TRADE_UPDATE i=4 c=sim-3 x=TRADE X=FILLED l=0.01 z=0.01 ap=100100 n=0.5005 rp=0
    key-3 ACCOUNT_UPDATE ORDER wb=99999.4995 BTCUSDT:0.01@100100
    key-1 ORDER_TRADE_UPDATE i=2 c=sim-1 x=TRADE X=FILLED l=0.01 z=0.01 ap=100100 n=0.2002 rp=0
    key-1 ACCOUNT_UPDATE ORDER wb=99999.5998 BTCUSDT:-0.02@100050
    key-2 ORDER_TRADE_UPDATE i=6 c=sim-5 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    |}]
;;

let%expect_test "self-trade prevention expires the taker" =
  let adapt = fresh () in
  place adapt 2 (limit Sell "100000" "0.01");
  place adapt 1 (limit Sell "100100" "0.01");
  place adapt 1 (limit Buy "100100" "0.02");
  place adapt 1 (limit Buy "100000" "0.01");
  [%expect
    {|
    order 1 sim-1 NEW qty=0.01 executed=0 avg=0
    order 2 sim-2 NEW qty=0.01 executed=0 avg=0
    order 3 sim-3 EXPIRED qty=0.02 executed=0.01 avg=100000
    order 4 sim-4 NEW qty=0.01 executed=0 avg=0
    |}];
  print_events adapt;
  [%expect
    {|
    key-2 ORDER_TRADE_UPDATE i=1 c=sim-1 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    key-1 ORDER_TRADE_UPDATE i=2 c=sim-2 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    key-1 ORDER_TRADE_UPDATE i=3 c=sim-3 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    key-1 ORDER_TRADE_UPDATE i=3 c=sim-3 x=TRADE X=PARTIALLY_FILLED l=0.01 z=0.01 ap=100000 n=0.5 rp=0
    key-1 ACCOUNT_UPDATE ORDER wb=99999.5 BTCUSDT:0.01@100000
    key-2 ORDER_TRADE_UPDATE i=1 c=sim-1 x=TRADE X=FILLED l=0.01 z=0.01 ap=100000 n=0.2 rp=0
    key-2 ACCOUNT_UPDATE ORDER wb=99999.8 BTCUSDT:-0.01@100000
    key-1 ORDER_TRADE_UPDATE i=3 c=sim-3 x=EXPIRED X=EXPIRED_IN_MATCH l=0 z=0.01 ap=100000 n=- rp=0
    key-1 ORDER_TRADE_UPDATE i=4 c=sim-4 x=NEW X=NEW l=0 z=0 ap=0 n=- rp=0
    |}]
;;

let%expect_test "funding updates balances and the premium index" =
  let adapt = fresh () in
  let ex = Adapt.exchange adapt in
  place adapt 2 (limit Sell "100000" "0.1");
  place adapt 1 (limit Buy "100000" "0.1");
  ignore (Exchange.drain_events ex : _ list);
  [%expect
    {|
    order 1 sim-1 NEW qty=0.1 executed=0 avg=0
    order 2 sim-2 FILLED qty=0.1 executed=0.1 avg=100000
    |}];
  Exchange.set_funding_rate ex btc 0.0003;
  Exchange.step ex ~now:Adapt.funding_interval_ns;
  print_events adapt;
  print_s [%sexp (Adapt.premium_index adapt btc : Premium_index.t option)];
  [%expect
    {|
    key-1 ACCOUNT_UPDATE FUNDING_FEE wb=99992
    key-2 ACCOUNT_UPDATE FUNDING_FEE wb=100001
    (((symbol BTCUSDT) (mark_price 100000) (index_price 100000)
      (estimated_settle_price (100000)) (last_funding_rate 0.0003)
      (interest_rate (0.0001)) (next_funding_time 57600000) (time 28800000)))
    |}];
  print_s [%sexp (Adapt.position_risk adapt (acct 2) ~symbol:btc : Position_risk.t list)];
  [%expect
    {|
    (((symbol BTCUSDT) (position_side Both) (position_amt -0.1)
      (entry_price 100000) (break_even_price ()) (mark_price 100000)
      (unrealized_profit 0) (liquidation_price 1095627.49003984)
      (isolated_margin (0)) (notional (-10000)) (isolated_wallet (0))
      (margin_asset ()) (leverage (20)) (margin_type (cross))
      (is_auto_add_margin (false)) (max_notional_value ()) (initial_margin ())
      (maint_margin ()) (position_initial_margin ())
      (open_order_initial_margin ()) (adl ()) (update_time 28800000)))
    |}]
;;
