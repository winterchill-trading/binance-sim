open! Core
open! Async
open! Exchange_core
module Anchor = Price_anchor.Anchor
module Source = Price_anchor.Source
module Server = Binance_sim.Server
module Exchange = Exchange_core_engine.Exchange

module Config = struct
  type t =
    { source : Reference.Kind.t
    ; levels : int option
    ; mark_interval : Time_ns.Span.t option
    ; max_staleness : Time_ns.Span.t option
    ; noise_traders : int option
    ; price_factor : float option
    ; size_factor : float option
    ; speed : float
    }
  [@@deriving sexp_of]

  let default =
    { source = Live
    ; levels = None
    ; mark_interval = None
    ; max_staleness = None
    ; noise_traders = None
    ; price_factor = None
    ; size_factor = None
    ; speed = 1.
    }
  ;;

  let wall_ns () = Time_ns.to_int_ns_since_epoch (Time_ns.now ())

  let server_clock t =
    let start = wall_ns () in
    match t.source with
    | Live -> wall_ns
    | (Raw _ | Norm _) when Float.equal t.speed 1. -> wall_ns
    | (Raw _ | Norm _) when Float.equal t.speed 0. -> fun () -> start
    | Raw _ | Norm _ ->
      fun () ->
        start + Float.iround_nearest_exn (Float.of_int (wall_ns () - start) *. t.speed)
  ;;

  let time which =
    Command.Arg_type.create (fun s -> Or_error.ok_exn (Reference.parse_time which s))
  ;;

  let param =
    let%map_open.Command levels =
      flag "-anchor-levels" (optional int) ~doc:"N reference levels resting per side (5)"
    and mark_interval_ms =
      flag
        "-anchor-mark-interval-ms"
        (optional int)
        ~doc:"MS minimum time between two mark price updates (100)"
    and max_staleness_ms =
      flag
        "-anchor-max-staleness-ms"
        (optional int)
        ~doc:"MS a reference silent for longer is stale (5000)"
    and noise_traders =
      flag
        "-anchor-noise"
        (optional int)
        ~doc:"N noise traders kept on anchored symbols (0)"
    and price_factor =
      flag
        "-anchor-price-factor"
        (optional float)
        ~doc:"F simulated price per reference price (1)"
    and size_factor =
      flag
        "-anchor-size-factor"
        (optional float)
        ~doc:"F simulated size per reference size (1)"
    and raw =
      flag
        "-anchor-raw"
        (optional string)
        ~doc:"DIR recorded raw minute files (the recorder's data directory)"
    and norm = flag "-anchor-norm" (optional string) ~doc:"DIR recorded event logs"
    and from =
      flag
        "-anchor-from"
        (optional (time `Start))
        ~doc:"T start of the recorded range (ISO 8601 time with zone, or a date)"
    and to_ =
      flag
        "-anchor-to"
        (optional (time `End))
        ~doc:"T end of the recorded range, exclusive (a date means that whole day)"
    and speed =
      flag
        "-anchor-speed"
        (optional_with_default 1. float)
        ~doc:"X recorded time pace: 1 real time, 0 as fast as websocket clients read"
    in
    let source : Reference.Kind.t =
      match raw, norm, from, to_ with
      | None, None, None, None -> Live
      | Some dir, None, Some from, Some to_ -> Raw { dir; from; to_ }
      | None, Some dir, Some from, Some to_ -> Norm { dir; from; to_ }
      | _ ->
        raise_s
          [%message
            "give -anchor-raw DIR or -anchor-norm DIR, with -anchor-from and -anchor-to"]
    in
    if Float.( < ) speed 0. then raise_s [%message "-anchor-speed must be >= 0"];
    { source
    ; levels
    ; mark_interval = Option.map mark_interval_ms ~f:Time_ns.Span.of_int_ms
    ; max_staleness = Option.map max_staleness_ms ~f:Time_ns.Span.of_int_ms
    ; noise_traders
    ; price_factor
    ; size_factor
    ; speed
    }
  ;;
end

type t =
  { spec : Spec.t
  ; anchor : Anchor.t
  ; source_name : string
  ; finished : unit Deferred.t
  ; close : unit -> unit Deferred.t
  }

let spec t = t.spec
let anchor t = t.anchor
let finished t = t.finished

let stop t =
  let%bind () = t.close () in
  t.finished
;;

let apply anchor : Source.Item.t -> unit = function
  | Event event -> Anchor.apply anchor event
  | Gap gap -> Anchor.gap anchor gap
  | Price { recv_ts; price } -> Anchor.apply_price anchor ~recv_ts price
;;

(* Applies each item, publishes what it produced, and waits for the websocket clients to
   take it before the next one. *)
let run_client_paced server source ~anchor =
  Pipe.iter source ~f:(fun item ->
    apply anchor item;
    Server.mutate server ~f:ignore;
    Server.pushback server)
;;

let start ?live_config ?market_sim ?source server (config : Config.t) (spec : Spec.t) =
  let open Deferred.Or_error.Let_syntax in
  let exchange = Binance_sim.Adapt.exchange (Server.adapt server) in
  let%bind () =
    match Binance_sim.Adapt.spec (Server.adapt server) spec.sim_symbol with
    | Some _ -> return ()
    | None ->
      Deferred.Or_error.error_s
        [%message
          "anchored symbol is not listed" ~sim_symbol:(spec.sim_symbol : Symbol.t)]
  in
  let%map { Reference.source; close } =
    match source with
    | Some source -> return (Reference.of_source source)
    | None -> Reference.open_ ?live_config config.source spec.reference
  in
  let reference = Market_data.Instrument.to_string spec.reference in
  let anchor =
    Anchor.create
      ?price_factor:config.price_factor
      ?size_factor:config.size_factor
      ?levels:config.levels
      ?mark_interval:config.mark_interval
      ?max_staleness:config.max_staleness
      ?noise_traders:config.noise_traders
      ?market_sim
      ~log:(fun change ->
        Log.Global.info_s [%message "anchor" reference (change : Sexp.t)])
      ~exchange
      ~reference:spec.reference
      ~sim_symbol:spec.sim_symbol
      ()
  in
  Server.on_step server (fun ~now -> Anchor.step anchor ~now);
  let finished =
    match config.source with
    | (Raw _ | Norm _) when Float.equal config.speed 0. ->
      run_client_paced server source ~anchor
    | Live | Raw _ | Norm _ ->
      let speed =
        match config.source with
        | Live -> 0.
        | Raw _ | Norm _ -> config.speed
      in
      Source.run ~speed source ~anchor ~on_item:(fun _ -> Server.mutate server ~f:ignore)
  in
  let finished =
    let%map.Deferred () = finished in
    Log.Global.info_s
      [%message
        "anchor source finished" reference ~stats:(Anchor.stats anchor : Anchor.Stats.t)]
  in
  { spec; anchor; source_name = Reference.Kind.name config.source; finished; close }
;;

let status t =
  let stats = Anchor.stats t.anchor in
  let int n = `Int n in
  let string s = `String s in
  let option f = Option.value_map ~default:`Null ~f in
  `Assoc
    [ "reference", string (Market_data.Instrument.to_string t.spec.reference)
    ; "sim_symbol", string (Symbol.to_string t.spec.sim_symbol)
    ; "source", string t.source_name
    ; ( "state"
      , string
          (match stats.stale with
           | None -> "fresh"
           | Some _ -> "stale") )
    ; ( "stale_reason"
      , option
          (fun reason -> string (Sexp.to_string [%sexp (reason : Anchor.Stale_reason.t)]))
          stats.stale )
    ; "stale_seconds", `Float (Float.of_int stats.stale_ns /. 1e9)
    ; "went_stale", int stats.went_stale
    ; "gaps", int stats.gaps
    ; "events", int stats.events
    ; "ignored", int stats.ignored
    ; "marks_set", int stats.marks_set
    ; "funding_rates_set", int stats.funding_rates_set
    ; ( "reference_price"
      , option (fun p -> string (Price.to_string p)) (Anchor.reference_price t.anchor) )
    ; "shadow_levels_resting", int (List.length (Anchor.shadow_orders t.anchor))
    ; ( "shadow"
      , `Assoc
          [ "placed", int stats.shadow.placed
          ; "cancelled", int stats.shadow.cancelled
          ; "skipped", int stats.shadow.skipped
          ; "consumed", int stats.shadow.consumed
          ] )
    ; "replay_fills", int stats.replays
    ; "replays_rejected", int stats.replays_rejected
    ; "source_finished", `Bool (Deferred.is_determined t.finished)
    ]
;;

let serve_status server ts =
  Server.add_get_route server ~path:"/sim/anchor" (fun () ->
    `List (List.map ts ~f:status))
;;

let log_status_every interval ts =
  if not (List.is_empty ts)
  then
    Clock_ns.every ~start:(Clock_ns.after interval) interval (fun () ->
      List.iter ts ~f:(fun t ->
        let stats = Anchor.stats t.anchor in
        Log.Global.info_s
          [%message
            "anchor status"
              ~reference:(Market_data.Instrument.to_string t.spec.reference)
              ~state:
                ((match stats.stale with
                  | None -> "fresh"
                  | Some _ -> "stale")
                 : string)
              ~stale_s:(Float.of_int stats.stale_ns /. 1e9 : float)
              ~events:(stats.events : int)
              ~shadow_levels:(List.length (Anchor.shadow_orders t.anchor) : int)
              ~replay_fills:(stats.replays : int)
              ~mark:(Anchor.reference_price t.anchor : Price.t option)]))
;;
