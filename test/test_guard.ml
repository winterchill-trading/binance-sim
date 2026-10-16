(* The price collar and halt rule through the simulator: flags, Binance error codes,
   PERCENT_PRICE, GET /sim/guard, POST /sim/reopen, and replay of the guard log. *)

open! Core
open! Async
open! Binance_protocol
open! Binance_sim
module Exchange = Exchange_core_engine.Exchange
module Guard_event = Exchange_core_engine.Guard_event

let start = 1_700_000_000_000_000_000
let mm = "mm-key"
let taker = "taker-key"
let btc = Symbol.of_string "BTCUSDT"

let%expect_test "halt levels and flag combinations" =
  let show s =
    print_s
      [%sexp
        (Guard.parse_levels s : Exchange_core_engine.Halt_rule.Level.t list Or_error.t)]
  in
  show "7:15m,13:15m,20:reopen";
  show "2.5:90s";
  show "7";
  show "x:15m";
  [%expect
    {|
    (Ok
     (((move_bps 700) (duration_ns (900000000000)))
      ((move_bps 1300) (duration_ns (900000000000)))
      ((move_bps 2000) (duration_ns ()))))
    (Ok (((move_bps 250) (duration_ns (90000000000)))))
    (Error ("halt level is not PERCENT:DURATION" 7))
    (Error (("invalid halt level" x:15m) (Invalid_argument "Float.of_string x")))
    |}];
  let create ?collar_bps ?collar_ticks ?collar_reference ?halt_levels ?halt_scope anchored
    =
    Guard.Config.create
      ?collar_bps
      ?collar_ticks
      ?collar_reference
      ?halt_levels
      ?halt_scope
      ~anchored
      ()
    |> [%sexp_of: Guard.Config.t Or_error.t]
    |> print_s
  in
  create false;
  create ~collar_bps:50 false;
  create ~collar_ticks:20 true;
  create ~collar_bps:50 ~collar_ticks:20 false;
  create ~collar_reference:Mid false;
  create ~collar_bps:0 false;
  create ~halt_scope:Per_symbol false;
  create ~halt_levels:[] false;
  [%expect
    {|
    (Ok ((collar ()) (halt_rule ())))
    (Ok
     ((collar (((reference Last_trade) (band (Bps 50)) (action Reject))))
      (halt_rule ())))
    (Ok
     ((collar (((reference Mark) (band (Ticks 20)) (action Reject))))
      (halt_rule ())))
    (Error "-collar-bps and -collar-ticks exclude each other")
    (Error
     "-collar-reference and -collar-action need -collar-bps or -collar-ticks")
    (Error
     ("Price_collar: band must be positive"
      (t ((reference Last_trade) (band (Bps 0)) (action Reject)))))
    (Error "-halt-scope needs -halt-levels")
    (Error
     ("Halt_rule: invalid levels"
      (t
       ((levels ()) (scope Market_wide) (watch ()) (observe Mark)
        (reopen Automatic)))))
    |}];
  return ()
;;

(* A server whose BTCUSDT book has mm's bid at 30000 and ask at 30010 (mid 30005). *)
let with_server ?(clock = ref start) guard f =
  Log.Global.set_output [];
  let adapt = Adapt.create () in
  let inputs = Queue.create () in
  Exchange.record_inputs (Adapt.exchange adapt) ~f:(Queue.enqueue inputs);
  Guard.apply guard (Adapt.exchange adapt) |> ok_exn;
  let server = Server.create ~now:(fun () -> !clock) adapt in
  let%bind http = Server.listen server ~port:0 in
  let port = Server.port http in
  let call ?key ?(quiet = false) meth path_and_query =
    let headers =
      Cohttp.Header.of_list
        (match key with
         | Some k -> [ "X-MBX-APIKEY", k ]
         | None -> [])
    in
    let uri = Uri.of_string (sprintf "http://127.0.0.1:%d%s" port path_and_query) in
    let%bind response, body =
      match meth with
      | `GET -> Cohttp_async.Client.get ~headers uri
      | `POST -> Cohttp_async.Client.post ~headers uri
    in
    let%map body = Cohttp_async.Body.to_string body in
    if not quiet
    then
      printf "%d %s\n" (Cohttp.Code.code_of_status (Cohttp.Response.status response)) body;
    body
  in
  let order ?(quiet = false) ~key ~side ?(tif = "GTC") ~price qty =
    call
      ~quiet
      ~key
      `POST
      (sprintf
         "/fapi/v1/order?symbol=BTCUSDT&side=%s&type=LIMIT&timeInForce=%s&price=%s&quantity=%s&timestamp=1"
         side
         tif
         price
         qty)
    |> Deferred.ignore_m
  in
  let%bind () = order ~quiet:true ~key:mm ~side:"BUY" ~price:"30000" "0.01" in
  let%bind () = order ~quiet:true ~key:mm ~side:"SELL" ~price:"30010" "0.01" in
  let%bind () = f ~server ~call ~order ~inputs in
  Cohttp_async.Server.close http
;;

let collar ?(action = Exchange_core_engine.Price_collar.Action.Reject) bps
  : Guard.Config.t
  =
  { collar = Some { reference = Mid; band = Bps bps; action }; halt_rule = None }
;;

let%expect_test "collar rejections are PERCENT_PRICE errors" =
  with_server (collar 50) (fun ~server:_ ~call ~order ~inputs:_ ->
    let%bind () = order ~key:taker ~side:"BUY" ~price:"30200" "0.01" in
    let%bind () = order ~key:taker ~side:"SELL" ~price:"29800" "0.01" in
    (* Still a tick error, not a collar one. *)
    let%bind () = order ~key:taker ~side:"BUY" ~price:"30200.05" "0.01" in
    (* Within the band it trades. *)
    let%bind () =
      order ~quiet:true ~key:taker ~side:"BUY" ~tif:"IOC" ~price:"30150" "0.01"
    in
    [%expect
      {|
      400 {"code":-4016,"msg":"Limit price can't be higher than 30155."}
      400 {"code":-4024,"msg":"Limit price can't be lower than 29855."}
      400 {"code":-4014,"msg":"Price not increased by tick size."}
      |}];
    let%bind info = call ~quiet:true `GET "/fapi/v1/exchangeInfo" in
    let info = Exchange_info.t_of_yojson (Yojson.Safe.from_string info) in
    List.iter info.symbols ~f:(fun s ->
      List.iter s.filters ~f:(function
        | Percent_price { multiplier_up; multiplier_down; _ } ->
          print_s
            [%message
              (s.symbol : Symbol.t)
                (multiplier_up : Decimal.t)
                (multiplier_down : Decimal.t)]
        | _ -> ()));
    [%expect
      {|
      ((s.symbol BTCUSDT) (multiplier_up 1.005) (multiplier_down 0.995))
      ((s.symbol ETHUSDT) (multiplier_up 1.005) (multiplier_down 0.995))
      ((s.symbol SOLUSDT) (multiplier_up 1.005) (multiplier_down 0.995))
      |}];
    let%bind () = call `GET "/sim/guard" |> Deferred.ignore_m in
    [%expect
      {| 200 {"collar":{"BTCUSDT":{"reference":"mid","band":{"bps":50},"action":"reject","referencePrice":null,"lower":null,"upper":null},"ETHUSDT":{"reference":"mid","band":{"bps":50},"action":"reject","referencePrice":null,"lower":null,"upper":null},"SOLUSDT":{"reference":"mid","band":{"bps":50},"action":"reject","referencePrice":null,"lower":null,"upper":null}},"haltRule":null,"halted":{},"stats":{"collarRejected":2,"collarRepriced":0,"collarUnreferenced":2,"haltRejected":0,"halts":0,"reopens":0},"recent":[{"time":1700000000000,"symbol":"BTCUSDT","account":"taker-key","orderId":3,"kind":"collarRejected","side":"BUY","price":"30200","reference":"30005","bound":"30155"},{"time":1700000000000,"symbol":"BTCUSDT","account":"taker-key","orderId":4,"kind":"collarRejected","side":"SELL","price":"29800","reference":"30005","bound":"29855"}]} |}];
    return ())
;;

let%expect_test "a reprice collar stops the order at the band" =
  with_server (collar ~action:Reprice 10) (fun ~server:_ ~call ~order ~inputs:_ ->
    (* Band 10 bps of 30005: up to 30035. A second ask beyond it stays. *)
    let%bind () = order ~quiet:true ~key:mm ~side:"SELL" ~price:"30040" "0.01" in
    let%bind () = order ~key:taker ~side:"BUY" ~tif:"IOC" ~price:"30100" "0.02" in
    [%expect
      {| 200 {"orderId":4,"symbol":"BTCUSDT","clientOrderId":"sim-4","side":"BUY","positionSide":"BOTH","status":"EXPIRED","type":"LIMIT","origType":"LIMIT","timeInForce":"IOC","price":"30100","origQty":"0.02","executedQty":"0.01","cumQty":"0.01","cumQuote":"300.1","avgPrice":"30010","stopPrice":"0","reduceOnly":false,"closePosition":false,"priceProtect":false,"workingType":"CONTRACT_PRICE","priceMatch":"NONE","selfTradePreventionMode":"EXPIRE_TAKER","goodTillDate":0,"updateTime":1700000000000} |}];
    let%bind () = call `GET "/sim/guard" |> Deferred.ignore_m in
    [%expect
      {| 200 {"collar":{"BTCUSDT":{"reference":"mid","band":{"bps":10},"action":"reprice","referencePrice":"30020","lower":"29990","upper":"30050"},"ETHUSDT":{"reference":"mid","band":{"bps":10},"action":"reprice","referencePrice":null,"lower":null,"upper":null},"SOLUSDT":{"reference":"mid","band":{"bps":10},"action":"reprice","referencePrice":null,"lower":null,"upper":null}},"haltRule":null,"halted":{},"stats":{"collarRejected":0,"collarRepriced":1,"collarUnreferenced":2,"haltRejected":0,"halts":0,"reopens":0},"recent":[{"time":1700000000000,"symbol":"BTCUSDT","account":"taker-key","orderId":4,"kind":"collarRepriced","side":"BUY","price":"30100","repricedPrice":"30035","reference":"30005"}]} |}];
    return ())
;;

let halt_rule : Guard.Config.t =
  Guard.Config.create
    ~halt_levels:(ok_exn (Guard.parse_levels "1:15m,2:reopen"))
    ~anchored:false
    ()
  |> ok_exn
;;

let set_mark server px =
  Server.mutate server ~f:(fun a ->
    Exchange.set_mark (Adapt.exchange a) btc (Price.of_string px))
;;

let%expect_test "halts reject orders that would trade; reopen" =
  let clock = ref start in
  with_server ~clock halt_rule (fun ~server ~call ~order ~inputs:_ ->
    set_mark server "30005";
    set_mark server "30350";
    let%bind () = order ~key:taker ~side:"BUY" ~price:"30010" "0.01" in
    (* A passive order rests while halted. *)
    let%bind () = order ~quiet:true ~key:taker ~side:"BUY" ~price:"29000" "0.01" in
    let%bind () = call `GET "/sim/guard" |> Deferred.ignore_m in
    [%expect
      {|
      400 {"code":-2010,"msg":"Trading is halted."}
      200 {"collar":{},"haltRule":{"levels":[{"moveBps":100,"durationMs":900000},{"moveBps":200,"durationMs":null}],"scope":"market","observe":"mark","sessionReference":{"BTCUSDT":"30005"}},"halted":{"BTCUSDT":{"state":"halted","until":1700000900000},"ETHUSDT":{"state":"halted","until":1700000900000},"SOLUSDT":{"state":"halted","until":1700000900000}},"stats":{"collarRejected":0,"collarRepriced":0,"collarUnreferenced":0,"haltRejected":1,"halts":3,"reopens":0},"recent":[{"time":1700000000000,"symbol":"BTCUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":0,"reference":"30005","price":"30350","moveBps":114,"until":1700000900000},{"time":1700000000000,"symbol":"ETHUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":0,"reference":"30005","price":"30350","moveBps":114,"until":1700000900000},{"time":1700000000000,"symbol":"SOLUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":0,"reference":"30005","price":"30350","moveBps":114,"until":1700000900000},{"time":1700000000000,"symbol":"BTCUSDT","account":"taker-key","orderId":3,"kind":"haltRejected","side":"BUY"}]}
      |}];
    (* The 15 minute halt lifts by itself. *)
    clock := !clock + Time_ns.Span.to_int_ns (Time_ns.Span.of_min 16.);
    let%bind () = order ~key:taker ~side:"BUY" ~tif:"IOC" ~price:"30010" "0.01" in
    [%expect
      {| 200 {"orderId":5,"symbol":"BTCUSDT","clientOrderId":"sim-5","side":"BUY","positionSide":"BOTH","status":"FILLED","type":"LIMIT","origType":"LIMIT","timeInForce":"IOC","price":"30010","origQty":"0.01","executedQty":"0.01","cumQty":"0.01","cumQuote":"300.1","avgPrice":"30010","stopPrice":"0","reduceOnly":false,"closePosition":false,"priceProtect":false,"workingType":"CONTRACT_PRICE","priceMatch":"NONE","selfTradePreventionMode":"EXPIRE_TAKER","goodTillDate":0,"updateTime":1700000960000} |}];
    (* The second level waits for POST /sim/reopen. *)
    set_mark server "30700";
    let%bind () = order ~key:taker ~side:"SELL" ~price:"29000" "0.01" in
    let%bind () = call `POST "/sim/reopen?symbol=XYZ" |> Deferred.ignore_m in
    let%bind () = call `POST "/sim/reopen?symbol=BTCUSDT" |> Deferred.ignore_m in
    [%expect
      {|
      400 {"code":-2010,"msg":"Trading is halted."}
      400 {"code":-1121,"msg":"Invalid symbol."}
      200 {"collar":{},"haltRule":{"levels":[{"moveBps":100,"durationMs":900000},{"moveBps":200,"durationMs":null}],"scope":"market","observe":"mark","sessionReference":{"BTCUSDT":"30005"}},"halted":{"ETHUSDT":{"state":"untilReopen"},"SOLUSDT":{"state":"untilReopen"}},"stats":{"collarRejected":0,"collarRepriced":0,"collarUnreferenced":0,"haltRejected":2,"halts":6,"reopens":4},"recent":[{"time":1700000000000,"symbol":"BTCUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":0,"reference":"30005","price":"30350","moveBps":114,"until":1700000900000},{"time":1700000000000,"symbol":"ETHUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":0,"reference":"30005","price":"30350","moveBps":114,"until":1700000900000},{"time":1700000000000,"symbol":"SOLUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":0,"reference":"30005","price":"30350","moveBps":114,"until":1700000900000},{"time":1700000000000,"symbol":"BTCUSDT","account":"taker-key","orderId":3,"kind":"haltRejected","side":"BUY"},{"time":1700000960000,"symbol":"BTCUSDT","account":null,"orderId":null,"kind":"reopened"},{"time":1700000960000,"symbol":"ETHUSDT","account":null,"orderId":null,"kind":"reopened"},{"time":1700000960000,"symbol":"SOLUSDT","account":null,"orderId":null,"kind":"reopened"},{"time":1700000960000,"symbol":"BTCUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":1,"reference":"30005","price":"30700","moveBps":231,"until":null},{"time":1700000960000,"symbol":"ETHUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":1,"reference":"30005","price":"30700","moveBps":231,"until":null},{"time":1700000960000,"symbol":"SOLUSDT","account":null,"orderId":null,"kind":"halted","triggerSymbol":"BTCUSDT","level":1,"reference":"30005","price":"30700","moveBps":231,"until":null},{"time":1700000960000,"symbol":"BTCUSDT","account":"taker-key","orderId":6,"kind":"haltRejected","side":"SELL"},{"time":1700000960000,"symbol":"BTCUSDT","account":null,"orderId":null,"kind":"reopened"}]}
      |}];
    return ())
;;

let%expect_test "the input journal replays the guard log" =
  let guard =
    { halt_rule with collar = Some { reference = Mid; band = Bps 50; action = Reject } }
  in
  with_server guard (fun ~server ~call:_ ~order ~inputs ->
    let%bind () = order ~quiet:true ~key:taker ~side:"BUY" ~price:"30200" "0.01" in
    set_mark server "30005";
    set_mark server "30350";
    let%bind () = order ~quiet:true ~key:taker ~side:"BUY" ~price:"30010" "0.01" in
    Server.mutate server ~f:(fun a -> Exchange.reopen (Adapt.exchange a));
    let live = Server.guard_events server in
    let exchange = Adapt.exchange (Server.adapt server) in
    let replayed =
      Exchange_core_engine.Journal.replay
        ~config:(Adapt.config ())
        ~header:(Exchange_core_engine.Journal.Header.of_exchange exchange)
        (Queue.to_list inputs)
    in
    let replayed_events = Exchange.drain_guard_events replayed in
    print_s
      [%message
        ""
          ~events:(List.length live : int)
          ~same_events:([%equal: Guard_event.t list] live replayed_events : bool)
          ~same_stats:
            ([%equal: Guard_event.Stats.t]
               (Exchange.guard_stats exchange)
               (Exchange.guard_stats replayed)
             : bool)];
    print_s [%sexp (Exchange.guard_stats replayed : Guard_event.Stats.t)];
    [%expect
      {|
      ((events 8) (same_events true) (same_stats true))
      ((collar_rejected 1) (collar_repriced 0) (collar_unreferenced 2)
       (halt_rejected 1) (halts 3) (reopens 3))
      |}];
    return ())
;;
