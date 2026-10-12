(lang dune 3.17)

(name binance-sim)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/binance-sim))

(package
 (name binance-sim)
 (synopsis "Binance USD-M Futures exchange simulator")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  cohttp-async
  http
  async_websocket
  uri
  yojson
  fixed-decimal
  exchange-core
  exchange-core-engine
  binance-protocol
  order-book
  ppx_jane))

(package
 (name binance-sim-anchor)
 (synopsis "The binance-sim binary, with its market anchored to a reference venue")
 (description
  "The binance-sim executable and the -anchor flags: live (binance-client's Live_feed), raw minute file and event log reference sources through price-anchor. A separate package because binance-client's tests depend on binance-sim.")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  yojson
  exchange-core
  exchange-core-engine
  market-data
  price-anchor
  binance-client
  (binance-sim
   (= :version))
  ppx_jane))
