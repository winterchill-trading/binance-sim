open! Core
open! Async
open! Binance_protocol
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Market_sim = Exchange_core_engine.Market_sim
module Account_id = Exchange_core.Account

module Config = struct
  type t =
    { initial_balance : Usd.t
    ; depth_interval : Time_ns.Span.t
    ; mark_price_interval : Time_ns.Span.t
    ; step_interval : Time_ns.Span.t
    ; ping_interval : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  let default =
    { initial_balance = Usd.of_int 1_000_000
    ; depth_interval = Time_ns.Span.of_int_ms 100
    ; mark_price_interval = Time_ns.Span.second
    ; step_interval = Time_ns.Span.second
    ; ping_interval = Time_ns.Span.of_min 3.
    }
  ;;
end

module Book_seq = struct
  (* Sequencing of one symbol's depth streams. *)
  type t =
    { mutable update_id : int (** book-changing events so far *)
    ; mutable published : int (** [u] of the last depth event *)
    ; mutable bids : Price.Set.t (** levels touched since the last depth event *)
    ; mutable asks : Price.Set.t
    ; mutable bbo : (Price.t * Size.t * Price.t * Size.t) option (** last bookTicker *)
    }

  let create () =
    { update_id = 0
    ; published = 0
    ; bids = Price.Set.empty
    ; asks = Price.Set.empty
    ; bbo = None
    }
  ;;

  let touch t (side : Side.t) px =
    match side with
    | Buy -> t.bids <- Set.add t.bids px
    | Sell -> t.asks <- Set.add t.asks px
  ;;
end

module Conn = struct
  type t =
    { id : int
    ; send : string Pipe.Writer.t
    ; combined : bool (** [/stream] connections wrap payloads *)
    ; mutable streams : Stream_name.t String.Map.t (** by name *)
    ; mutable listen_keys : String.Set.t
    }
end

type t =
  { adapt : Adapt.t
  ; config : Config.t
  ; now : unit -> int
  ; seen : Account_id.Hash_set.t
  ; books : Book_seq.t Symbol.Table.t
  ; dirty : Symbol.Hash_set.t
  ; mutable flush_scheduled : bool
  ; conns : Conn.t Int.Table.t
  ; mutable next_conn_id : int
  ; key_of_account : string Account_id.Table.t
  ; account_of_key : Account_id.t String.Table.t
  ; mutable next_key : int
  }

let wall_clock () = Time_ns.now () |> Time_ns.to_int_ns_since_epoch
let config t = t.config
let adapt t = t.adapt
let exchange t = Adapt.exchange t.adapt
let num_ws_connections t = Hashtbl.length t.conns
let book_seq t symbol = Hashtbl.find_or_add t.books symbol ~default:Book_seq.create

let last_update_id t symbol =
  Hashtbl.find t.books symbol |> Option.value_map ~default:0 ~f:(fun b -> b.update_id)
;;

let step_clock t =
  let now = t.now () in
  if now > Exchange.now (exchange t) then Exchange.step (exchange t) ~now
;;

let create ?(config = Config.default) ?(now = wall_clock) adapt =
  let t =
    { adapt
    ; config
    ; now
    ; seen = Account_id.Hash_set.create ()
    ; books = Symbol.Table.create ()
    ; dirty = Symbol.Hash_set.create ()
    ; flush_scheduled = false
    ; conns = Int.Table.create ()
    ; next_conn_id = 0
    ; key_of_account = Account_id.Table.create ()
    ; account_of_key = String.Table.create ()
    ; next_key = 0
    }
  in
  step_clock t;
  List.iter
    (Exchange.drain_events (exchange t))
    ~f:(fun e -> ignore (Adapt.user_events adapt e : _ list));
  t
;;

let ensure_account t account =
  if not (Hash_set.mem t.seen account)
  then (
    Hash_set.add t.seen account;
    Exchange.deposit (exchange t) account t.config.initial_balance;
    Log.Global.debug_s
      [%message
        "credited initial balance"
          (account : Account_id.t)
          ~usd:(t.config.initial_balance : Usd.t)])
;;

(* Websocket fan-out *)

let send_raw (conn : Conn.t) json =
  Pipe.write_without_pushback_if_open conn.send (Yojson.Safe.to_string json)
;;

let send (conn : Conn.t) ~stream json =
  send_raw
    conn
    (if conn.combined then `Assoc [ "stream", `String stream; "data", json ] else json)
;;

(* Sends [payload] on every subscribed stream that [matches]. *)
let broadcast t ~matches payload =
  Hashtbl.iter t.conns ~f:(fun conn ->
    Map.iteri conn.streams ~f:(fun ~key:name ~data:stream ->
      if matches stream then send conn ~stream:name (Lazy.force payload)))
;;

let has_subscriber t ~matches =
  Hashtbl.exists t.conns ~f:(fun conn -> Map.exists conn.streams ~f:matches)
;;

let flush_depth t =
  t.flush_scheduled <- false;
  let symbols = Hash_set.to_list t.dirty |> List.sort ~compare:Symbol.compare in
  Hash_set.clear t.dirty;
  List.iter symbols ~f:(fun symbol ->
    let b = book_seq t symbol in
    if b.update_id > b.published
    then (
      let first_update_id = b.published + 1
      and final_update_id = b.update_id
      and prev_final_update_id = b.published in
      let bids = Set.to_list b.bids
      and asks = Set.to_list b.asks in
      b.published <- b.update_id;
      b.bids <- Price.Set.empty;
      b.asks <- Price.Set.empty;
      broadcast
        t
        ~matches:(function
          | Diff_depth { symbol = s; speed = _ } -> Symbol.equal s symbol
          | _ -> false)
        (lazy
          (Depth_update.yojson_of_t
             (Adapt.depth_update
                t.adapt
                symbol
                ~bids
                ~asks
                ~first_update_id
                ~final_update_id
                ~prev_final_update_id)));
      List.iter [ 5; 10; 20 ] ~f:(fun levels ->
        broadcast
          t
          ~matches:(function
            | Partial_depth { symbol = s; levels = n; speed = _ } ->
              Symbol.equal s symbol && n = levels
            | _ -> false)
          (lazy
            (Depth_update.yojson_of_t
               (Adapt.partial_depth
                  t.adapt
                  symbol
                  ~levels
                  ~first_update_id
                  ~final_update_id
                  ~prev_final_update_id))))))
;;

let schedule_flush t =
  if (not t.flush_scheduled) && not (Hash_set.is_empty t.dirty)
  then (
    t.flush_scheduled <- true;
    Clock_ns.run_after t.config.depth_interval (fun () -> flush_depth t) ())
;;

let publish_book_ticker t symbol =
  let b = book_seq t symbol in
  match Adapt.book_ticker_event t.adapt symbol ~update_id:b.update_id with
  | None -> ()
  | Some e ->
    let bbo = Some (e.bid_price, e.bid_qty, e.ask_price, e.ask_qty) in
    if not ([%equal: (Price.t * Size.t * Price.t * Size.t) option] bbo b.bbo)
    then (
      b.bbo <- bbo;
      broadcast
        t
        ~matches:(function
          | Book_ticker s -> Symbol.equal s symbol
          | _ -> false)
        (lazy (Book_ticker_event.yojson_of_t e)))
;;

let log_event (event : Event.t) =
  match event with
  | Fill { fill; _ } ->
    Log.Global.info
      "fill %s %s %s@%s taker=%s maker=%s tid=%s"
      (Symbol.to_string fill.symbol)
      (Side.to_wire fill.taker_side)
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (Account_id.to_string fill.taker)
      (Account_id.to_string fill.maker)
      (Exchange_core.Trade_id.to_string fill.tid)
  | Liquidation { liquidation = l; _ } ->
    Log.Global.info
      "liquidation %s %s %s@%s pnl=%s"
      (Account_id.to_string l.account)
      (Symbol.to_string l.symbol)
      (Size.to_string l.size)
      (Price.to_string l.px)
      (Usd.to_string l.pnl)
  | Order_accepted _ | Order_rejected _ | Order_filled _ | Order_cancelled _ | Funding _
    -> Log.Global.debug_s [%sexp (event : Event.t)]
;;

let touch_book t (event : Event.t) =
  Option.iter (Event.book_symbol event) ~f:(fun symbol ->
    let b = book_seq t symbol in
    b.update_id <- b.update_id + 1;
    Hash_set.add t.dirty symbol;
    match event with
    | Order_accepted { order; _ } | Order_cancelled { order; _ } ->
      Book_seq.touch b order.side order.px
    | Fill { fill; _ } -> Book_seq.touch b (Side.flip fill.taker_side) fill.px
    | Order_rejected _ | Order_filled _ | Liquidation _ | Funding _ -> ())
;;

let send_user_event t account event =
  match Hashtbl.find t.key_of_account account with
  | None -> ()
  | Some key ->
    let payload = lazy (User_event.yojson_of_t event) in
    Hashtbl.iter t.conns ~f:(fun conn ->
      if Set.mem conn.listen_keys key then send conn ~stream:key (Lazy.force payload))
;;

let publish t =
  let events = Exchange.drain_events (exchange t) in
  if not (List.is_empty events)
  then (
    let touched = Symbol.Hash_set.create () in
    List.iter events ~f:(fun event ->
      log_event event;
      touch_book t event;
      Option.iter (Event.book_symbol event) ~f:(Hash_set.add touched);
      (match event with
       | Fill { fill; _ } ->
         broadcast
           t
           ~matches:(function
             | Agg_trade s -> Symbol.equal s fill.symbol
             | _ -> false)
           (lazy (Agg_trade.yojson_of_t (Adapt.agg_trade fill)))
       | _ -> ());
      Adapt.user_events t.adapt event ~interested:(Hashtbl.mem t.key_of_account)
      |> List.iter ~f:(fun (account, e) -> send_user_event t account e));
    Hash_set.to_list touched
    |> List.sort ~compare:Symbol.compare
    |> List.iter ~f:(fun symbol ->
      if has_subscriber t ~matches:(function
           | Book_ticker s -> Symbol.equal s symbol
           | _ -> false)
      then publish_book_ticker t symbol);
    schedule_flush t)
;;

let mutate t ~f =
  step_clock t;
  publish t;
  let result = f t.adapt in
  publish t;
  result
;;

(* Listen keys *)

let new_listen_key t =
  t.next_key <- t.next_key + 1;
  let half n = Md5.to_hex (Md5.digest_string (sprintf "listen-key-%d-%d" t.next_key n)) in
  half 0 ^ half 1
;;

let listen_key t account =
  match Hashtbl.find t.key_of_account account with
  | Some key -> key
  | None ->
    let key = new_listen_key t in
    Hashtbl.set t.key_of_account ~key:account ~data:key;
    Hashtbl.set t.account_of_key ~key ~data:account;
    key
;;

let close_listen_key t account =
  Option.iter (Hashtbl.find_and_remove t.key_of_account account) ~f:(fun key ->
    Hashtbl.remove t.account_of_key key;
    Hashtbl.iter t.conns ~f:(fun conn ->
      conn.listen_keys <- Set.remove conn.listen_keys key))
;;

(* Websocket connections *)

let subscribe (conn : Conn.t) t name =
  if Hashtbl.mem t.account_of_key name
  then conn.listen_keys <- Set.add conn.listen_keys name
  else (
    let stream = Stream_name.of_string name in
    conn.streams <- Map.set conn.streams ~key:(Stream_name.to_string stream) ~data:stream)
;;

let unsubscribe (conn : Conn.t) name =
  conn.listen_keys <- Set.remove conn.listen_keys name;
  conn.streams
  <- Map.remove conn.streams (Stream_name.to_string (Stream_name.of_string name))
;;

let ws_error ?id code msg = Subscribe.Response.yojson_of_t (Error { code; msg; id })

let handle_ws_message t (conn : Conn.t) text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error msg -> send_raw conn (ws_error 3 ("Invalid JSON: " ^ msg))
  | json ->
    (match Subscribe.Request.t_of_yojson json with
     | exception _ ->
       let id =
         Option.bind (Json.member json ~key:"id") ~f:(function
           | `Int i -> Some i
           | _ -> None)
       in
       send_raw conn (ws_error ?id 2 "Invalid request")
     | { method_; params; id } ->
       let names = List.map params ~f:Stream_name.to_string in
       let result : Yojson.Safe.t =
         match method_ with
         | Subscribe ->
           List.iter names ~f:(subscribe conn t);
           `Null
         | Unsubscribe ->
           List.iter names ~f:(unsubscribe conn);
           `Null
         | List_subscriptions ->
           `List
             (List.map
                (Map.keys conn.streams @ Set.to_list conn.listen_keys)
                ~f:(fun s -> `String s))
       in
       Log.Global.debug_s
         [%message
           "ws request"
             ~conn:(conn.id : int)
             (method_ : Subscribe.Method.t)
             (names : string list)];
       send_raw conn (Subscribe.Response.yojson_of_t (Result { result; id })))
;;

let handle_ws t ~combined ~streams reader writer =
  let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
  let incoming, outgoing = Websocket.pipes ws in
  let id = t.next_conn_id in
  t.next_conn_id <- id + 1;
  let conn =
    { Conn.id
    ; send = outgoing
    ; combined
    ; streams = String.Map.empty
    ; listen_keys = String.Set.empty
    }
  in
  List.iter streams ~f:(subscribe conn t);
  Hashtbl.set t.conns ~key:id ~data:conn;
  Log.Global.debug "ws %d: connected" id;
  Clock_ns.every
    ~start:(Clock_ns.after t.config.ping_interval)
    ~stop:(Pipe.closed outgoing)
    t.config.ping_interval
    (fun () -> Websocket.send_ping ws "");
  let%map () = Pipe.iter_without_pushback incoming ~f:(handle_ws_message t conn) in
  Hashtbl.remove t.conns id;
  Pipe.close outgoing;
  Log.Global.debug "ws %d: disconnected" id
;;

(* HTTP *)

let json_headers = Cohttp.Header.of_list [ "content-type", "application/json" ]

let respond ?(status = `OK) json =
  let%map response =
    Cohttp_async.Server.respond_string
      ~headers:json_headers
      ~status
      (Yojson.Safe.to_string json)
  in
  `Response response
;;

let header_is req name value =
  match Cohttp.Header.get (Cohttp.Request.headers req) name with
  | Some v ->
    String.split v ~on:','
    |> List.exists ~f:(fun v -> String.Caseless.equal (String.strip v) value)
  | None -> false
;;

let ws_upgrade t req ~combined ~streams =
  match Cohttp.Header.get (Cohttp.Request.headers req) "sec-websocket-key" with
  | None ->
    respond
      ~status:`Bad_request
      (`Assoc [ "code", `Int (-1102); "msg", `String "missing Sec-WebSocket-Key" ])
  | Some key ->
    let headers =
      Cohttp.Header.of_list
        [ "upgrade", "websocket"
        ; "connection", "Upgrade"
        ; ( "sec-websocket-accept"
          , Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key )
        ]
    in
    (* [Http.Response.make], unlike [Cohttp.Response.make], does not add
       [transfer-encoding: chunked], which is invalid on a 101. *)
    let response = Http.Response.make ~status:`Switching_protocols ~headers () in
    return
      (`Expert
        (response, fun reader writer -> handle_ws t ~combined ~streams reader writer))
;;

(* The streams named by a websocket path, if it is one. *)
let ws_target uri =
  let split s = String.split s ~on:'/' |> List.filter ~f:(Fn.non String.is_empty) in
  match Uri.path uri with
  | "/ws" | "/ws/" -> Some (false, [])
  | "/stream" ->
    Some (true, Uri.get_query_param uri "streams" |> Option.value_map ~default:[] ~f:split)
  | path ->
    String.chop_prefix path ~prefix:"/ws/"
    |> Option.map ~f:(fun rest -> false, split rest)
;;

type reply = (Yojson.Safe.t, Cohttp.Code.status_code * Api_error.t) Result.t

let bad_request err : reply = Error (`Bad_request, err)

let ok_or_400 json_of = function
  | Ok x -> Ok (json_of x)
  | Error err -> bad_request err
;;

let list f xs = `List (List.map xs ~f)

let with_api_key req ~f : reply =
  match Cohttp.Header.get (Cohttp.Request.headers req) "x-mbx-apikey" with
  | None | Some "" ->
    Error (`Unauthorized, Adapt.error (Other (-2014)) "API-key format invalid.")
  | Some key -> f (Account_id.of_string key)
;;

let signed t req params ~f =
  with_api_key req ~f:(fun account ->
    match Params.find params "timestamp" with
    | None -> bad_request (Params.mandatory "timestamp")
    | Some _ ->
      ensure_account t account;
      f account)
;;

let known_symbol t symbol =
  match Adapt.spec t.adapt symbol with
  | Some _ -> Ok symbol
  | None -> Error (Adapt.error Bad_symbol "Invalid symbol.")
;;

let one_or_all t params ~f ~to_json : reply =
  match Params.symbol_opt params with
  | None ->
    Ok (list to_json (List.filter_map (Adapt.universe t.adapt) ~f:(fun s -> f s.symbol)))
  | Some symbol ->
    (match f symbol with
     | Some x -> Ok (to_json x)
     | None -> bad_request (Adapt.error Bad_symbol "Invalid symbol."))
;;

let depth_limits = [ 5; 10; 20; 50; 100; 500; 1000 ]

let route t req (meth : Cohttp.Code.meth) path params : reply =
  let open Result.Let_syntax in
  let a = t.adapt in
  let in_400 r = Result.map_error r ~f:(fun err -> `Bad_request, err) in
  match meth, path with
  | `GET, "/fapi/v1/ping" -> Ok (`Assoc [])
  | `GET, "/fapi/v1/time" ->
    Ok (`Assoc [ "serverTime", Timestamp_ms.yojson_of_t (Adapt.now_ms a) ])
  | `GET, "/fapi/v1/exchangeInfo" ->
    Ok (Exchange_info.yojson_of_t (Adapt.exchange_info a))
  | `GET, "/fapi/v1/depth" ->
    in_400
      (let%bind symbol = Params.symbol params >>= known_symbol t in
       let%bind limit = Params.int_opt params "limit" in
       let limit = Option.value limit ~default:500 in
       let%bind () =
         if List.mem depth_limits limit ~equal:Int.equal
         then Ok ()
         else Error (Params.invalid "limit")
       in
       Adapt.depth a symbol ~limit ~last_update_id:(last_update_id t symbol)
       |> Option.value_exn
       |> Depth.yojson_of_t
       |> Ok)
  | `GET, "/fapi/v1/ticker/bookTicker" ->
    one_or_all t params ~f:(Adapt.book_ticker a) ~to_json:Book_ticker.yojson_of_t
  | `GET, "/fapi/v1/premiumIndex" ->
    one_or_all t params ~f:(Adapt.premium_index a) ~to_json:Premium_index.yojson_of_t
  | `POST, "/fapi/v1/order" ->
    signed t req params ~f:(fun account ->
      Params.new_order params >>= Adapt.new_order a account |> ok_or_400 Order.yojson_of_t)
  | `POST, "/fapi/v1/batchOrders" ->
    signed t req params ~f:(fun account ->
      Params.batch_orders params
      |> ok_or_400 (fun items ->
        List.map items ~f:(fun item : Batch_orders.Response.Item.t ->
          match Params.new_order item >>= Adapt.new_order a account with
          | Ok order -> Ok order
          | Error err -> Error err)
        |> Batch_orders.Response.yojson_of_t))
  | `DELETE, "/fapi/v1/order" ->
    signed t req params ~f:(fun account ->
      Params.cancel_order params
      >>= Adapt.cancel_order a account
      |> ok_or_400 Order.yojson_of_t)
  | `DELETE, "/fapi/v1/allOpenOrders" ->
    signed t req params ~f:(fun account ->
      Params.symbol params
      >>= Adapt.cancel_all a account
      |> ok_or_400 Cancel_all.Response.yojson_of_t)
  | `GET, "/fapi/v1/openOrders" ->
    signed t req params ~f:(fun account ->
      (match Params.symbol_opt params with
       | None -> Ok None
       | Some s -> known_symbol t s |> Result.map ~f:Option.some)
      |> ok_or_400 (fun symbol ->
        list Open_order.yojson_of_t (Adapt.open_orders ?symbol a account)))
  | `GET, "/fapi/v1/userTrades" ->
    signed t req params ~f:(fun account ->
      in_400
        (let%bind symbol = Params.symbol params >>= known_symbol t in
         let%bind order_id = Params.int_opt params "orderId" in
         let%bind from_id = Params.int_opt params "fromId" in
         let%map limit = Params.int_opt params "limit" in
         Adapt.user_trades
           a
           account
           ~symbol
           ?order_id:(Option.map order_id ~f:Order_id.of_int)
           ?from_id
           ?limit
         |> list User_trade.yojson_of_t))
  | `GET, "/fapi/v2/account" ->
    signed t req params ~f:(fun account ->
      Ok (Account.yojson_of_t (Adapt.account a account)))
  | `GET, "/fapi/v2/positionRisk" ->
    signed t req params ~f:(fun account ->
      (match Params.symbol_opt params with
       | None -> Ok None
       | Some s -> known_symbol t s |> Result.map ~f:Option.some)
      |> ok_or_400 (fun symbol ->
        list Position_risk.yojson_of_t (Adapt.position_risk ?symbol a account)))
  | `POST, "/fapi/v1/listenKey" ->
    with_api_key req ~f:(fun account ->
      ensure_account t account;
      Ok (Listen_key.yojson_of_t { listen_key = listen_key t account }))
  | `PUT, "/fapi/v1/listenKey" ->
    with_api_key req ~f:(fun account ->
      match Hashtbl.find t.key_of_account account with
      | Some listen_key -> Ok (Listen_key.yojson_of_t { listen_key })
      | None ->
        bad_request (Adapt.error Invalid_listen_key "This listenKey does not exist."))
  | `DELETE, "/fapi/v1/listenKey" ->
    with_api_key req ~f:(fun account ->
      close_listen_key t account;
      Ok (`Assoc []))
  | _, path ->
    Error
      ( `Not_found
      , Adapt.error
          (Other (-5000))
          (sprintf
             "Path %s, Method %s is invalid"
             path
             (Cohttp.Code.string_of_method meth)) )
;;

let handler t ~body _addr req =
  let uri = Cohttp.Request.uri req in
  let meth = Cohttp.Request.meth req in
  match meth, ws_target uri with
  | `GET, Some (combined, streams) when header_is req "upgrade" "websocket" ->
    ws_upgrade t req ~combined ~streams
  | _ ->
    let%bind body = Cohttp_async.Body.to_string body in
    let params =
      Params.of_request
        ~query:(Uri.query uri)
        ~body:
          (match meth with
           | `GET -> ""
           | _ -> body)
    in
    Log.Global.debug_s
      [%message
        "request"
          ~meth:(Cohttp.Code.string_of_method meth)
          ~path:(Uri.path uri)
          (params : Params.t)];
    (match mutate t ~f:(fun _ -> route t req meth (Uri.path uri) params) with
     | Ok json -> respond json
     | Error (status, err) -> respond ~status (Api_error.yojson_of_t err))
;;

let listen t ~port =
  Cohttp_async.Server.create_expert
    ~on_handler_error:
      (`Call (fun _ exn -> Log.Global.error_s [%message "handler error" (exn : exn)]))
    (Tcp.Where_to_listen.of_port port)
    (handler t)
;;

let port server = Cohttp_async.Server.listening_on server

let broadcast_mark_prices t ~every_second =
  List.iter (Adapt.universe t.adapt) ~f:(fun spec ->
    let matches : Stream_name.t -> bool = function
      | Mark_price { symbol; every_second = e } ->
        Symbol.equal symbol spec.symbol && Bool.equal e every_second
      | _ -> false
    in
    if has_subscriber t ~matches
    then
      Option.iter (Adapt.mark_price_update t.adapt spec.symbol) ~f:(fun u ->
        broadcast t ~matches (lazy (Mark_price_update.yojson_of_t u))))
;;

let start_periodic t =
  let ticks = ref 0 in
  Clock_ns.every t.config.mark_price_interval (fun () ->
    broadcast_mark_prices t ~every_second:true;
    if !ticks % 3 = 0 then broadcast_mark_prices t ~every_second:false;
    incr ticks);
  Clock_ns.every t.config.step_interval (fun () -> mutate t ~f:ignore)
;;

let run_market_sim t sim =
  Clock_ns.every (Market_sim.config sim).tick_interval (fun () ->
    mutate t ~f:(fun _ -> Market_sim.tick sim))
;;
