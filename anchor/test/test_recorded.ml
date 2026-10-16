(* The simulator anchored to a recorded Binance minute (raw minute files under
   fixtures/raw, copied from binance-client's fixtures), with a client order resting
   through the prices the reference later trades at. The journal replays the run. *)

open! Core
open! Async
open Binance_sim_anchor
open Helpers

let spec = Or_error.ok_exn (Spec.of_string "binance:BTCUSDT=BTCUSDT")

let raw : Reference.Kind.t =
  Raw
    { dir = "fixtures"
    ; from = Time_ns.of_string_with_utc_offset "2026-10-12T15:05:00Z"
    ; to_ = Time_ns.of_string_with_utc_offset "2026-10-12T15:06:00Z"
    }
;;

let%expect_test "anchored to a recorded minute; the journal replays the run" =
  Log.Global.set_output [];
  let sim = create_sim () in
  (* Rests alone until the reference book arrives; buyers sweep through it at 15:05:47. *)
  place sim ~key:"client" ~side:"SELL" ~tif:"GTX" ~price:"82615" ~qty:"0.01";
  let%bind anchored =
    Anchored.start
      sim.server
      { Anchored.Config.default with source = raw; speed = 0. }
      spec
    >>| Or_error.ok_exn
  in
  let%bind () = Anchored.finished anchored in
  print_status (Anchored.status anchored);
  print_book sim;
  print_s
    [%message
      ""
        ~client_open_orders:
          (List.length
             (Exchange_core_engine.Exchange.open_orders
                sim.exchange
                (Exchange_core.Account.of_string "client"))
           : int)
        ~inputs:(Queue.length sim.inputs : int)
        ~replay_matches:(replay_matches sim ~accounts:[ "client" ] : bool)];
  [%expect
    {|
    {
      "reference": "binance:BTCUSDT",
      "sim_symbol": "BTCUSDT",
      "source": "raw",
      "state": "fresh",
      "stale_reason": null,
      "went_stale": 1,
      "gaps": 0,
      "events": 406,
      "ignored": 0,
      "marks_set": 13,
      "funding_rates_set": 1,
      "reference_price": "82624.1",
      "shadow_levels_resting": 10,
      "shadow": { "placed": 388, "cancelled": 378, "skipped": 0, "consumed": 0 },
      "replay_fills": 2,
      "replays_rejected": 0,
      "source_finished": true
    }
    ((symbol BTCUSDT) (time 1700000014104000000)
     (bids
      (((px 82624.8) (sz 0.1) (n 1)) ((px 82624.7) (sz 0.001) (n 1))
       ((px 82624.6) (sz 0.002) (n 1))))
     (asks
      (((px 82624.9) (sz 20.52) (n 1)) ((px 82625) (sz 0.367) (n 1))
       ((px 82625.1) (sz 0.001) (n 1)))))
    ((client_open_orders 0) (inputs 997) (replay_matches true))
    |}];
  return ()
;;

let with_temp_dir f =
  let%bind dir = Unix.mkdtemp (Filename.temp_dir_name ^/ "binance-sim-anchor") in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () -> Unix.system_exn (sprintf "rm -rf %s" (Filename.quote dir)))
;;

let%expect_test "event logs rebuilt from the same minute give the same run" =
  Log.Global.set_output [];
  let run source =
    let sim = create_sim () in
    place sim ~key:"client" ~side:"SELL" ~tif:"GTX" ~price:"82615" ~qty:"0.01";
    let%bind anchored =
      Anchored.start sim.server { Anchored.Config.default with source; speed = 0. } spec
      >>| Or_error.ok_exn
    in
    let%map () = Anchored.finished anchored in
    let stats = Price_anchor.Anchor.stats (Anchored.anchor anchored) in
    ( [%sexp
        (stats.marks_set : int)
        , (stats.replays : int)
        , (Exchange_core_engine.Exchange.l2 sim.exchange spec.sim_symbol
           : Exchange_core.L2.t option)]
    , replay_matches sim ~accounts:[ "client" ] )
  in
  let%map () =
    with_temp_dir (fun dir ->
      let%bind stats =
        Market_data.Rebuild_norm.run
          ~normalizers:[ (module Binance_client.Raw_normalizer) ]
          ~data_dir:"fixtures"
          ~out_dir:(dir ^/ "norm")
          (Date.of_string "2026-10-12")
      in
      ignore (Or_error.ok_exn stats : Market_data.Rebuild_norm.Stats.t);
      let%bind from_raw, raw_replays = run raw in
      let%map from_norm, norm_replays =
        run
          (Norm
             { dir = dir ^/ "norm"
             ; from = Time_ns.of_string_with_utc_offset "2026-10-12T00:00:00Z"
             ; to_ = Time_ns.of_string_with_utc_offset "2026-10-13T00:00:00Z"
             })
      in
      print_s
        [%message
          ""
            ~same_run:(Sexp.equal from_raw from_norm : bool)
            (raw_replays : bool)
            (norm_replays : bool)])
  in
  [%expect {| ((same_run true) (raw_replays true) (norm_replays true)) |}]
;;

(* The same minute with a 2 bps collar on the mark and a tight halt rule: the anchored
   mark moves 0.01% and halts the market for 5 s, the client's order far through the book
   meets the collar, and the journal replays the guard log. *)
let%expect_test "an anchored run with a collar and halts replays its guard log" =
  Log.Global.set_output [];
  let module Exchange = Exchange_core_engine.Exchange in
  let module Guard_event = Exchange_core_engine.Guard_event in
  let sim = create_sim () in
  let guard =
    Binance_sim.Guard.Config.create
      ~collar_bps:2
      ~halt_levels:
        (Or_error.ok_exn (Binance_sim.Guard.parse_levels "0.01:5s,0.03:reopen"))
      ~anchored:true
      ()
    |> Or_error.ok_exn
  in
  Binance_sim.Guard.apply guard sim.exchange |> Or_error.ok_exn;
  place sim ~key:"client" ~side:"SELL" ~tif:"GTX" ~price:"82615" ~qty:"0.01";
  let%bind anchored =
    Anchored.start
      sim.server
      { Anchored.Config.default with source = raw; speed = 0. }
      spec
    >>| Or_error.ok_exn
  in
  let%bind () = Anchored.finished anchored in
  (* Far through the book: the collar (reference: the anchored mark) refuses it. *)
  let rejection =
    match
      Binance_sim.Server.mutate sim.server ~f:(fun a ->
        Binance_sim.Adapt.new_order
          a
          (Exchange_core.Account.of_string "client")
          (Binance_sim.Params.new_order
             [ "symbol", "BTCUSDT"
             ; "side", "BUY"
             ; "type", "LIMIT"
             ; "timeInForce", "GTC"
             ; "price", "83500"
             ; "quantity", "0.01"
             ]
           |> Result.map_error ~f:Binance_protocol.Api_error.sexp_of_t
           |> Result.map_error ~f:Sexp.to_string
           |> Result.ok_or_failwith))
    with
    | Ok _ -> "accepted"
    | Error e -> Yojson.Safe.to_string (Binance_protocol.Api_error.yojson_of_t e)
  in
  print_endline rejection;
  let live = Binance_sim.Server.guard_events sim.server in
  let replayed =
    Exchange_core_engine.Journal.replay
      ~config:(Binance_sim.Adapt.config ())
      (Queue.to_list sim.inputs)
  in
  let replayed_events = Exchange.drain_guard_events replayed in
  print_s
    [%message
      ""
        ~stats:(Exchange.guard_stats sim.exchange : Guard_event.Stats.t)
        ~same_stats:
          ([%equal: Guard_event.Stats.t]
             (Exchange.guard_stats sim.exchange)
             (Exchange.guard_stats replayed)
           : bool)
        ~same_recent_events:
          ([%equal: Guard_event.t list]
             live
             (List.drop replayed_events (List.length replayed_events - List.length live))
           : bool)
        ~replay_matches:(replay_matches sim ~accounts:[ "client" ] : bool)];
  [%expect
    {|
    {"code":-4016,"msg":"Limit price can't be higher than 82640.6."}
    ((stats
      ((collar_rejected 1) (collar_repriced 0) (collar_unreferenced 0)
       (halt_rejected 0) (halts 3) (reopens 3)))
     (same_stats true) (same_recent_events true) (replay_matches true))
    |}];
  return ()
;;
