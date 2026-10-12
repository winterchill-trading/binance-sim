open! Core
open! Binance_protocol
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Execution = Exchange_core_engine.Execution
module Clearinghouse = Exchange_core_engine.Clearinghouse
module Account_id = Exchange_core.Account
module Neutral = Exchange_core
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

let ms ns = Timestamp_ms.of_int (ns / 1_000_000)
let usdt = "USDT"

(* Universe *)

module Spec = struct
  type t =
    { symbol : Symbol.t
    ; base_asset : string
    ; tick_size : Price.t
    ; min_price : Price.t
    ; max_price : Price.t
    ; step_size : Size.t
    ; min_qty : Size.t
    ; max_qty : Size.t
    ; market_max_qty : Size.t
    ; min_notional : Usd.t
    ; price_precision : int
    ; quantity_precision : int
    ; max_leverage : int
    }
  [@@deriving sexp_of]

  let make
    base_asset
    ~tick
    ~min_price
    ~max_price
    ~step
    ~max_qty
    ~market_max_qty
    ~min_notional
    ~price_precision
    ~quantity_precision
    ~max_leverage
    =
    { symbol = Symbol.of_string (base_asset ^ usdt)
    ; base_asset
    ; tick_size = Price.of_string tick
    ; min_price = Price.of_string min_price
    ; max_price = Price.of_string max_price
    ; step_size = Size.of_string step
    ; min_qty = Size.of_string step
    ; max_qty = Size.of_string max_qty
    ; market_max_qty = Size.of_string market_max_qty
    ; min_notional = Usd.of_string min_notional
    ; price_precision
    ; quantity_precision
    ; max_leverage
    }
  ;;

  let default_universe =
    [ make
        "BTC"
        ~tick:"0.1"
        ~min_price:"556.8"
        ~max_price:"4529764"
        ~step:"0.001"
        ~max_qty:"1000"
        ~market_max_qty:"120"
        ~min_notional:"100"
        ~price_precision:2
        ~quantity_precision:3
        ~max_leverage:125
    ; make
        "ETH"
        ~tick:"0.01"
        ~min_price:"39.86"
        ~max_price:"306177"
        ~step:"0.001"
        ~max_qty:"10000"
        ~market_max_qty:"2000"
        ~min_notional:"20"
        ~price_precision:2
        ~quantity_precision:3
        ~max_leverage:100
    ; make
        "SOL"
        ~tick:"0.01"
        ~min_price:"0.42"
        ~max_price:"6857"
        ~step:"1"
        ~max_qty:"1000000"
        ~market_max_qty:"5000"
        ~min_notional:"5"
        ~price_precision:4
        ~quantity_precision:0
        ~max_leverage:100
    ]
  ;;

  (* The number of decimals of a power of ten no finer than 10^-8. *)
  let decimals_of_step step =
    let units = Size.to_units step in
    let rec go d = if d > 8 || Int.pow 10 (8 - d) = units then d else go (d + 1) in
    let d = go 0 in
    if d > 8 then raise_s [%message "step size is not a power of ten" (step : Size.t)];
    d
  ;;

  let fees : Neutral.Fee_schedule.t = { taker_bps = 5.; maker_bps = 2. }

  let instrument t =
    Neutral.Instrument.create
      t.symbol
      ~fees
      ~size_decimals:(decimals_of_step t.step_size)
      ~price_tick:t.tick_size
      ~max_leverage:t.max_leverage
  ;;
end

let fees = Spec.fees
let funding_interval_ns = Time_ns.Span.to_int_ns (Time_ns.Span.of_hr 8.)

let config ?(universe = Spec.default_universe) () =
  { Exchange.Config.default with
    instruments = List.map universe ~f:Spec.instrument
  ; funding_interval_ns
  ; default_funding_rate = 0.0001
  ; min_order_value = Usd.zero
  }
;;

module Order_info = struct
  (* What Binance reports about an order that the engine does not keep. *)
  type t =
    { symbol : Symbol.t
    ; side : Side.t
    ; order_type : Order_type.t
    ; time_in_force : Time_in_force.t
    ; price : Price.t
    ; orig_qty : Size.t
    ; reduce_only : bool
    ; client_order_id : Client_order_id.t
    ; mutable executed : Size.t
    ; mutable cum_quote : Usd.t
    ; mutable announced : bool
    }

  let of_open_order (o : Neutral.Open_order.t) =
    { symbol = o.symbol
    ; side = o.side
    ; order_type = Limit
    ; time_in_force = Gtc
    ; price = o.px
    ; orig_qty = Option.value o.orig_size ~default:o.size
    ; reduce_only = false
    ; client_order_id =
        Option.value
          o.client_order_id
          ~default:
            (Client_order_id.of_string
               (sprintf "sim-oid-%s" (Order_id.to_string o.order_id)))
    ; executed = Size.zero
    ; cum_quote = Usd.zero
    ; announced = false
    }
  ;;

  let avg_price t =
    if Size.is_zero t.executed then Price.zero else Notional.div t.cum_quote t.executed
  ;;
end

type t =
  { exchange : Exchange.t
  ; universe : Spec.t list
  ; orders : Order_info.t Order_id.Table.t
  ; funding_rates : float Symbol.Table.t
  ; mutable next_client_id : int
  }

let create ?(universe = Spec.default_universe) ?exchange () =
  let exchange =
    match exchange with
    | Some ex -> ex
    | None -> Exchange.create ~config:(config ~universe ()) ()
  in
  { exchange
  ; universe
  ; orders = Order_id.Table.create ()
  ; funding_rates = Symbol.Table.create ()
  ; next_client_id = 1
  }
;;

let exchange t = t.exchange
let universe t = t.universe
let spec t symbol = List.find t.universe ~f:(fun s -> Symbol.equal s.symbol symbol)
let now_ms t = ms (Exchange.now t.exchange)
let error code msg = { Api_error.code; msg }

(* Rejections *)

let precision_msg = "Precision is over the maximum defined for this asset."

let min_notional_error min =
  error
    Min_notional
    (sprintf
       "Order's notional must be no smaller than %s (unless you choose reduce only)."
       (Usd.to_string min))
;;

let api_error_of_reject (reason : Neutral.Reject_reason.t) =
  match reason with
  | Unknown_symbol -> error Bad_symbol "Invalid symbol."
  | Unsupported msg -> error Invalid_parameter msg
  | Invalid_size -> error Bad_precision precision_msg
  | Invalid_price ->
    error Price_not_increased_by_tick_size "Price not increased by tick size."
  | Duplicate_client_order_id -> error (Other (-4116)) "ClientOrderId is duplicated."
  | Reduce_only_would_increase -> error Reduce_only_reject "ReduceOnly Order is rejected."
  | Below_min_value { min } -> min_notional_error min
  | Insufficient_margin ->
    error New_order_rejected "Account has insufficient balance for requested action."
  | No_liquidity -> error Unable_to_fill "Unable to fill."
  | Self_trade ->
    error
      New_order_rejected
      "Order would immediately match against an order of the same account."
  | Post_only_would_cross _ ->
    error
      Gtx_order_reject
      "Due to the order could not be executed as maker, the Post Only order will be \
       rejected. The order will not be recorded in the order history"
  | Order_not_found -> error Cancel_rejected "Unknown order sent."
;;

let mandatory name =
  error
    Mandatory_param_empty_or_malformed
    (sprintf "Mandatory parameter '%s' was not sent, was empty/null, or malformed." name)
;;

(* Validation *)

let has_at_most_decimals units decimals =
  decimals >= 8 || units % Int.pow 10 (8 - decimals) = 0
;;

let check cond err = if cond then Ok () else Error err

(* Liquidity on the opposite side at prices no worse than [px]. *)
let crossing_size t ~symbol ~(side : Side.t) ~px =
  match Exchange.l2 t.exchange symbol ~n_levels:Int.max_value with
  | None -> Size.zero
  | Some book ->
    let levels, crosses =
      match side with
      | Buy -> book.asks, fun (l : Neutral.L2.Level.t) -> Price.( <= ) l.px px
      | Sell -> book.bids, fun (l : Neutral.L2.Level.t) -> Price.( >= ) l.px px
    in
    List.take_while levels ~f:crosses
    |> List.map ~f:(fun (l : Neutral.L2.Level.t) -> l.sz)
    |> Size.sum
;;

(* The engine request and the order attributes to remember, or the rejection. *)
let validate t (spec : Spec.t) (req : New_order.Request.t) =
  let open Result.Let_syntax in
  let unsupported err = Neutral.Reject_reason.Unsupported err.Api_error.msg, err in
  let%bind () =
    match req.position_side with
    | None | Some Both -> Ok ()
    | Some (Long | Short) ->
      Error
        (unsupported
           (error
              Position_side_not_match
              "Order's position side does not match user's setting."))
  in
  let%bind is_limit =
    match req.order_type with
    | Limit -> Ok true
    | Market -> Ok false
    | Other _ -> Error (unsupported (error Invalid_order_type "Invalid orderType."))
  in
  let%bind qty =
    match req.quantity with
    | None -> Error (unsupported (mandatory "quantity"))
    | Some q -> Ok q
  in
  let invalid_size err = Neutral.Reject_reason.Invalid_size, err in
  let%bind () =
    check
      (Size.is_positive qty)
      (invalid_size (error Qty_less_than_zero "Quantity less than or equal to zero."))
  in
  let%bind () =
    check
      (has_at_most_decimals (Size.to_units qty) spec.quantity_precision
       && Size.to_units qty % Size.to_units spec.step_size = 0)
      (invalid_size (error Bad_precision precision_msg))
  in
  let%bind () =
    let max = if is_limit then spec.max_qty else spec.market_max_qty in
    check
      (Size.( <= ) qty max)
      (invalid_size
         (error Qty_greater_than_max_qty "Quantity greater than max quantity."))
  in
  let%bind time_in_force, px, order_type =
    if not is_limit
    then Ok (Time_in_force.Gtc, None, Neutral.Order_type.market)
    else (
      let%bind tif, order_type =
        match req.time_in_force with
        | None -> Error (unsupported (mandatory "timeInForce"))
        | Some Gtc -> Ok (Time_in_force.Gtc, Neutral.Order_type.gtc)
        | Some Ioc -> Ok (Ioc, Neutral.Order_type.ioc)
        | Some Fok -> Ok (Fok, Neutral.Order_type.ioc)
        | Some Gtx -> Ok (Gtx, Neutral.Order_type.alo)
        | Some (Gtd | Rpi) ->
          Error (unsupported (error Invalid_tif "Invalid timeInForce."))
      in
      let%bind px =
        match req.price with
        | None -> Error (unsupported (mandatory "price"))
        | Some px -> Ok px
      in
      let invalid_price err = Neutral.Reject_reason.Invalid_price, err in
      let%bind () =
        check
          (Price.is_positive px)
          (invalid_price (error Price_less_than_zero "Price less than 0."))
      in
      let%bind () =
        check
          (has_at_most_decimals (Price.to_units px) spec.price_precision)
          (invalid_price (error Bad_precision precision_msg))
      in
      let%bind () =
        check
          (Price.to_units px % Price.to_units spec.tick_size = 0)
          (invalid_price
             (error Price_not_increased_by_tick_size "Price not increased by tick size."))
      in
      Ok (tif, Some px, order_type))
  in
  let reduce_only = Option.value req.reduce_only ~default:false in
  let%bind () =
    if reduce_only
    then Ok ()
    else (
      let reference =
        match px with
        | Some px -> Some px
        | None -> Exchange.mark t.exchange spec.symbol
      in
      match reference with
      | Some px when Usd.( < ) (Notional.mul px qty) spec.min_notional ->
        Error
          ( Neutral.Reject_reason.Below_min_value { min = spec.min_notional }
          , min_notional_error spec.min_notional )
      | Some _ | None -> Ok ())
  in
  let%bind () =
    match time_in_force, px with
    | Fok, Some px
      when Size.( < ) (crossing_size t ~symbol:spec.symbol ~side:req.side ~px) qty ->
      Error
        ( Neutral.Reject_reason.No_liquidity
        , error
            Fok_order_reject
            "Due to the order could not be filled immediately, the FOK order has been \
             rejected. The order will not be recorded in the order history" )
    | _ -> Ok ()
  in
  let client_order_id =
    match req.new_client_order_id with
    | Some id -> id
    | None ->
      let id = t.next_client_id in
      t.next_client_id <- id + 1;
      Client_order_id.of_string (sprintf "sim-%d" id)
  in
  let neutral : Neutral.Order_request.t =
    { symbol = spec.symbol
    ; side = req.side
    ; size = qty
    ; px
    ; order_type
    ; reduce_only
    ; client_order_id = Some client_order_id
    }
  in
  let info : Order_info.t =
    { symbol = spec.symbol
    ; side = req.side
    ; order_type = req.order_type
    ; time_in_force
    ; price = Option.value px ~default:Price.zero
    ; orig_qty = qty
    ; reduce_only
    ; client_order_id
    ; executed = Size.zero
    ; cum_quote = Usd.zero
    ; announced = false
    }
  in
  Ok (neutral, info)
;;

(* Order objects *)

let order_of_info
  ?time
  ?cum_qty
  t
  (info : Order_info.t)
  ~order_id
  ~(status : Order_status.t)
  ~executed
  ~cum_quote
  : Order.t
  =
  { order_id
  ; symbol = info.symbol
  ; client_order_id = info.client_order_id
  ; side = info.side
  ; position_side = Some Both
  ; status
  ; order_type = info.order_type
  ; orig_type = Some info.order_type
  ; time_in_force = info.time_in_force
  ; price = info.price
  ; orig_qty = info.orig_qty
  ; executed_qty = executed
  ; cum_qty
  ; cum_quote = Some cum_quote
  ; avg_price =
      Some (if Size.is_zero executed then Price.zero else Notional.div cum_quote executed)
  ; stop_price = Some Price.zero
  ; activate_price = None
  ; price_rate = None
  ; reduce_only = info.reduce_only
  ; close_position = false
  ; price_protect = false
  ; working_type = Some Contract_price
  ; price_match = Some "NONE"
  ; self_trade_prevention_mode = Some "EXPIRE_TAKER"
  ; good_till_date = Some (Timestamp_ms.of_int 0)
  ; time
  ; update_time = now_ms t
  }
;;

(* The taker fills of the order just placed: they are the account's newest. *)
let taker_fills t account order_id =
  Exchange.fills t.exchange account
  |> List.take_while ~f:(fun (e : Execution.t) ->
    e.settlement.crossed && Order_id.equal (Execution.order_id e) order_id)
;;

let fills_total (fills : Execution.t list) =
  ( Size.sum (List.map fills ~f:(fun e -> e.fill.sz))
  , Usd.sum (List.map fills ~f:(fun e -> Notional.mul e.fill.px e.fill.sz)) )
;;

let new_order t account (req : New_order.Request.t) =
  let ex = t.exchange in
  let reject ?symbol (reason, err) =
    ignore (Exchange.reject ?symbol ex account reason : Neutral.Order_status.t);
    Error err
  in
  match spec t req.symbol with
  | None -> reject (Unknown_symbol, error Bad_symbol "Invalid symbol.")
  | Some spec ->
    (match validate t spec req with
     | Error rejection -> reject ~symbol:spec.symbol rejection
     | Ok (neutral, info) ->
       let respond order_id status =
         Hashtbl.set t.orders ~key:order_id ~data:info;
         let executed, cum_quote = fills_total (taker_fills t account order_id) in
         let status =
           match status with
           | `Resting ->
             if Size.is_zero executed
             then Order_status.New
             else Order_status.Partially_filled
           | `Done ->
             if Size.equal executed info.orig_qty
             then Order_status.Filled
             else Order_status.Expired
         in
         Ok
           (order_of_info t info ~order_id ~status ~executed ~cum_quote ~cum_qty:executed)
       in
       (match Exchange.place ex account neutral with
        | Resting { order_id; client_order_id = _ } -> respond order_id `Resting
        | Filled { order_id; _ } -> respond order_id `Done
        | Rejected reason -> Error (api_error_of_reject reason)))
;;

let info_of_open_order t (o : Neutral.Open_order.t) =
  match Hashtbl.find t.orders o.order_id with
  | Some info -> info
  | None -> Order_info.of_open_order o
;;

let open_order_record t (o : Neutral.Open_order.t) : Open_order.t =
  let info = info_of_open_order t o in
  let orig = Option.value o.orig_size ~default:info.orig_qty in
  let executed = Size.( - ) orig o.size in
  order_of_info
    t
    { info with orig_qty = orig }
    ~time:(ms o.timestamp)
    ~order_id:o.order_id
    ~status:(if Size.is_zero executed then New else Partially_filled)
    ~executed
    ~cum_quote:info.cum_quote
;;

let resting t account =
  (* The engine lists newest first. *)
  List.rev (Exchange.open_orders t.exchange account)
;;

let open_orders ?symbol t account =
  resting t account
  |> List.filter ~f:(fun (o : Neutral.Open_order.t) ->
    Option.for_all symbol ~f:(Symbol.equal o.symbol))
  |> List.map ~f:(open_order_record t)
;;

let cancel_resting t account (o : Neutral.Open_order.t) =
  let record = open_order_record t o in
  match Exchange.cancel t.exchange account ~symbol:o.symbol o.order_id with
  | Cancelled ->
    Ok { record with status = Canceled; time = None; cum_qty = Some record.executed_qty }
  | Not_found -> Error (api_error_of_reject Order_not_found)
;;

let cancel_order t account (req : Cancel_order.Request.t) =
  match spec t req.symbol with
  | None -> Error (error Bad_symbol "Invalid symbol.")
  | Some _ ->
    let matches (o : Neutral.Open_order.t) =
      Symbol.equal o.symbol req.symbol
      &&
      match req.target with
      | Order_id id -> Order_id.equal o.order_id id
      | Client_order_id cid ->
        Client_order_id.equal (info_of_open_order t o).client_order_id cid
    in
    (match List.find (resting t account) ~f:matches with
     | None -> Error (api_error_of_reject Order_not_found)
     | Some o -> cancel_resting t account o)
;;

let cancel_all t account symbol =
  match spec t symbol with
  | None -> Error (error Bad_symbol "Invalid symbol.")
  | Some _ ->
    List.iter (resting t account) ~f:(fun o ->
      if Symbol.equal o.symbol symbol
      then ignore (cancel_resting t account o : (Order.t, Api_error.t) Result.t));
    Ok
      { Cancel_all.Response.code = 200
      ; msg = "The operation of cancel all open order is done."
      }
;;

let decimal_of_usd u = Decimal.of_units (Usd.to_units u)

let user_trade (e : Execution.t) : User_trade.t =
  let s = e.settlement in
  { id = e.fill.tid
  ; order_id = Execution.order_id e
  ; symbol = e.fill.symbol
  ; side = s.side
  ; position_side = Some Both
  ; price = e.fill.px
  ; qty = e.fill.sz
  ; quote_qty = Notional.mul e.fill.px e.fill.sz
  ; commission = decimal_of_usd s.fee
  ; commission_asset = usdt
  ; realized_pnl = s.change.closed_pnl
  ; margin_asset = Some usdt
  ; maker = not s.crossed
  ; buyer = Side.equal s.side Buy
  ; time = ms e.fill.time
  }
;;

let user_trades ?order_id ?from_id ?(limit = 500) t account ~symbol =
  let limit = Int.clamp_exn limit ~min:1 ~max:1000 in
  let trades =
    Exchange.fills t.exchange account
    |> List.rev
    |> List.filter ~f:(fun (e : Execution.t) ->
      Symbol.equal e.fill.symbol symbol
      && Option.for_all order_id ~f:(Order_id.equal (Execution.order_id e))
      && Option.for_all from_id ~f:(fun id -> Neutral.Trade_id.to_int e.fill.tid >= id))
    |> List.map ~f:user_trade
  in
  match from_id with
  | Some _ -> List.take trades limit
  | None -> List.drop trades (List.length trades - limit)
;;

(* Account *)

let leverage t account symbol =
  Clearinghouse.leverage (Exchange.clearinghouse t.exchange) account symbol
;;

(* Initial margin held by the account's resting orders in [symbol]. *)
let open_order_margin t account symbol =
  resting t account
  |> List.filter ~f:(fun (o : Neutral.Open_order.t) ->
    Symbol.equal o.symbol symbol && not (info_of_open_order t o).reduce_only)
  |> List.map ~f:(fun (o : Neutral.Open_order.t) ->
    Usd.div_int (Notional.mul o.px o.size) (leverage t account symbol))
  |> Usd.sum
;;

let signed_notional (p : Neutral.Position_view.t) =
  if Size.is_negative p.size then Usd.neg p.notional else p.notional
;;

let maint_margin (spec : Spec.t) (p : Neutral.Position_view.t) =
  Usd.div_int p.notional (2 * spec.max_leverage)
;;

let account t account : Account.t =
  let v = Exchange.account_view t.exchange account in
  let now = now_ms t in
  let positions =
    List.map t.universe ~f:(fun spec : Account.Position.t ->
      let order_margin = open_order_margin t account spec.symbol in
      let pos = Neutral.Account_view.find_position v spec.symbol in
      let get f ~default = Option.value_map pos ~f ~default in
      let position_margin = get (fun p -> p.margin_used) ~default:Usd.zero in
      { symbol = spec.symbol
      ; position_side = Both
      ; position_amt = get (fun p -> p.size) ~default:Size.zero
      ; entry_price = Some (get (fun p -> p.entry_px) ~default:Price.zero)
      ; unrealized_profit = get (fun p -> p.unrealized_pnl) ~default:Usd.zero
      ; leverage = Some (leverage t account spec.symbol)
      ; liquidation_price = None
      ; isolated = Some false
      ; initial_margin = Some (Usd.( + ) position_margin order_margin)
      ; maint_margin = Some (get (maint_margin spec) ~default:Usd.zero)
      ; position_initial_margin = Some position_margin
      ; open_order_initial_margin = Some order_margin
      ; isolated_margin = None
      ; isolated_wallet = Some Usd.zero
      ; notional = Some (get signed_notional ~default:Usd.zero)
      ; max_notional = None
      ; update_time = now
      })
  in
  let sum f =
    Usd.sum (List.map positions ~f:(fun p -> Option.value (f p) ~default:Usd.zero))
  in
  let order_margin = sum (fun p -> p.open_order_initial_margin) in
  let initial_margin = Usd.( + ) v.margin_used order_margin in
  let unrealized = Usd.( - ) v.equity v.balance in
  let available = Usd.max Usd.zero (Usd.( - ) v.equity initial_margin) in
  let max_withdraw = Usd.min available (Usd.max Usd.zero v.balance) in
  let asset : Account.Asset.t =
    { asset = usdt
    ; wallet_balance = v.balance
    ; unrealized_profit = unrealized
    ; margin_balance = v.equity
    ; maint_margin = Some v.maintenance_margin
    ; initial_margin = Some initial_margin
    ; position_initial_margin = Some v.margin_used
    ; open_order_initial_margin = Some order_margin
    ; cross_wallet_balance = Some v.balance
    ; cross_un_pnl = Some unrealized
    ; available_balance = available
    ; max_withdraw_amount = Some max_withdraw
    ; margin_available = Some true
    ; update_time = now
    }
  in
  { total_wallet_balance = v.balance
  ; total_unrealized_profit = unrealized
  ; total_margin_balance = v.equity
  ; total_initial_margin = Some initial_margin
  ; total_maint_margin = Some v.maintenance_margin
  ; total_position_initial_margin = Some v.margin_used
  ; total_open_order_initial_margin = Some order_margin
  ; total_cross_wallet_balance = Some v.balance
  ; total_cross_un_pnl = Some unrealized
  ; available_balance = available
  ; max_withdraw_amount = Some max_withdraw
  ; can_trade = Some true
  ; fee_tier = Some 0
  ; multi_assets_margin = Some false
  ; update_time = Some (Timestamp_ms.of_int 0)
  ; assets = [ asset ]
  ; positions
  }
;;

let mark t symbol = Option.value (Exchange.mark t.exchange symbol) ~default:Price.zero

let position_risk ?symbol t account =
  let v = Exchange.account_view t.exchange account in
  List.filter t.universe ~f:(fun spec ->
    Option.for_all symbol ~f:(Symbol.equal spec.symbol))
  |> List.map ~f:(fun spec : Position_risk.t ->
    let pos = Neutral.Account_view.find_position v spec.symbol in
    let get f ~default = Option.value_map pos ~f ~default in
    { symbol = spec.symbol
    ; position_side = Both
    ; position_amt = get (fun p -> p.size) ~default:Size.zero
    ; entry_price = get (fun p -> p.entry_px) ~default:Price.zero
    ; break_even_price = None
    ; mark_price = mark t spec.symbol
    ; unrealized_profit = get (fun p -> p.unrealized_pnl) ~default:Usd.zero
    ; liquidation_price =
        get
          (fun p -> Option.value p.liquidation_px ~default:Price.zero)
          ~default:Price.zero
    ; isolated_margin = Some Usd.zero
    ; notional = Some (get signed_notional ~default:Usd.zero)
    ; isolated_wallet = Some Usd.zero
    ; margin_asset = None
    ; leverage = Some (leverage t account spec.symbol)
    ; margin_type = Some "cross"
    ; is_auto_add_margin = Some false
    ; max_notional_value = None
    ; initial_margin = None
    ; maint_margin = None
    ; position_initial_margin = None
    ; open_order_initial_margin = None
    ; adl = None
    ; update_time = now_ms t
    })
;;

(* Market data *)

let book_level (l : Neutral.L2.Level.t) : Book_level.t = { price = l.px; qty = l.sz }

let depth_of_l2 (l2 : Neutral.L2.t) ~last_update_id ~now : Depth.t =
  { last_update_id
  ; event_time = now
  ; transaction_time = ms l2.time
  ; bids = List.map l2.bids ~f:book_level
  ; asks = List.map l2.asks ~f:book_level
  }
;;

let depth t symbol ~limit ~last_update_id =
  Exchange.l2 t.exchange symbol ~n_levels:limit
  |> Option.map ~f:(depth_of_l2 ~last_update_id ~now:(now_ms t))
;;

let bbo t symbol =
  Exchange.l2 t.exchange symbol ~n_levels:1
  |> Option.map ~f:(fun (l2 : Neutral.L2.t) ->
    let level = function
      | Some (l : Neutral.L2.Level.t) -> l.px, l.sz
      | None -> Price.zero, Size.zero
    in
    level (Neutral.L2.best_bid l2), level (Neutral.L2.best_ask l2))
;;

let book_ticker t symbol =
  bbo t symbol
  |> Option.map ~f:(fun ((bid_price, bid_qty), (ask_price, ask_qty)) : Book_ticker.t ->
    { symbol; bid_price; bid_qty; ask_price; ask_qty; time = now_ms t })
;;

let funding_rate t symbol =
  Hashtbl.find t.funding_rates symbol
  |> Option.value ~default:(Exchange.config t.exchange).default_funding_rate
;;

let next_funding_time t =
  let interval = (Exchange.config t.exchange).funding_interval_ns in
  ms (((Exchange.now t.exchange / interval) + 1) * interval)
;;

let premium_index t symbol =
  Option.map (spec t symbol) ~f:(fun spec : Premium_index.t ->
    let mark = mark t spec.symbol in
    { symbol = spec.symbol
    ; mark_price = mark
    ; index_price = mark
    ; estimated_settle_price = Some mark
    ; last_funding_rate = Decimal.of_float (funding_rate t spec.symbol)
    ; interest_rate = Some (Decimal.of_string "0.0001")
    ; next_funding_time = next_funding_time t
    ; time = now_ms t
    })
;;

let symbol_info (spec : Spec.t) : Exchange_info.Symbol_info.t =
  { symbol = spec.symbol
  ; pair = Symbol.to_string spec.symbol
  ; contract_type = "PERPETUAL"
  ; delivery_date = Timestamp_ms.of_int 4133404800000
  ; onboard_date = Timestamp_ms.of_int 1569398400000
  ; status = "TRADING"
  ; base_asset = spec.base_asset
  ; quote_asset = usdt
  ; margin_asset = usdt
  ; price_precision = spec.price_precision
  ; quantity_precision = spec.quantity_precision
  ; base_asset_precision = 8
  ; quote_precision = 8
  ; underlying_type = Some "COIN"
  ; underlying_sub_type = []
  ; trigger_protect = Some (Decimal.of_string "0.05")
  ; liquidation_fee = Some (Decimal.of_string "0.0125")
  ; market_take_bound = Some (Decimal.of_string "0.05")
  ; filters =
      [ Price_filter
          { min_price = spec.min_price
          ; max_price = spec.max_price
          ; tick_size = spec.tick_size
          }
      ; Lot_size
          { min_qty = spec.min_qty; max_qty = spec.max_qty; step_size = spec.step_size }
      ; Market_lot_size
          { min_qty = spec.min_qty
          ; max_qty = spec.market_max_qty
          ; step_size = spec.step_size
          }
      ; Max_num_orders { limit = 200 }
      ; Max_num_algo_orders { limit = 10 }
      ; Min_notional { notional = spec.min_notional }
      ; Percent_price
          { multiplier_up = Decimal.of_string "1.05"
          ; multiplier_down = Decimal.of_string "0.95"
          ; multiplier_decimal = 4
          }
      ]
  ; order_types = [ Limit; Market ]
  ; time_in_force = [ Gtc; Ioc; Fok; Gtx ]
  }
;;

let exchange_info t : Exchange_info.t =
  let rate_limit rate_limit_type interval interval_num limit =
    { Exchange_info.Rate_limit.rate_limit_type; interval; interval_num; limit }
  in
  { timezone = "UTC"
  ; server_time = now_ms t
  ; rate_limits =
      [ rate_limit "REQUEST_WEIGHT" "MINUTE" 1 2400
      ; rate_limit "ORDERS" "MINUTE" 1 1200
      ; rate_limit "ORDERS" "SECOND" 10 300
      ]
  ; assets = [ { asset = usdt; margin_available = true; auto_asset_exchange = None } ]
  ; symbols = List.map t.universe ~f:symbol_info
  }
;;

(* Streams *)

let agg_trade (fill : Order_book.Fill.t) : Agg_trade.t =
  { event_time = ms fill.time
  ; symbol = fill.symbol
  ; agg_trade_id = Neutral.Trade_id.to_int fill.tid
  ; price = fill.px
  ; qty = fill.sz
  ; normal_qty = None
  ; first_trade_id = fill.tid
  ; last_trade_id = fill.tid
  ; trade_time = ms fill.time
  ; buyer_is_maker = Side.equal fill.taker_side Sell
  }
;;

let book_ticker_event t symbol ~update_id =
  bbo t symbol
  |> Option.map
       ~f:(fun ((bid_price, bid_qty), (ask_price, ask_qty)) : Book_ticker_event.t ->
         { update_id
         ; event_time = now_ms t
         ; transaction_time = now_ms t
         ; symbol
         ; bid_price
         ; bid_qty
         ; ask_price
         ; ask_qty
         })
;;

let mark_price_update t symbol =
  premium_index t symbol
  |> Option.map ~f:(fun (p : Premium_index.t) : Mark_price_update.t ->
    { event_time = p.time
    ; symbol = p.symbol
    ; mark_price = p.mark_price
    ; index_price = Some p.index_price
    ; estimated_settle_price = p.estimated_settle_price
    ; funding_rate = p.last_funding_rate
    ; next_funding_time = p.next_funding_time
    })
;;

let depth_event
  t
  symbol
  ~bids
  ~asks
  ~first_update_id
  ~final_update_id
  ~prev_final_update_id
  : Depth_update.t
  =
  { event_time = now_ms t
  ; transaction_time = now_ms t
  ; symbol
  ; first_update_id
  ; final_update_id
  ; prev_final_update_id
  ; bids
  ; asks
  }
;;

let depth_update t symbol ~bids ~asks =
  let book =
    Exchange.l2 t.exchange symbol ~n_levels:Int.max_value
    |> Option.value ~default:{ Neutral.L2.symbol; time = 0; bids = []; asks = [] }
  in
  let side levels prices ~compare =
    let qty =
      Price.Map.of_alist_reduce
        (List.map levels ~f:(fun (l : Neutral.L2.Level.t) -> l.px, l.sz))
        ~f:Size.( + )
    in
    List.dedup_and_sort prices ~compare
    |> List.map ~f:(fun price : Book_level.t ->
      { price; qty = Map.find qty price |> Option.value ~default:Size.zero })
  in
  depth_event
    t
    symbol
    ~bids:(side book.bids bids ~compare:(fun a b -> Price.compare b a))
    ~asks:(side book.asks asks ~compare:Price.compare)
;;

let partial_depth t symbol ~levels =
  let book =
    Exchange.l2 t.exchange symbol ~n_levels:levels
    |> Option.value ~default:{ Neutral.L2.symbol; time = 0; bids = []; asks = [] }
  in
  depth_event
    t
    symbol
    ~bids:(List.map book.bids ~f:book_level)
    ~asks:(List.map book.asks ~f:book_level)
;;

(* User data stream *)

let order_trade_update
  ?(last_qty = Size.zero)
  ?(last_px = Price.zero)
  ?commission
  ?(trade_id = 0)
  ?(is_maker = false)
  ?(realized = Usd.zero)
  (info : Order_info.t)
  ~order_id
  ~(execution_type : Execution_type.t)
  ~(status : Order_status.t)
  ~time
  : User_event.t
  =
  Order_trade_update
    { event_time = ms time
    ; transaction_time = ms time
    ; order =
        { symbol = info.symbol
        ; client_order_id = info.client_order_id
        ; side = info.side
        ; order_type = info.order_type
        ; time_in_force = info.time_in_force
        ; orig_qty = info.orig_qty
        ; price = info.price
        ; avg_price = Order_info.avg_price info
        ; stop_price = Some Price.zero
        ; execution_type
        ; status
        ; order_id
        ; last_filled_qty = last_qty
        ; cum_filled_qty = info.executed
        ; last_filled_price = last_px
        ; commission_asset = Option.map commission ~f:(const usdt)
        ; commission = Option.map commission ~f:decimal_of_usd
        ; trade_time = ms time
        ; trade_id = Neutral.Trade_id.of_int trade_id
        ; bids_notional = None
        ; asks_notional = None
        ; is_maker
        ; reduce_only = info.reduce_only
        ; working_type = Some Contract_price
        ; orig_type = Some info.order_type
        ; position_side = Some Both
        ; close_position = false
        ; activation_price = None
        ; callback_rate = None
        ; price_protect = false
        ; si = None
        ; ss = None
        ; realized_profit = realized
        ; self_trade_prevention_mode = Some "EXPIRE_TAKER"
        ; price_match = Some "NONE"
        ; good_till_date = Some (Timestamp_ms.of_int 0)
        ; expiry_reason = None
        }
    }
;;

let account_update
  t
  account
  ~(reason : Account_update.Reason.t)
  ~symbols
  ~balance_change
  ~time
  : User_event.t
  =
  let v = Exchange.account_view t.exchange account in
  Account_update
    { event_time = ms time
    ; transaction_time = ms time
    ; reason
    ; balances =
        [ { asset = usdt
          ; wallet_balance = v.balance
          ; cross_wallet_balance = v.balance
          ; balance_change
          }
        ]
    ; positions =
        List.map symbols ~f:(fun symbol : Account_update.Position.t ->
          let pos = Neutral.Account_view.find_position v symbol in
          let get f ~default = Option.value_map pos ~f ~default in
          { symbol
          ; position_amt = get (fun p -> p.size) ~default:Size.zero
          ; entry_price = get (fun p -> p.entry_px) ~default:Price.zero
          ; breakeven_price = None
          ; accumulated_realized = Some (get (fun p -> p.realized_pnl) ~default:Usd.zero)
          ; unrealized_pnl = get (fun p -> p.unrealized_pnl) ~default:Usd.zero
          ; margin_type = Some "cross"
          ; isolated_wallet = Some Usd.zero
          ; position_side = Both
          })
    }
;;

let user_events ?(interested = fun _ -> true) t (event : Event.t) =
  let for_account account events =
    if interested account
    then List.map (Lazy.force events) ~f:(fun e -> account, e)
    else []
  in
  let announce info ~order_id ~time =
    if info.Order_info.announced
    then []
    else (
      info.announced <- true;
      [ order_trade_update info ~order_id ~execution_type:New ~status:New ~time ])
  in
  let finish order_id = Hashtbl.remove t.orders order_id in
  match event with
  | Order_rejected _ -> []
  | Order_accepted { account; order; time } ->
    let info = info_of_open_order t order in
    Hashtbl.set t.orders ~key:order.order_id ~data:info;
    let new_ = announce info ~order_id:order.order_id ~time in
    for_account account (lazy new_)
  | Order_filled { order; _ } ->
    finish order.order_id;
    []
  | Order_cancelled { account; order; reason; time } ->
    let info = info_of_open_order t order in
    finish order.order_id;
    let execution_type, (status : Order_status.t) =
      match reason with
      | User | Modified | Liquidated -> Execution_type.Canceled, Order_status.Canceled
      | Ioc_unfilled -> Expired, Expired
      | Self_trade -> Expired, Expired_in_match
    in
    let new_ = announce info ~order_id:order.order_id ~time in
    for_account
      account
      (lazy
        (new_
         @ [ order_trade_update
               info
               ~order_id:order.order_id
               ~execution_type
               ~status
               ~time
           ]))
  | Fill { fill; taker; maker } ->
    let side (s : Clearinghouse.Settlement.t) ~order_id ~cloid =
      let info =
        match Hashtbl.find t.orders order_id with
        | Some info -> info
        | None ->
          (* An order the adapter never saw resting, e.g. a market order of the simulated
             noise traders. *)
          let info =
            Order_info.of_open_order
              { symbol = fill.symbol
              ; side = s.side
              ; px = fill.px
              ; size = fill.sz
              ; orig_size = Some fill.sz
              ; order_id
              ; client_order_id = cloid
              ; timestamp = fill.time
              }
          in
          Hashtbl.set t.orders ~key:order_id ~data:info;
          info
      in
      let new_ = announce info ~order_id ~time:fill.time in
      info.executed <- Size.( + ) info.executed fill.sz;
      info.cum_quote <- Usd.( + ) info.cum_quote (Notional.mul fill.px fill.sz);
      let status : Order_status.t =
        if Size.( >= ) info.executed info.orig_qty then Filled else Partially_filled
      in
      if Order_status.is_final status then finish order_id;
      for_account
        s.account
        (lazy
          (new_
           @ [ order_trade_update
                 info
                 ~order_id
                 ~execution_type:Trade
                 ~status
                 ~time:fill.time
                 ~last_qty:fill.sz
                 ~last_px:fill.px
                 ~commission:s.fee
                 ~trade_id:(Neutral.Trade_id.to_int fill.tid)
                 ~is_maker:(not s.crossed)
                 ~realized:s.change.closed_pnl
             ; account_update
                 t
                 s.account
                 ~reason:Order
                 ~symbols:[ fill.symbol ]
                 ~balance_change:Usd.zero
                 ~time:fill.time
             ]))
    in
    side taker ~order_id:fill.taker_oid ~cloid:fill.taker_cloid
    @ side maker ~order_id:fill.maker_oid ~cloid:fill.maker_cloid
  | Liquidation { liquidation = l; time } ->
    for_account
      l.account
      (lazy
        [ account_update
            t
            l.account
            ~reason:Order
            ~symbols:[ l.symbol ]
            ~balance_change:Usd.zero
            ~time
        ])
  | Funding { symbol; rate; payments; time; mark = _ } ->
    Hashtbl.set t.funding_rates ~key:symbol ~data:rate;
    List.concat_map payments ~f:(fun p ->
      for_account
        p.account
        (lazy
          [ account_update
              t
              p.account
              ~reason:Funding_fee
              ~symbols:[]
              ~balance_change:(Usd.neg p.payment)
              ~time
          ]))
;;
