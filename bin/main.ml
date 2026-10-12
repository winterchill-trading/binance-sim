open! Core
open! Async
open! Binance_protocol
open! Binance_sim
module Market_sim = Exchange_core_engine.Market_sim

let command =
  Command.async
    ~summary:"Binance USD-M Futures exchange simulator"
    ~readme:(fun () ->
      "Serves the /fapi REST API and the market and user data websocket streams (/ws, \
       /stream) on one port. The X-MBX-APIKEY header names the account; signatures are \
       not checked, but signed endpoints need a timestamp parameter. Every API key is \
       credited -initial-balance USDT on first use.")
    (let%map_open.Command port =
       flag "-port" (optional_with_default 3300 int) ~doc:"PORT HTTP and websocket port"
     and seed =
       flag "-seed" (optional_with_default 0 int) ~doc:"N market simulation random seed"
     and vol_bps =
       flag
         "-vol-bps"
         (optional_with_default Market_sim.Config.default.vol_bps float)
         ~doc:"BPS reference price volatility per second, in basis points"
     and symbols =
       flag
         "-symbols"
         (optional (Arg_type.comma_separated string))
         ~doc:"SYMBOL,... symbols the noise traders trade (default: all)"
     and noise_traders =
       flag
         "-noise-traders"
         (optional_with_default Market_sim.Config.default.noise_traders int)
         ~doc:"N number of noise trader accounts (0 disables the market simulation)"
     and initial_balance =
       flag
         "-initial-balance"
         (optional_with_default
            (Usd.to_string Server.Config.default.initial_balance)
            string)
         ~doc:"USDT balance credited to any API key on first use"
     and anchors =
       flag
         "-anchor"
         (listed Binance_sim_anchor.Spec.arg_type)
         ~doc:
           "VENUE:SYMBOL=SIM_SYMBOL follow a reference market, e.g. \
            binance:BTCUSDT=BTCUSDT (repeatable; live unless -anchor-raw or \
            -anchor-norm)"
     and anchor_config = Binance_sim_anchor.Anchored.Config.param
     and log_level =
       flag
         "-log-level"
         (optional_with_default `Info Log.Level.arg)
         ~doc:"LEVEL debug, info, warn or error (default info)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       Log.Global.set_level log_level;
       let adapt = Adapt.create () in
       let server =
         Server.create
           ~now:(Binance_sim_anchor.Anchored.Config.server_clock anchor_config)
           ~config:
             { Server.Config.default with
               initial_balance = Usd.of_string initial_balance
             }
           adapt
       in
       let%bind http = Server.listen server ~port in
       Log.Global.info
         "binance-sim listening on port %d (/fapi REST, /ws and /stream websockets)"
         (Server.port http);
       Server.start_periodic server;
       let market_sim =
         if noise_traders <= 0
         then None
         else (
           let sim =
             Market_sim.create
               { Market_sim.Config.default with
                 seed
               ; vol_bps
               ; noise_traders
               ; symbols = List.map (Option.value symbols ~default:[]) ~f:Symbol.of_string
               }
               (Adapt.exchange adapt)
           in
           Some sim)
       in
       let%bind anchors =
         Deferred.List.map anchors ~how:`Sequential ~f:(fun spec ->
           Binance_sim_anchor.Anchored.start ?market_sim server anchor_config spec
           >>| Or_error.ok_exn)
       in
       (* After the anchors, so anchored symbols never see a noise trader tick. *)
       Option.iter market_sim ~f:(Server.run_market_sim server);
       Binance_sim_anchor.Anchored.serve_status server anchors;
       Binance_sim_anchor.Anchored.log_status_every (Time_ns.Span.of_sec 30.) anchors;
       Cohttp_async.Server.close_finished http)
;;

let () = Command_unix.run command
