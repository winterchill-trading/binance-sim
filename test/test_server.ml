open! Core
open! Async
open! Binance_protocol
open! Binance_sim

(* A fixed clock keeps every timestamp in the output deterministic. *)
let now () = 1_700_000_000_000_000_000
let mm = "mm-key"
let taker = "taker-key"

let with_server ?(config = Server.Config.default) f =
  Log.Global.set_output [];
  let server = Server.create ~config ~now (Adapt.create ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind () = f (Server.port http) in
  Cohttp_async.Server.close http
;;

let uri port path_and_query =
  Uri.of_string (sprintf "http://127.0.0.1:%d%s" port path_and_query)
;;

(* Prints the status and body; returns the body. *)
let call ?key ?body ?(quiet = false) meth port path =
  let headers =
    Cohttp.Header.of_list
      ((match key with
        | Some k -> [ "X-MBX-APIKEY", k ]
        | None -> [])
       @
       match body with
       | Some _ -> [ "content-type", "application/x-www-form-urlencoded" ]
       | None -> [])
  in
  let body = Option.map body ~f:Cohttp_async.Body.of_string in
  let uri = uri port path in
  let%bind response, body =
    match meth with
    | `GET -> Cohttp_async.Client.get ~headers uri
    | `POST -> Cohttp_async.Client.post ~headers ?body uri
    | `PUT -> Cohttp_async.Client.put ~headers ?body uri
    | `DELETE -> Cohttp_async.Client.delete ~headers ?body uri
  in
  let%map body = Cohttp_async.Body.to_string body in
  if not quiet
  then
    printf "%d %s\n" (Cohttp.Code.code_of_status (Cohttp.Response.status response)) body;
  body
;;

let get ?key ?quiet port path = call ?key ?quiet `GET port path
let ignore_body d = Deferred.ignore_m (d : string Deferred.t)

let order ~key ~side ~type_ ?tif ?price ~qty port =
  let params =
    [ Some ("symbol", "BTCUSDT")
    ; Some ("side", side)
    ; Some ("type", type_)
    ; Option.map tif ~f:(fun v -> "timeInForce", v)
    ; Some ("quantity", qty)
    ; Option.map price ~f:(fun v -> "price", v)
    ; Some ("timestamp", "1700000000000")
    ]
    |> List.filter_opt
  in
  call ~key ~body:(Query.encode params) `POST port "/fapi/v1/order" |> ignore_body
;;

let%expect_test "public market data" =
  with_server (fun port ->
    let%bind () = get port "/fapi/v1/ping" |> ignore_body in
    [%expect {| 200 {} |}];
    let%bind () = get port "/fapi/v1/time" |> ignore_body in
    [%expect {| 200 {"serverTime":1700000000000} |}];
    let%bind info = get ~quiet:true port "/fapi/v1/exchangeInfo" in
    let info = Exchange_info.t_of_yojson (Yojson.Safe.from_string info) in
    List.iter info.symbols ~f:(fun s ->
      print_s
        [%message
          ""
            ~symbol:(s.symbol : Symbol.t)
            ~tick:(Exchange_info.Symbol_info.tick_size s : Price.t option)
            ~step:(Exchange_info.Symbol_info.step_size s : Size.t option)
            ~min_notional:(Exchange_info.Symbol_info.min_notional s : Usd.t option)
            ~precision:((s.price_precision, s.quantity_precision) : int * int)
            ~round_trips:
              ([%equal: Exchange_core.Instrument.t option]
                 (Exchange_info.Symbol_info.to_instrument
                    s
                    ~fees:Adapt.fees
                    ~max_leverage:
                      (List.find_exn Adapt.Spec.default_universe ~f:(fun spec ->
                         Symbol.equal spec.symbol s.symbol))
                        .max_leverage)
                 (List.find
                    (List.map Adapt.Spec.default_universe ~f:Adapt.Spec.instrument)
                    ~f:(fun i -> Symbol.equal i.symbol s.symbol))
               : bool)]);
    [%expect
      {|
      ((symbol BTCUSDT) (tick (0.1)) (step (0.001)) (min_notional (100))
       (precision (2 3)) (round_trips true))
      ((symbol ETHUSDT) (tick (0.01)) (step (0.001)) (min_notional (20))
       (precision (2 3)) (round_trips true))
      ((symbol SOLUSDT) (tick (0.01)) (step (1)) (min_notional (5))
       (precision (4 0)) (round_trips true))
      |}];
    let%bind () = get port "/fapi/v1/depth?symbol=BTCUSDT&limit=5" |> ignore_body in
    let%bind () = get port "/fapi/v1/depth?symbol=XYZUSDT" |> ignore_body in
    let%bind () = get port "/fapi/v1/depth?symbol=BTCUSDT&limit=7" |> ignore_body in
    let%bind () = get port "/fapi/v1/ticker/bookTicker?symbol=BTCUSDT" |> ignore_body in
    let%bind () = get port "/fapi/v1/premiumIndex?symbol=ETHUSDT" |> ignore_body in
    [%expect
      {|
      200 {"lastUpdateId":0,"E":1700000000000,"T":1700000000000,"bids":[],"asks":[]}
      400 {"code":-1121,"msg":"Invalid symbol."}
      400 {"code":-1130,"msg":"Data sent for parameter 'limit' is not valid."}
      200 {"symbol":"BTCUSDT","bidPrice":"0","bidQty":"0","askPrice":"0","askQty":"0","time":1700000000000}
      200 {"symbol":"ETHUSDT","markPrice":"0","indexPrice":"0","estimatedSettlePrice":"0","lastFundingRate":"0.0001","interestRate":"0.0001","nextFundingTime":1700006400000,"time":1700000000000}
      |}];
    return ())
;;

let%expect_test "orders, cancels and account views" =
  with_server (fun port ->
    (* Signed endpoints need an API key and a timestamp. *)
    let%bind () =
      call `POST port "/fapi/v1/order" ~body:"symbol=BTCUSDT&timestamp=1" |> ignore_body
    in
    let%bind () =
      call ~key:mm `POST port "/fapi/v1/order" ~body:"symbol=BTCUSDT" |> ignore_body
    in
    [%expect
      {|
      401 {"code":-2014,"msg":"API-key format invalid."}
      400 {"code":-1102,"msg":"Mandatory parameter 'timestamp' was not sent, was empty/null, or malformed."}
      |}];
    (* A post-only ask rests; a post-only bid at the same price would match. *)
    let%bind () =
      order
        port
        ~key:mm
        ~side:"SELL"
        ~type_:"LIMIT"
        ~tif:"GTX"
        ~price:"100000"
        ~qty:"0.01"
    in
    let%bind () =
      order
        port
        ~key:taker
        ~side:"BUY"
        ~type_:"LIMIT"
        ~tif:"GTX"
        ~price:"100000"
        ~qty:"0.01"
    in
    [%expect
      {|
      200 {"orderId":1,"symbol":"BTCUSDT","clientOrderId":"sim-1","side":"SELL","positionSide":"BOTH","status":"NEW","type":"LIMIT","origType":"LIMIT","timeInForce":"GTX","price":"100000","origQty":"0.01","executedQty":"0","cumQty":"0","cumQuote":"0","avgPrice":"0","stopPrice":"0","reduceOnly":false,"closePosition":false,"priceProtect":false,"workingType":"CONTRACT_PRICE","priceMatch":"NONE","selfTradePreventionMode":"EXPIRE_TAKER","goodTillDate":0,"updateTime":1700000000000}
      400 {"code":-5022,"msg":"Due to the order could not be executed as maker, the Post Only order will be rejected. The order will not be recorded in the order history"}
      |}];
    (* A crossing GTC bid fills against it. *)
    let%bind () =
      order
        port
        ~key:taker
        ~side:"BUY"
        ~type_:"LIMIT"
        ~tif:"GTC"
        ~price:"100000"
        ~qty:"0.004"
    in
    [%expect
      {| 200 {"orderId":3,"symbol":"BTCUSDT","clientOrderId":"sim-3","side":"BUY","positionSide":"BOTH","status":"FILLED","type":"LIMIT","origType":"LIMIT","timeInForce":"GTC","price":"100000","origQty":"0.004","executedQty":"0.004","cumQty":"0.004","cumQuote":"400","avgPrice":"100000","stopPrice":"0","reduceOnly":false,"closePosition":false,"priceProtect":false,"workingType":"CONTRACT_PRICE","priceMatch":"NONE","selfTradePreventionMode":"EXPIRE_TAKER","goodTillDate":0,"updateTime":1700000000000} |}];
    let%bind () = get port "/fapi/v1/depth?symbol=BTCUSDT&limit=5" |> ignore_body in
    let%bind () = get port "/fapi/v1/ticker/bookTicker?symbol=BTCUSDT" |> ignore_body in
    [%expect
      {|
      200 {"lastUpdateId":2,"E":1700000000000,"T":1700000000000,"bids":[],"asks":[["100000","0.006"]]}
      200 {"symbol":"BTCUSDT","bidPrice":"0","bidQty":"0","askPrice":"100000","askQty":"0.006","time":1700000000000}
      |}];
    let%bind () =
      get ~key:mm port "/fapi/v1/openOrders?symbol=BTCUSDT&timestamp=1" |> ignore_body
    in
    [%expect
      {| 200 [{"orderId":1,"symbol":"BTCUSDT","clientOrderId":"sim-1","side":"SELL","positionSide":"BOTH","status":"PARTIALLY_FILLED","type":"LIMIT","origType":"LIMIT","timeInForce":"GTX","price":"100000","origQty":"0.01","executedQty":"0.004","cumQuote":"400","avgPrice":"100000","stopPrice":"0","reduceOnly":false,"closePosition":false,"priceProtect":false,"workingType":"CONTRACT_PRICE","priceMatch":"NONE","selfTradePreventionMode":"EXPIRE_TAKER","goodTillDate":0,"time":1700000000000,"updateTime":1700000000000}] |}];
    let%bind () =
      call ~key:mm `DELETE port "/fapi/v1/order?symbol=BTCUSDT&orderId=1&timestamp=1"
      |> ignore_body
    in
    let%bind () =
      call ~key:mm `DELETE port "/fapi/v1/order?symbol=BTCUSDT&orderId=1&timestamp=1"
      |> ignore_body
    in
    let%bind () = get ~key:mm port "/fapi/v1/openOrders?timestamp=1" |> ignore_body in
    [%expect
      {|
      200 {"orderId":1,"symbol":"BTCUSDT","clientOrderId":"sim-1","side":"SELL","positionSide":"BOTH","status":"CANCELED","type":"LIMIT","origType":"LIMIT","timeInForce":"GTX","price":"100000","origQty":"0.01","executedQty":"0.004","cumQty":"0.004","cumQuote":"400","avgPrice":"100000","stopPrice":"0","reduceOnly":false,"closePosition":false,"priceProtect":false,"workingType":"CONTRACT_PRICE","priceMatch":"NONE","selfTradePreventionMode":"EXPIRE_TAKER","goodTillDate":0,"updateTime":1700000000000}
      400 {"code":-2011,"msg":"Unknown order sent."}
      200 []
      |}];
    let%bind () =
      get ~key:taker port "/fapi/v1/userTrades?symbol=BTCUSDT&timestamp=1" |> ignore_body
    in
    let%bind () =
      get ~key:mm port "/fapi/v1/userTrades?symbol=BTCUSDT&timestamp=1" |> ignore_body
    in
    [%expect
      {|
      200 [{"id":1,"orderId":3,"symbol":"BTCUSDT","side":"BUY","positionSide":"BOTH","price":"100000","qty":"0.004","quoteQty":"400","commission":"0.2","commissionAsset":"USDT","realizedPnl":"0","marginAsset":"USDT","maker":false,"buyer":true,"time":1700000000000}]
      200 [{"id":1,"orderId":1,"symbol":"BTCUSDT","side":"SELL","positionSide":"BOTH","price":"100000","qty":"0.004","quoteQty":"400","commission":"0.08","commissionAsset":"USDT","realizedPnl":"0","marginAsset":"USDT","maker":true,"buyer":false,"time":1700000000000}]
      |}];
    let%bind account = get ~quiet:true ~key:taker port "/fapi/v2/account?timestamp=1" in
    let account = Account.t_of_yojson (Yojson.Safe.from_string account) in
    print_s
      [%message
        ""
          ~wallet:(account.total_wallet_balance : Usd.t)
          ~unrealized:(account.total_unrealized_profit : Usd.t)
          ~available:(account.available_balance : Usd.t)
          ~positions:(Account.open_positions account : Account.Position.t list)];
    [%expect
      {|
      ((wallet 999999.8) (unrealized 0) (available 999979.8)
       (positions
        (((symbol BTCUSDT) (position_side Both) (position_amt 0.004)
          (entry_price (100000)) (unrealized_profit 0) (leverage (20))
          (liquidation_price ()) (isolated (false)) (initial_margin (20))
          (maint_margin (1.6)) (position_initial_margin (20))
          (open_order_initial_margin (0)) (isolated_margin ())
          (isolated_wallet (0)) (notional (400)) (max_notional ())
          (update_time 1700000000000)))))
      |}];
    let%bind () =
      get ~key:taker port "/fapi/v2/positionRisk?symbol=BTCUSDT&timestamp=1"
      |> ignore_body
    in
    [%expect
      {| 200 [{"symbol":"BTCUSDT","positionSide":"BOTH","positionAmt":"0.004","entryPrice":"100000","markPrice":"100000","unRealizedProfit":"0","liquidationPrice":"0","isolatedMargin":"0","notional":"400","isolatedWallet":"0","leverage":"20","marginType":"cross","isAutoAddMargin":"false","updateTime":1700000000000}] |}];
    return ())
;;

let%expect_test "order rejections and batch orders" =
  with_server (fun port ->
    let reject ?tif ?price ?(type_ = "LIMIT") ?(side = "BUY") qty =
      order port ~key:taker ~side ~type_ ?tif ?price ~qty
    in
    let%bind () = reject ~tif:"GTC" ~price:"100000" "0.0001" in
    let%bind () = reject ~tif:"GTC" ~price:"100000.05" "0.01" in
    let%bind () = reject ~tif:"GTC" ~price:"100000.001" "0.01" in
    let%bind () = reject ~tif:"GTC" ~price:"99000" "0.001" in
    let%bind () = reject ~tif:"GTC" ~price:"100000" "1500" in
    let%bind () = reject ~tif:"GTC" ~price:"100000" "500" in
    let%bind () = reject ~tif:"FOK" ~price:"100000" "0.01" in
    let%bind () = reject ~tif:"GTD" ~price:"100000" "0.01" in
    let%bind () = reject ~tif:"IOC" ~price:"100000" "0.01" in
    let%bind () = reject ~side:"UP" ~tif:"GTC" ~price:"100000" "0.01" in
    let%bind () = reject ~type_:"STOP" "0.01" in
    let%bind () = reject ~tif:"GTC" "0.01" in
    [%expect
      {|
      400 {"code":-1111,"msg":"Precision is over the maximum defined for this asset."}
      400 {"code":-4014,"msg":"Price not increased by tick size."}
      400 {"code":-1111,"msg":"Precision is over the maximum defined for this asset."}
      400 {"code":-4164,"msg":"Order's notional must be no smaller than 100 (unless you choose reduce only)."}
      400 {"code":-4005,"msg":"Quantity greater than max quantity."}
      400 {"code":-2010,"msg":"Account has insufficient balance for requested action."}
      400 {"code":-5021,"msg":"Due to the order could not be filled immediately, the FOK order has been rejected. The order will not be recorded in the order history"}
      400 {"code":-1115,"msg":"Invalid timeInForce."}
      400 {"code":-2020,"msg":"Unable to fill."}
      400 {"code":-1117,"msg":"Invalid side."}
      400 {"code":-1116,"msg":"Invalid orderType."}
      400 {"code":-1102,"msg":"Mandatory parameter 'price' was not sent, was empty/null, or malformed."}
      |}];
    let batch =
      {|[{"symbol":"BTCUSDT","side":"SELL","type":"LIMIT","timeInForce":"GTC","price":"101000","quantity":"0.01"},{"symbol":"BTCUSDT","side":"SELL","type":"LIMIT","timeInForce":"GTC","price":"101000.01","quantity":"0.01"}]|}
    in
    let%bind () =
      call
        ~key:mm
        `POST
        port
        "/fapi/v1/batchOrders"
        ~body:(Query.encode [ "batchOrders", batch; "timestamp", "1" ])
      |> ignore_body
    in
    [%expect
      {| 200 [{"orderId":2,"symbol":"BTCUSDT","clientOrderId":"sim-3","side":"SELL","positionSide":"BOTH","status":"NEW","type":"LIMIT","origType":"LIMIT","timeInForce":"GTC","price":"101000","origQty":"0.01","executedQty":"0","cumQty":"0","cumQuote":"0","avgPrice":"0","stopPrice":"0","reduceOnly":false,"closePosition":false,"priceProtect":false,"workingType":"CONTRACT_PRICE","priceMatch":"NONE","selfTradePreventionMode":"EXPIRE_TAKER","goodTillDate":0,"updateTime":1700000000000},{"code":-4014,"msg":"Price not increased by tick size."}] |}];
    let%bind () =
      call ~key:mm `DELETE port "/fapi/v1/allOpenOrders?symbol=BTCUSDT&timestamp=1"
      |> ignore_body
    in
    let%bind () =
      get ~key:mm port "/fapi/v1/openOrders?symbol=BTCUSDT&timestamp=1" |> ignore_body
    in
    [%expect
      {|
      200 {"code":200,"msg":"The operation of cancel all open order is done."}
      200 []
      |}];
    return ())
;;
