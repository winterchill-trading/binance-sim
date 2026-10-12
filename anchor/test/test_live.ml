(* A simulator anchored live to another binance-sim (the reference, on a free local port)
   through binance-client's Live_feed: the reference book rests in the anchored book, a
   reference trade fills a client order it trades through, and the journal replays the
   run. *)

open! Core
open! Async
open Binance_sim_anchor
open Helpers

let wall_ns () = Time_ns.to_int_ns_since_epoch (Time_ns.now ())

(* Polls [f] until it holds, for at most 10 seconds. *)
let wait_until what f =
  let deadline = Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec 10.) in
  let rec loop () =
    if f ()
    then return ()
    else if Time_ns.( > ) (Time_ns.now ()) deadline
    then raise_s [%message "timed out" (what : string)]
    else (
      let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 20) in
      loop ())
  in
  loop ()
;;

let best_bid sim =
  Exchange_core_engine.Exchange.l2 sim.exchange (Exchange_core.Symbol.of_string "BTCUSDT")
  |> Option.bind ~f:(fun (l2 : Exchange_core.L2.t) -> List.hd l2.bids)
  |> Option.map ~f:(fun (level : Exchange_core.L2.Level.t) -> level.px)
;;

let%expect_test "live anchor to a local reference simulator" =
  Log.Global.set_output [];
  let reference = create_sim ~now:wall_ns () in
  let%bind http = Binance_sim.Server.listen reference.server ~port:0 in
  place reference ~key:"maker" ~side:"BUY" ~tif:"GTC" ~price:"50000" ~qty:"1";
  place reference ~key:"maker" ~side:"SELL" ~tif:"GTC" ~price:"50010" ~qty:"2";
  let sim = create_sim () in
  place sim ~key:"client" ~side:"SELL" ~tif:"GTX" ~price:"50005" ~qty:"0.01";
  let%bind anchored =
    Anchored.start
      ~live_config:
        (Binance_client.Config.Read_only.local ~port:(Binance_sim.Server.port http) ())
      sim.server
      Anchored.Config.default
      (Or_error.ok_exn (Spec.of_string "binance:BTCUSDT=BTCUSDT"))
    >>| Or_error.ok_exn
  in
  let anchor = Anchored.anchor anchored in
  let%bind () =
    wait_until "fresh" (fun () -> not (Price_anchor.Anchor.is_stale anchor))
  in
  print_book sim;
  [%expect
    {|
    ((symbol BTCUSDT) (time 1700000000000000000)
     (bids (((px 50000) (sz 1) (n 1))))
     (asks (((px 50005) (sz 0.01) (n 1)) ((px 50010) (sz 2) (n 1)))))
    |}];
  (* A reference buyer lifts the 50010 offer: the client's 50005 offer is through it. *)
  place reference ~key:"taker" ~side:"BUY" ~tif:"IOC" ~price:"50010" ~qty:"0.5";
  let%bind () =
    wait_until "replay fill" (fun () -> (Price_anchor.Anchor.stats anchor).replays > 0)
  in
  let%bind () = Anchored.stop anchored in
  (* Only the counters that do not depend on how frames interleave on the sockets. *)
  let status = Anchored.status anchored in
  let field name = Yojson.Safe.Util.member name status in
  print_s
    [%message
      ""
        ~state:(Yojson.Safe.Util.to_string (field "state") : string)
        ~source:(Yojson.Safe.Util.to_string (field "source") : string)
        ~replay_fills:(Yojson.Safe.to_string (field "replay_fills") : string)
        ~source_finished:(Yojson.Safe.to_string (field "source_finished") : string)
        ~client_open_orders:
          (List.length
             (Exchange_core_engine.Exchange.open_orders
                sim.exchange
                (Exchange_core.Account.of_string "client"))
           : int)
        ~best_bid:(best_bid sim : Exchange_core.Price.t option)
        ~replay_matches:(replay_matches sim ~accounts:[ "client" ] : bool)];
  [%expect
    {|
    ((state fresh) (source live) (replay_fills 1) (source_finished true)
     (client_open_orders 0) (best_bid (50000)) (replay_matches true))
    |}];
  Cohttp_async.Server.close http
;;
