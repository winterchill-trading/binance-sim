(** Request parameters, as Binance reads them: from the query string and, for [POST],
    [PUT] and [DELETE], also from an [application/x-www-form-urlencoded] body. When a key
    appears in both, the query string wins. Parsers return Binance's error for missing or
    malformed values. *)

open! Core
open! Binance_protocol

type t = (string * string) list [@@deriving sexp_of]

(** [body] is ignored when empty. *)
val of_request : query:(string * string list) list -> body:string -> t

(** The object's fields with every value as a string, as in a [batchOrders] item. *)
val of_json_object : Yojson.Safe.t -> t option

val find : t -> string -> string option

(** [-1102 Mandatory parameter '<name>' was not sent, was empty/null, or malformed.] *)
val mandatory : string -> Api_error.t

(** [-1130 Data sent for parameter '<name>' is not valid.] *)
val invalid : string -> Api_error.t

val symbol : t -> (Symbol.t, Api_error.t) Result.t
val symbol_opt : t -> Symbol.t option
val int_opt : t -> string -> (int option, Api_error.t) Result.t

(** [POST /fapi/v1/order]: [symbol], [side] ([-1117] if invalid), [type], [timeInForce]
    ([-1115]), [quantity], [price], [positionSide], [reduceOnly], [newClientOrderId]
    ([-4015] unless it matches Binance's format), [newOrderRespType], [goodTillDate]. *)
val new_order : t -> (New_order.Request.t, Api_error.t) Result.t

(** The items of [batchOrders] (a JSON array of objects), at most
    {!Binance_protocol.Batch_orders.Request.max_orders}. *)
val batch_orders : t -> (t list, Api_error.t) Result.t

(** [DELETE /fapi/v1/order]: [symbol] and [orderId] or [origClientOrderId]. *)
val cancel_order : t -> (Cancel_order.Request.t, Api_error.t) Result.t
