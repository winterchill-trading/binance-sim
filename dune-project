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
  async_websocket
  uri
  yojson
  fixed-decimal
  exchange-core
  exchange-core-engine
  binance-protocol
  order-book
  ppx_jane))
