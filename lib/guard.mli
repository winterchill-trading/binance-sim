(** The engine's price collar ({!Exchange_core_engine.Price_collar}) and halt rule
    ({!Exchange_core_engine.Halt_rule}) as simulator settings: the [-collar-*] and
    [-halt-*] flags, how they are applied to an exchange, and the status served on
    [GET /sim/guard].

    Both are off by default: without the flags the exchange behaves as before. *)

open! Core
open! Binance_protocol
module Exchange := Exchange_core_engine.Exchange
module Price_collar := Exchange_core_engine.Price_collar
module Halt_rule := Exchange_core_engine.Halt_rule
module Guard_event := Exchange_core_engine.Guard_event

module Config : sig
  type t =
    { collar : Price_collar.Config.t option (** applied to every symbol *)
    ; halt_rule : Halt_rule.Config.t option
    }
  [@@deriving sexp_of]

  (** No collar, no halt rule. *)
  val off : t

  (** The settings of the flags. A band of [collar_bps] or [collar_ticks] (not both) turns
      the collar on; its reference defaults to the mark when [anchored], else to the last
      trade, and its action to [Reject]. [halt_levels] turns the halt rule on: market-wide
      unless [halt_scope] says otherwise, every symbol watched, moves of the mark,
      automatic reopening (a level without a duration waits for {!Exchange.reopen}). A
      reference or action without a band, or a scope without levels, is an error. *)
  val create
    :  ?collar_bps:int
    -> ?collar_ticks:int
    -> ?collar_reference:Price_collar.Reference.t
    -> ?collar_action:Price_collar.Action.t
    -> ?halt_levels:Halt_rule.Level.t list
    -> ?halt_scope:Halt_rule.Scope.t
    -> anchored:bool
    -> unit
    -> t Or_error.t

  (** [-collar-bps N], [-collar-ticks N], [-collar-reference last|mid|mark],
      [-collar-action reject|reprice], [-halt-levels SPEC] (see {!parse_levels}) and
      [-halt-scope market|symbol]; the result takes [anchored] (see {!create}). *)
  val param : (anchored:bool -> t Or_error.t) Command.Param.t
end

(** Halt levels written as [PERCENT:DURATION,...], e.g. ["7:15m,13:15m,20:reopen"]: a move
    of [PERCENT] (decimals allowed) from the session reference halts trading for
    [DURATION] (a {!Time_ns.Span} such as [15m] or [90s]), or until reopened for [reopen]. *)
val parse_levels : string -> Halt_rule.Level.t list Or_error.t

(** Sets the collar on every instrument and the halt rule, through the exchange's recorded
    calls (an input journal attached before records them). Does nothing for {!Config.off}. *)
val apply : Config.t -> Exchange.t -> unit Or_error.t

(** The engine's rejection text for an order refused during a halt
    ([Unsupported "trading halted"]). *)
val halted_reason : string

(** One guard event as JSON: [time] (ms), [symbol], [account], [orderId], [kind] and the
    kind's fields. *)
val event_to_yojson : Guard_event.t -> Yojson.Safe.t

(** [{"collar": {SYMBOL: {...}}, "haltRule": ..., "halted": {SYMBOL: {...}}, "stats": {...}, "recent": [...]}]:
    each symbol's collar with its current reference and bounds, the halt rule and session
    references, the halted symbols, the guard counters and [recent] guard events, oldest
    first. *)
val status : ?recent:Guard_event.t list -> Exchange.t -> Yojson.Safe.t
