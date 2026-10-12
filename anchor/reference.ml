open! Core
open! Async

module Kind = struct
  type t =
    | Live
    | Raw of
        { dir : string
        ; from : Time_ns.t
        ; to_ : Time_ns.t
        }
    | Norm of
        { dir : string
        ; from : Time_ns.t
        ; to_ : Time_ns.t
        }
  [@@deriving sexp_of]

  let name = function
    | Live -> "live"
    | Raw _ -> "raw"
    | Norm _ -> "norm"
  ;;
end

let utc = Time_float.Zone.utc

let parse_time which s =
  match Date.of_string s with
  | date ->
    let date =
      match which with
      | `Start -> date
      | `End -> Date.add_days date 1
    in
    Ok (Time_ns.of_date_ofday ~zone:utc date Time_ns.Ofday.start_of_day)
  | exception _ ->
    Or_error.try_with (fun () -> Time_ns_unix.of_string_with_utc_offset s)
    |> Or_error.tag_s ~tag:[%message "expected an ISO 8601 time with a zone or a date" s]
;;

let unsupported venue what =
  Or_error.error_s
    [%message
      "reference venue not supported by binance-sim"
        (venue : Market_data.Venue.t)
        (what : string)]
;;

let normalizer : Market_data.Venue.t -> Market_data.Normalizer.t Or_error.t = function
  | Binance -> Ok (module Binance_client.Raw_normalizer)
  | venue -> unsupported venue "raw"
;;

type t =
  { source : Price_anchor.Source.t
  ; close : unit -> unit Deferred.t
  }

let of_source source =
  { source
  ; close =
      (fun () ->
        Pipe.close_read source;
        return ())
  }
;;

let symbol (instrument : Market_data.Instrument.t) =
  Market_data.Symbol.to_string instrument.symbol
;;

let live ?(live_config = Binance_client.Config.Read_only.mainnet ()) instrument =
  match (instrument : Market_data.Instrument.t).venue with
  | Binance ->
    Monitor.try_with_or_error ~extract_exn:true (fun () ->
      Binance_client.Live_feed.create
        live_config
        ~symbols:[ symbol instrument ]
        ~streams:[ Trades; L2; Funding ])
    |> Deferred.Or_error.map ~f:(fun feed ->
      let (module F : Market_data.Feed.S) = feed in
      let source = Price_anchor.Source.of_feed feed in
      { source
      ; close =
          (fun () ->
            Pipe.close_read source;
            F.close ())
      })
  | venue -> return (unsupported venue "live")
;;

let open_ ?live_config (kind : Kind.t) instrument =
  match kind with
  | Live -> live ?live_config instrument
  | Raw { dir; from; to_ } ->
    (match normalizer instrument.venue with
     | Error _ as e -> return e
     | Ok normalizer ->
       return
         (Ok
            (of_source
               (Price_anchor.Source.of_raw
                  ~dir
                  ~symbol:(symbol instrument)
                  ~from
                  ~to_
                  ~normalizer
                  ()))))
  | Norm { dir; from; to_ } ->
    let day t = Time_ns.to_date t ~zone:utc in
    Price_anchor.Source.of_norm
      ~dir
      instrument
      ~from:(day from)
      ~to_:(day (Time_ns.sub to_ (Time_ns.Span.of_int_ns 1)))
    |> Deferred.Or_error.map ~f:of_source
;;
