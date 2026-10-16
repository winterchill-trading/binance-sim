open! Core
open! Binance_protocol
module Exchange = Exchange_core_engine.Exchange
module Price_collar = Exchange_core_engine.Price_collar
module Halt_rule = Exchange_core_engine.Halt_rule
module Guard_event = Exchange_core_engine.Guard_event

let parse_level s =
  match String.lsplit2 (String.strip s) ~on:':' with
  | None -> Or_error.error_s [%message "halt level is not PERCENT:DURATION" s]
  | Some (pct, duration) ->
    Or_error.try_with_join (fun () ->
      let pct = Float.of_string (String.strip pct) in
      let move_bps = Float.iround_nearest_exn (pct *. 100.) in
      let duration_ns =
        match String.strip duration with
        | "reopen" -> None
        | d -> Some (Time_ns.Span.to_int_ns (Time_ns.Span.of_string d))
      in
      Ok { Halt_rule.Level.move_bps; duration_ns })
    |> Or_error.tag_s ~tag:[%message "invalid halt level" s]
;;

let parse_levels s =
  String.split s ~on:','
  |> List.filter ~f:(fun l -> not (String.is_empty (String.strip l)))
  |> List.map ~f:parse_level
  |> Or_error.combine_errors
;;

module Config = struct
  type t =
    { collar : Price_collar.Config.t option
    ; halt_rule : Halt_rule.Config.t option
    }
  [@@deriving sexp_of, equal]

  let off = { collar = None; halt_rule = None }

  let create
    ?collar_bps
    ?collar_ticks
    ?collar_reference
    ?collar_action
    ?halt_levels
    ?halt_scope
    ~anchored
    ()
    =
    let open Or_error.Let_syntax in
    let%bind band =
      match collar_bps, collar_ticks with
      | Some _, Some _ ->
        Or_error.error_string "-collar-bps and -collar-ticks exclude each other"
      | Some bps, None -> Ok (Some (Price_collar.Band.Bps bps))
      | None, Some ticks -> Ok (Some (Price_collar.Band.Ticks ticks))
      | None, None -> Ok None
    in
    let%bind collar =
      match band with
      | None ->
        if Option.is_some collar_reference || Option.is_some collar_action
        then
          Or_error.error_string
            "-collar-reference and -collar-action need -collar-bps or -collar-ticks"
        else Ok None
      | Some band ->
        let reference =
          match collar_reference with
          | Some r -> r
          | None -> if anchored then Price_collar.Reference.Mark else Last_trade
        in
        let config =
          { Price_collar.Config.reference
          ; band
          ; action = Option.value collar_action ~default:Price_collar.Action.Reject
          }
        in
        let%map () = Price_collar.Config.validate config in
        Some config
    in
    let%map halt_rule =
      match halt_levels with
      | None ->
        if Option.is_some halt_scope
        then Or_error.error_string "-halt-scope needs -halt-levels"
        else Ok None
      | Some levels ->
        let config =
          { Halt_rule.Config.levels
          ; scope = Option.value halt_scope ~default:Halt_rule.Scope.Market_wide
          ; watch = []
          ; observe = Price_collar.Reference.Mark
          ; reopen = Halt_rule.Reopen.Automatic
          }
        in
        let%map () = Halt_rule.Config.validate config in
        Some config
    in
    { collar; halt_rule }
  ;;

  let param =
    let open Command.Let_syntax in
    let reference =
      Command.Arg_type.of_alist_exn
        [ "last", Price_collar.Reference.Last_trade; "mid", Mid; "mark", Mark ]
    in
    let action =
      Command.Arg_type.of_alist_exn
        [ "reject", Price_collar.Action.Reject; "reprice", Reprice ]
    in
    let scope =
      Command.Arg_type.of_alist_exn
        [ "market", Halt_rule.Scope.Market_wide; "symbol", Per_symbol ]
    in
    let levels = Command.Arg_type.create (fun s -> ok_exn (parse_levels s)) in
    let%map_open collar_bps =
      flag
        "-collar-bps"
        (optional int)
        ~doc:
          "N reject (or re-price) aggressive orders more than N bps from the reference \
           price (default: no collar)"
    and collar_ticks =
      flag "-collar-ticks" (optional int) ~doc:"N collar band in ticks instead of bps"
    and collar_reference =
      flag
        "-collar-reference"
        (optional reference)
        ~doc:
          "last|mid|mark collar reference price (default mark when anchored, else last)"
    and collar_action =
      flag
        "-collar-action"
        (optional action)
        ~doc:"reject|reprice what happens to an order beyond the band (default reject)"
    and halt_levels =
      flag
        "-halt-levels"
        (optional levels)
        ~doc:
          "SPEC circuit-breaker levels PERCENT:DURATION,..., e.g. 7:15m,13:15m,20:reopen \
           (default: no halts)"
    and halt_scope =
      flag
        "-halt-scope"
        (optional scope)
        ~doc:
          "market|symbol a halt stops every symbol or only the one that moved (default \
           market)"
    in
    fun ~anchored ->
      create
        ?collar_bps
        ?collar_ticks
        ?collar_reference
        ?collar_action
        ?halt_levels
        ?halt_scope
        ~anchored
        ()
  ;;
end

let apply (config : Config.t) ex =
  let open Or_error.Let_syntax in
  let%bind () =
    match config.collar with
    | None -> Ok ()
    | Some collar ->
      List.map (Exchange.instruments ex) ~f:(fun (i : Exchange_core.Instrument.t) ->
        Exchange.set_collar ex i.symbol (Some collar))
      |> Or_error.all_unit
  in
  match config.halt_rule with
  | None -> Ok ()
  | Some rule -> Exchange.set_halt_rule ex (Some rule)
;;

let halted_reason = "trading halted"
let ms ns = ns / 1_000_000
let price px = `String (Price.to_string px)

let reference_name : Price_collar.Reference.t -> string = function
  | Last_trade -> "last"
  | Mid -> "mid"
  | Mark -> "mark"
;;

let side s = `String (Side.to_wire s)

let kind_fields : Guard_event.Kind.t -> (string * Yojson.Safe.t) list = function
  | Collar_rejected { side = s; limit_px; reference; bound } ->
    [ "kind", `String "collarRejected"
    ; "side", side s
    ; "price", price limit_px
    ; "reference", price reference
    ; "bound", price bound
    ]
  | Collar_repriced { side = s; limit_px; repriced_px; reference } ->
    [ "kind", `String "collarRepriced"
    ; "side", side s
    ; "price", price limit_px
    ; "repricedPrice", price repriced_px
    ; "reference", price reference
    ]
  | Halt_rejected { side = s } -> [ "kind", `String "haltRejected"; "side", side s ]
  | Halted { trigger_symbol; level; reference; px; move_bps; until } ->
    [ "kind", `String "halted"
    ; "triggerSymbol", `String (Symbol.to_string trigger_symbol)
    ; "level", `Int level
    ; "reference", price reference
    ; "price", price px
    ; "moveBps", `Int move_bps
    ; "until", Option.value_map until ~default:`Null ~f:(fun ns -> `Int (ms ns))
    ]
  | Reopen_pending -> [ "kind", `String "reopenPending" ]
  | Reopened -> [ "kind", `String "reopened" ]
;;

let event_to_yojson (e : Guard_event.t) : Yojson.Safe.t =
  `Assoc
    ([ "time", `Int (ms e.time)
     ; "symbol", `String (Symbol.to_string e.symbol)
     ; ( "account"
       , Option.value_map e.account ~default:`Null ~f:(fun a ->
           `String (Exchange_core.Account.to_string a)) )
     ; ( "orderId"
       , Option.value_map e.order_id ~default:`Null ~f:(fun id ->
           `Int (Exchange_core.Order_id.to_int_exn id)) )
     ]
     @ kind_fields e.kind)
;;

let collar_status ex (i : Exchange_core.Instrument.t) =
  Exchange.collar ex i.symbol
  |> Option.map ~f:(fun (c : Price_collar.Config.t) ->
    let reference = Exchange.collar_reference ex i.symbol in
    let bound f = Option.value_map reference ~default:`Null ~f:(fun r -> price (f r)) in
    ( Symbol.to_string i.symbol
    , `Assoc
        [ "reference", `String (reference_name c.reference)
        ; ( "band"
          , match c.band with
            | Bps n -> `Assoc [ "bps", `Int n ]
            | Ticks n -> `Assoc [ "ticks", `Int n ] )
        ; ( "action"
          , `String
              (match c.action with
               | Reject -> "reject"
               | Reprice -> "reprice") )
        ; "referencePrice", Option.value_map reference ~default:`Null ~f:price
        ; "lower", bound (fun reference -> Price_collar.lower c i ~reference)
        ; "upper", bound (fun reference -> Price_collar.upper c i ~reference)
        ] ))
;;

let halt_rule_status ex =
  match Exchange.halt_rule ex with
  | None -> `Null
  | Some (rule : Halt_rule.Config.t) ->
    `Assoc
      [ ( "levels"
        , `List
            (List.map rule.levels ~f:(fun (l : Halt_rule.Level.t) ->
               `Assoc
                 [ "moveBps", `Int l.move_bps
                 ; ( "durationMs"
                   , Option.value_map l.duration_ns ~default:`Null ~f:(fun ns ->
                       `Int (ms ns)) )
                 ])) )
      ; ( "scope"
        , `String
            (match rule.scope with
             | Market_wide -> "market"
             | Per_symbol -> "symbol") )
      ; "observe", `String (reference_name rule.observe)
      ; ( "sessionReference"
        , `Assoc
            (List.filter_map (Exchange.instruments ex) ~f:(fun i ->
               Exchange.session_reference ex i.symbol
               |> Option.map ~f:(fun px -> Symbol.to_string i.symbol, price px))) )
      ]
;;

let halted ex =
  List.filter_map (Exchange.instruments ex) ~f:(fun (i : Exchange_core.Instrument.t) ->
    Exchange.halt_status ex i.symbol
    |> Option.map ~f:(fun status ->
      ( Symbol.to_string i.symbol
      , match status with
        | `Until ns -> `Assoc [ "state", `String "halted"; "until", `Int (ms ns) ]
        | `Until_reopen -> `Assoc [ "state", `String "untilReopen" ]
        | `Reopen_pending -> `Assoc [ "state", `String "reopenPending" ] )))
;;

let stats_to_yojson (s : Guard_event.Stats.t) : Yojson.Safe.t =
  `Assoc
    [ "collarRejected", `Int s.collar_rejected
    ; "collarRepriced", `Int s.collar_repriced
    ; "collarUnreferenced", `Int s.collar_unreferenced
    ; "haltRejected", `Int s.halt_rejected
    ; "halts", `Int s.halts
    ; "reopens", `Int s.reopens
    ]
;;

let status ?(recent = []) ex : Yojson.Safe.t =
  `Assoc
    [ "collar", `Assoc (List.filter_map (Exchange.instruments ex) ~f:(collar_status ex))
    ; "haltRule", halt_rule_status ex
    ; "halted", `Assoc (halted ex)
    ; "stats", stats_to_yojson (Exchange.guard_stats ex)
    ; "recent", `List (List.map recent ~f:event_to_yojson)
    ]
;;
