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
