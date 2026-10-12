open! Core
open! Binance_protocol

type t = (string * string) list [@@deriving sexp_of]

let of_request ~query ~body =
  let query =
    List.filter_map query ~f:(fun (k, vs) -> List.hd vs |> Option.map ~f:(fun v -> k, v))
  in
  let body =
    if String.is_empty (String.strip body)
    then []
    else
      Uri.query_of_encoded body
      |> List.filter_map ~f:(fun (k, vs) ->
        if List.Assoc.mem query ~equal:String.equal k
        then None
        else List.hd vs |> Option.map ~f:(fun v -> k, v))
  in
  query @ body
;;

let of_json_object : Yojson.Safe.t -> t option = function
  | `Assoc fields ->
    Some
      (List.filter_map fields ~f:(fun (k, v) ->
         match v with
         | `String s -> Some (k, s)
         | `Int i -> Some (k, Int.to_string i)
         | `Intlit s -> Some (k, s)
         | `Float f -> Some (k, Float.to_string_hum ~strip_zero:true f)
         | `Bool b -> Some (k, Bool.to_string b)
         | `Null | `List _ | `Assoc _ | `Tuple _ | `Variant _ -> None))
  | _ -> None
;;

let find t key =
  List.Assoc.find t ~equal:String.equal key
  |> Option.bind ~f:(fun v -> if String.is_empty v then None else Some v)
;;

let mandatory name =
  { Api_error.code = Mandatory_param_empty_or_malformed
  ; msg =
      sprintf "Mandatory parameter '%s' was not sent, was empty/null, or malformed." name
  }
;;

let invalid name =
  { Api_error.code = Invalid_parameter
  ; msg = sprintf "Data sent for parameter '%s' is not valid." name
  }
;;

let required t key = Result.of_option (find t key) ~error:(mandatory key)

let parse_opt t key ~f ~error =
  match find t key with
  | None -> Ok None
  | Some v ->
    (match f v with
     | Some x -> Ok (Some x)
     | None -> Error error)
;;

let symbol t = required t "symbol" |> Result.map ~f:Symbol.of_string
let symbol_opt t = find t "symbol" |> Option.map ~f:Symbol.of_string
let int_opt t key = parse_opt t key ~f:Int.of_string_opt ~error:(invalid key)

let new_order t =
  let open Result.Let_syntax in
  let%bind symbol = symbol t in
  let%bind side =
    let%bind side = required t "side" in
    Result.of_option
      (Side.of_wire side)
      ~error:{ Api_error.code = Invalid_side; msg = "Invalid side." }
  in
  let%bind order_type = required t "type" |> Result.map ~f:Order_type.of_wire in
  let%bind time_in_force =
    parse_opt
      t
      "timeInForce"
      ~f:Time_in_force.of_wire
      ~error:{ Api_error.code = Invalid_tif; msg = "Invalid timeInForce." }
  in
  let%bind position_side =
    parse_opt t "positionSide" ~f:Position_side.of_wire ~error:(invalid "positionSide")
  in
  let%bind quantity =
    parse_opt t "quantity" ~f:Size.of_string_opt ~error:(mandatory "quantity")
  in
  let%bind price =
    parse_opt t "price" ~f:Price.of_string_opt ~error:(mandatory "price")
  in
  let%bind reduce_only =
    parse_opt
      t
      "reduceOnly"
      ~f:(function
        | "true" | "TRUE" -> Some true
        | "false" | "FALSE" -> Some false
        | _ -> None)
      ~error:(invalid "reduceOnly")
  in
  let%bind new_client_order_id =
    parse_opt
      t
      "newClientOrderId"
      ~f:(fun s -> Client_order_id.validate s |> Result.ok)
      ~error:{ Api_error.code = Other (-4015); msg = "Client order id is not valid." }
  in
  let%bind new_order_resp_type =
    parse_opt
      t
      "newOrderRespType"
      ~f:(function
        | "ACK" -> Some New_order.Resp_type.Ack
        | "RESULT" -> Some Result
        | _ -> None)
      ~error:(invalid "newOrderRespType")
  in
  let%map good_till_date = int_opt t "goodTillDate" in
  { New_order.Request.symbol
  ; side
  ; position_side
  ; order_type
  ; time_in_force
  ; quantity
  ; price
  ; reduce_only
  ; new_client_order_id
  ; new_order_resp_type
  ; good_till_date
  }
;;

let batch_orders t =
  let open Result.Let_syntax in
  let%bind raw = required t "batchOrders" in
  let%bind items =
    match Yojson.Safe.from_string raw with
    | `List items -> Ok items
    | _ | (exception Yojson.Json_error _) -> Error (invalid "batchOrders")
  in
  let%bind () =
    if List.is_empty items || List.length items > Batch_orders.Request.max_orders
    then Error (invalid "batchOrders")
    else Ok ()
  in
  List.map items ~f:of_json_object
  |> Option.all
  |> Result.of_option ~error:(invalid "batchOrders")
;;

let cancel_order t =
  let open Result.Let_syntax in
  let%bind symbol = symbol t in
  let%bind order_id =
    parse_opt t "orderId" ~f:Int.of_string_opt ~error:(invalid "orderId")
  in
  let%map target =
    match order_id, find t "origClientOrderId" with
    | Some id, _ -> Ok (Cancel_order.Request.Target.Order_id (Order_id.of_int id))
    | None, Some cid -> Ok (Client_order_id (Client_order_id.of_string cid))
    | None, None ->
      Error
        { Api_error.code = Mandatory_param_empty_or_malformed
        ; msg = "Either orderId or origClientOrderId must be sent."
        }
  in
  { Cancel_order.Request.symbol; target }
;;
