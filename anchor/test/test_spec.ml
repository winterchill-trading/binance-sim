open! Core
open Binance_sim_anchor

let%expect_test "-anchor values" =
  List.iter
    [ "binance:BTCUSDT=BTCUSDT"
    ; "Bybit:ETHUSDT=ETHUSDT"
    ; "hyperliquid:BTC=BTCUSDT"
    ; "BTCUSDT"
    ; "binance:BTCUSDT"
    ; "nowhere:BTC=BTCUSDT"
    ; "binance:=BTCUSDT"
    ]
    ~f:(fun s ->
      match Spec.of_string s with
      | Ok spec -> print_s [%message s ~_:(Spec.to_string spec : string)]
      | Error e -> print_s [%message s ~_:(e : Error.t)]);
  [%expect
    {|
    (binance:BTCUSDT=BTCUSDT binance:BTCUSDT=BTCUSDT)
    (Bybit:ETHUSDT=ETHUSDT bybit:ETHUSDT=ETHUSDT)
    (hyperliquid:BTC=BTCUSDT hyperliquid:BTC=BTCUSDT)
    (BTCUSDT ("expected <venue>:<symbol>=<sim-symbol>" (anchor BTCUSDT)))
    (binance:BTCUSDT
     ("expected <venue>:<symbol>=<sim-symbol>" (anchor binance:BTCUSDT)))
    (nowhere:BTC=BTCUSDT ("unknown venue" (anchor nowhere:BTC=BTCUSDT)))
    (binance:=BTCUSDT ("empty symbol" (anchor binance:=BTCUSDT)))
    |}]
;;

let%expect_test "-anchor-from and -anchor-to values" =
  List.iter
    [ `Start, "2026-10-12"
    ; `End, "2026-10-12"
    ; `Start, "2026-10-12T15:05:00Z"
    ; `End, "2026-10-12T17:05:30.5+02:00"
    ; `Start, "yesterday"
    ]
    ~f:(fun (which, s) ->
      match Reference.parse_time which s with
      | Ok t ->
        print_endline (Time_ns.to_string_iso8601_basic t ~zone:Time_float.Zone.utc)
      | Error _ -> print_endline "error");
  [%expect
    {|
    2026-10-12T00:00:00.000000000Z
    2026-10-13T00:00:00.000000000Z
    2026-10-12T15:05:00.000000000Z
    2026-10-12T15:05:30.500000000Z
    error
    |}]
;;

let%expect_test "the server clock follows the replay speed" =
  let wall () = Time_ns.to_int_ns_since_epoch (Time_ns.now ()) in
  let raw : Reference.Kind.t =
    Raw { dir = "."; from = Time_ns.epoch; to_ = Time_ns.max_value_representable }
  in
  let advance (config : Anchored.Config.t) =
    let clock = Anchored.Config.server_clock config in
    let t0 = clock () in
    let w0 = wall () in
    while wall () - w0 < 50_000_000 do
      ()
    done;
    Float.of_int (clock () - t0) /. Float.of_int (wall () - w0)
  in
  let print what ratio =
    printf "%s: %.1f\n" what (Float.round_decimal ratio ~decimal_digits:1)
  in
  print "live" (advance Anchored.Config.default);
  print "recorded, speed 1" (advance { Anchored.Config.default with source = raw });
  print
    "recorded, speed 0.5"
    (advance { Anchored.Config.default with source = raw; speed = 0.5 });
  print
    "recorded, speed 0"
    (advance { Anchored.Config.default with source = raw; speed = 0. });
  [%expect
    {|
    live: 1.0
    recorded, speed 1: 1.0
    recorded, speed 0.5: 0.5
    recorded, speed 0: 0.0
    |}]
;;
