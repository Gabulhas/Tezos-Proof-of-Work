(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Alpha_context
open Script
open Script_typed_ir
open Script_tc_errors
open Script_ir_translator

let dummy_code_fee = Tez.fifty_cents
let dummy_storage_fee = Tez.fifty_cents

(* ---- Run-time errors -----------------------------------------------------*)

type error += Reject of Script.location
type error += Overflow of Script.location
type error += Runtime_contract_error : Contract.t * Script.expr -> error

let () =
  let open Data_encoding in
  (* Reject *)
  register_error_kind
    `Temporary
    ~id:"scriptRejectedRuntimeError"
    ~title: "Script failed (runtime script error)"
    ~description: "A FAIL instruction was reached"
    (obj1 (req "location" Script.location_encoding))
    (function Reject loc -> Some loc | _ -> None)
    (fun loc -> Reject loc);
  (* Overflow *)
  register_error_kind
    `Temporary
    ~id:"scriptOverflowRuntimeError"
    ~title: "Script failed (overflow error)"
    ~description: "A FAIL instruction was reached due to the detection of an overflow"
    (obj1 (req "location" Script.location_encoding))
    (function Overflow loc -> Some loc | _ -> None)
    (fun loc -> Overflow loc);
  (* Runtime contract error *)
  register_error_kind
    `Temporary
    ~id:"scriptRuntimeError"
    ~title: "Script runtime error"
    ~description: "Toplevel error for all runtime script errors"
    (obj2
       (req "contractHandle" Contract.encoding)
       (req "contractCode" Script.expr_encoding))
    (function
      | Runtime_contract_error (contract, expr) ->
          Some (contract, expr)
      | _ -> None)
    (fun (contract, expr) ->
       Runtime_contract_error (contract, expr))

(* ---- interpreter ---------------------------------------------------------*)

type 'tys stack =
  | Item : 'ty * 'rest stack -> ('ty * 'rest) stack
  | Empty : end_of_stack stack

let rec unparse_stack
  : type a. a stack * a stack_ty -> Script.expr list
  = function
    | Empty, Empty_t -> []
    | Item (v, rest), Item_t (ty, rest_ty, _) ->
        (* Meant to be more gas than you can consume as this function is only used for debugging/errors *)
        match unparse_data (Gas.of_int 1000000000) ty v with
        | Ok (data, _) -> (Micheline.strip_locations data) :: (unparse_stack (rest, rest_ty))
        | Error _ -> Pervasives.failwith "Internal error: raise gas limit for unparse_stack"

module Interp_costs = Michelson_v1_gas.Cost_of

let rec interp
  : type p r.
    ?log: (Script.location * Gas.t * Script.expr list) list ref ->
    Contract.origination_nonce -> Gas.t -> Contract.t -> Contract.t -> Tez.t ->
    context -> (p, r) lambda -> p ->
    (r * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t
  = fun ?log origination gas orig source amount ctxt (Lam (code, _)) arg ->
    let rec step
      : type b a.
        Contract.origination_nonce -> Gas.t -> context -> (b, a) descr -> b stack ->
        (a stack * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t =
      fun origination gas ctxt ({ instr ; loc ; _ } as descr) stack ->
        let gas = Gas.consume gas Interp_costs.cycle in
        Gas.check gas >>=? fun () ->
        let logged_return : type a b.
          (b, a) descr ->
          ?origination:Contract.origination_nonce ->
          a stack * Gas.t * context ->
          (a stack * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t =
          fun descr ?(origination = origination) (ret, gas, ctxt) ->
            match log with
            | None -> return (ret, gas, ctxt, origination)
            | Some log ->
                log := (descr.loc, gas, unparse_stack (ret, descr.aft)) :: !log ;
                return (ret, gas, ctxt, origination) in
        let gas_check_terop : type ret arg1 arg2 arg3 rest.
          ?gas:Gas.t ->
          ?origination:Contract.origination_nonce ->
          (_ * (_ * (_ * rest)), ret * rest) descr ->
          ((arg1 -> arg2 -> arg3 -> ret) * arg1 * arg2 * arg3) ->
          (arg1 -> arg2 -> arg3 -> Gas.cost) ->
          rest stack ->
          ((ret * rest) stack * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t =
          fun ?(gas=gas) ?(origination = origination) descr (op, x1, x2, x3) cost_func rest ->
            let gas = Gas.consume gas (cost_func x1 x2 x3) in
            Gas.check gas >>=? fun () ->
            logged_return descr ~origination (Item (op x1 x2 x3, rest), gas, ctxt) in
        let gas_check_binop : type ret arg1 arg2 rest.
          ?gas:Gas.t ->
          ?origination:Contract.origination_nonce ->
          (_ * (_ * rest), ret * rest) descr ->
          ((arg1 -> arg2 -> ret) * arg1 * arg2) ->
          (arg1 -> arg2 -> Gas.cost) ->
          rest stack ->
          context ->
          ((ret * rest) stack * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t =
          fun ?(gas=gas) ?(origination = origination) descr (op, x1, x2) cost_func rest ctxt ->
            let gas = Gas.consume gas (cost_func x1 x2) in
            Gas.check gas >>=? fun () ->
            logged_return descr ~origination (Item (op x1 x2, rest), gas, ctxt) in
        let gas_check_unop : type ret arg rest.
          ?gas:Gas.t ->
          ?origination:Contract.origination_nonce ->
          (_ * rest, ret * rest) descr ->
          ((arg -> ret) * arg) ->
          (arg -> Gas.cost) ->
          rest stack ->
          context ->
          ((ret * rest) stack * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t =
          fun ?(gas=gas) ?(origination = origination) descr (op, arg) cost_func rest ctxt ->
            let gas = Gas.consume gas (cost_func arg) in
            Gas.check gas >>=? fun () ->
            logged_return descr ~origination (Item (op arg, rest), gas, ctxt) in
        let gas_compare :
          type t rest.
          (t * (t * rest), Script_int.z Script_int.num * rest) descr ->
          (t -> t -> int) ->
          (t -> t -> Gas.cost) ->
          t -> t ->
          rest stack ->
          ((Script_int.z Script_int.num * rest) stack
           * Gas.t
           * context
           * Contract.origination_nonce) tzresult Lwt.t =
          fun descr op cost x1 x2 rest ->
            let gas = Gas.consume gas (cost x1 x2) in
            Gas.check gas >>=? fun () ->
            logged_return descr (Item (Script_int.of_int @@ op x1 x2, rest), gas, ctxt) in
        let create_contract :
          type param return rest storage.
          (_, (param, return) typed_contract * rest) descr ->
          manager:public_key_hash -> delegate:public_key_hash option -> spendable:bool ->
          delegatable:bool -> credit:Tez.t -> code:prim Micheline.canonical ->
          init:storage -> param_type:param ty -> storage_type:storage ty ->
          return_type:return ty ->
          rest:rest stack ->
          (((param, return) typed_contract * rest) stack * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t =
          fun descr ~manager ~delegate ~spendable ~delegatable
            ~credit ~code ~init ~param_type ~storage_type ~return_type ~rest ->
            let gas = Gas.consume gas Interp_costs.create_contract in
            Gas.check gas >>=? fun () ->
            let code =
              Micheline.strip_locations
                (Seq (0, [ Prim (0, K_parameter, [ unparse_ty None param_type ], None) ;
                           Prim (0, K_return, [ unparse_ty None return_type ], None) ;
                           Prim (0, K_storage, [ unparse_ty None storage_type ], None) ;
                           Prim (0, K_code, [ Micheline.root code ], None) ], None)) in
            Lwt.return @@ unparse_data gas storage_type init >>=? fun (storage, gas) ->
            let storage = Micheline.strip_locations storage in
            Contract.spend_from_script ctxt source credit >>=? fun ctxt ->
            Contract.originate ctxt
              origination
              ~manager ~delegate ~balance:credit
              ~script:({ code ; storage }, (dummy_code_fee, dummy_storage_fee))
              ~spendable ~delegatable
            >>=? fun (ctxt, contract, origination) ->
            Fees.origination_burn ctxt ~source:orig contract >>=? fun ctxt ->
            logged_return descr ~origination (Item ((param_type, return_type, contract), rest), gas, ctxt) in
        let logged_return : ?origination:Contract.origination_nonce ->
          a stack * Gas.t * context ->
          (a stack * Gas.t * context * Contract.origination_nonce) tzresult Lwt.t =
          logged_return descr in
        match instr, stack with
        (* stack ops *)
        | Drop, Item (_, rest) ->
            let gas = Gas.consume gas Interp_costs.stack_op in
            Gas.check gas >>=? fun () ->
            logged_return (rest, gas, ctxt)
        | Dup, Item (v, rest) ->
            let gas = Gas.consume gas Interp_costs.stack_op in
            Gas.check gas >>=? fun () ->
            logged_return (Item (v, Item (v, rest)), gas, ctxt)
        | Swap, Item (vi, Item (vo, rest)) ->
            let gas = Gas.consume gas Interp_costs.stack_op in
            Gas.check gas >>=? fun () ->
            logged_return (Item (vo, Item (vi, rest)), gas, ctxt)
        | Const v, rest ->
            let gas = Gas.consume gas Interp_costs.push in
            Gas.check gas >>=? fun () ->
            logged_return (Item (v, rest), gas, ctxt)
        (* options *)
        | Cons_some, Item (v, rest) ->
            let gas = Gas.consume gas Interp_costs.wrap in
            Gas.check gas >>=? fun () ->
            logged_return (Item (Some v, rest), gas, ctxt)
        | Cons_none _, rest ->
            let gas = Gas.consume gas Interp_costs.variant_no_data in
            Gas.check gas >>=? fun () ->
            logged_return (Item (None, rest), gas, ctxt)
        | If_none (bt, _), Item (None, rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bt rest
        | If_none (_, bf), Item (Some v, rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bf (Item (v, rest))
        (* pairs *)
        | Cons_pair, Item (a, Item (b, rest)) ->
            let gas = Gas.consume gas Interp_costs.pair in
            Gas.check gas >>=? fun () ->
            logged_return (Item ((a, b), rest), gas, ctxt)
        | Car, Item ((a, _), rest) ->
            let gas = Gas.consume gas Interp_costs.pair_access in
            Gas.check gas >>=? fun () ->
            logged_return (Item (a, rest), gas, ctxt)
        | Cdr, Item ((_, b), rest) ->
            let gas = Gas.consume gas Interp_costs.pair_access in
            Gas.check gas >>=? fun () ->
            logged_return (Item (b, rest), gas, ctxt)
        (* unions *)
        | Left, Item (v, rest) ->
            let gas = Gas.consume gas Interp_costs.wrap in
            Gas.check gas >>=? fun () ->
            logged_return (Item (L v, rest), gas, ctxt)
        | Right, Item (v, rest) ->
            let gas = Gas.consume gas Interp_costs.wrap in
            Gas.check gas >>=? fun () ->
            logged_return (Item (R v, rest), gas, ctxt)
        | If_left (bt, _), Item (L v, rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bt (Item (v, rest))
        | If_left (_, bf), Item (R v, rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bf (Item (v, rest))
        (* lists *)
        | Cons_list, Item (hd, Item (tl, rest)) ->
            let gas = Gas.consume gas Interp_costs.cons in
            Gas.check gas >>=? fun () ->
            logged_return (Item (hd :: tl, rest), gas, ctxt)
        | Nil, rest ->
            let gas = Gas.consume gas Interp_costs.variant_no_data in
            Gas.check gas >>=? fun () ->
            logged_return (Item ([], rest), gas, ctxt)
        | If_cons (_, bf), Item ([], rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bf rest
        | If_cons (bt, _), Item (hd :: tl, rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bt (Item (hd, Item (tl, rest)))
        | List_map, Item (lam, Item (l, rest)) ->
            Gas.fold_right ~cycle_cost:Interp_costs.cycle gas
              (fun gas arg (tail, ctxt, origination) ->
                 interp ?log origination gas orig source amount ctxt lam arg
                 >>=? fun (ret, gas, ctxt, origination) ->
                 return ((ret :: tail, ctxt, origination), gas))
              ([], ctxt, origination) l >>=? fun ((res, ctxt, origination), gas) ->
            logged_return ~origination (Item (res, rest), gas, ctxt)
        | List_map_body body, Item (l, rest) ->
            let rec help rest gas l =
              let gas = Gas.consume gas Interp_costs.loop_cycle in
              Gas.check gas >>=? fun () ->
              match l with
              | [] -> logged_return ~origination (Item ([], rest), gas, ctxt)
              | hd :: tl ->
                  step origination gas ctxt body (Item (hd, rest))
                  >>=? fun (Item (hd, rest), gas, _, _) ->
                  help rest gas tl
                  >>=? fun (Item (tl, rest), gas, ctxt, origination) ->
                  logged_return ~origination (Item (hd :: tl, rest), gas, ctxt)
            in help rest gas l >>=? fun (res, gas, ctxt, origination) ->
            logged_return ~origination (res, gas, ctxt)
        | List_reduce, Item (lam, Item (l, Item (init, rest))) ->
            Gas.fold_left ~cycle_cost:Interp_costs.cycle gas
              (fun gas arg (partial, ctxt, origination) ->
                 interp ?log origination gas orig source amount ctxt lam (arg, partial)
                 >>=? fun (partial, gas, ctxt, origination) ->
                 return ((partial, ctxt, origination), gas))
              (init, ctxt, origination) l >>=? fun ((res, ctxt, origination), gas) ->
            logged_return ~origination (Item (res, rest), gas, ctxt)
        | List_size, Item (list, rest) ->
            Gas.fold_left ~cycle_cost:Interp_costs.list_size gas
              (fun gas _ len ->
                 return (len + 1, gas))
              0
              list >>=? fun (len, gas) ->
            logged_return (Item (Script_int.(abs (of_int len)), rest), gas, ctxt)
        | List_iter body, Item (l, init_stack) ->
            Gas.fold_left ~cycle_cost:Interp_costs.list_size gas
              (fun gas arg (stack, ctxt, origination) ->
                 step origination gas ctxt body (Item (arg, stack))
                 >>=? fun (stack, gas, ctxt, origination) ->
                 return ((stack, ctxt, origination), gas))
              (init_stack, ctxt, origination) l >>=? fun ((stack, ctxt, origination), gas) ->
            logged_return ~origination (stack, gas, ctxt)
        (* sets *)
        | Empty_set t, rest ->
            logged_return (Item (empty_set t, rest), Gas.consume gas Interp_costs.empty_set, ctxt)
        | Set_reduce, Item (lam, Item (set, Item (init, rest))) ->
            let gas = Gas.consume gas (Interp_costs.set_to_list set) in
            Gas.check gas >>=? fun () ->
            let items =
              List.rev (set_fold (fun e acc -> e :: acc) set []) in
            Gas.fold_left ~cycle_cost:Interp_costs.list_size gas
              (fun gas arg (partial, ctxt, origination) ->
                 interp ?log origination gas orig source amount ctxt lam (arg, partial)
                 >>=? fun (partial, gas, ctxt, origination) ->
                 return ((partial, ctxt, origination), gas))
              (init, ctxt, origination) items >>=? fun ((res, ctxt, origination), gas) ->
            logged_return ~origination (Item (res, rest), gas, ctxt)
        | Set_iter body, Item (set, init_stack) ->
            Gas.fold_left ~cycle_cost:Interp_costs.list_size gas
              (fun gas arg (stack, ctxt, origination) ->
                 step origination gas ctxt body (Item (arg, stack))
                 >>=? fun (stack, gas, ctxt, origination) ->
                 return ((stack, ctxt, origination), gas))
              (init_stack, ctxt, origination)
              (set_fold (fun e acc -> e :: acc) set []) >>=? fun ((stack, ctxt, origination), gas) ->
            logged_return ~origination (stack, gas, ctxt)
        | Set_mem, Item (v, Item (set, rest)) ->
            gas_check_binop descr (set_mem, v, set) Interp_costs.set_mem rest ctxt
        | Set_update, Item (v, Item (presence, Item (set, rest))) ->
            gas_check_terop descr (set_update, v, presence, set) Interp_costs.set_update rest
        | Set_size, Item (set, rest) ->
            gas_check_unop descr (set_size, set) (fun _ -> Interp_costs.set_size) rest ctxt
        (* maps *)
        | Empty_map (t, _), rest ->
            logged_return (Item (empty_map t, rest), Gas.consume gas Interp_costs.empty_map, ctxt)
        | Map_map, Item (lam, Item (map, rest)) ->
            let gas = Gas.consume gas (Interp_costs.map_to_list map) in
            Gas.check gas >>=? fun () ->
            let items =
              List.rev (map_fold (fun k v acc -> (k, v) :: acc) map []) in
            Gas.fold_left ~cycle_cost:Interp_costs.list_size gas
              (fun gas (k, v) (acc, ctxt, origination) ->
                 interp ?log origination gas orig source amount ctxt lam (k, v)
                 >>=? fun (ret, gas, ctxt, origination) ->
                 return ((map_update k (Some ret) acc, ctxt, origination), gas))
              (empty_map (map_key_ty map), ctxt, origination) items >>=? fun ((res, ctxt, origination), gas) ->
            logged_return ~origination (Item (res, rest), gas, ctxt)
        | Map_reduce, Item (lam, Item (map, Item (init, rest))) ->
            let gas = Gas.consume gas (Interp_costs.map_to_list map) in
            Gas.check gas >>=? fun () ->
            let items =
              List.rev (map_fold (fun k v acc -> (k, v) :: acc) map []) in
            Gas.fold_left ~cycle_cost:Interp_costs.list_size gas
              (fun gas arg (partial, ctxt, origination) ->
                 interp ?log origination gas orig source amount ctxt lam (arg, partial)
                 >>=? fun (partial, gas, ctxt, origination) ->
                 return ((partial, ctxt, origination), gas))
              (init, ctxt, origination) items >>=? fun ((res, ctxt, origination), gas) ->
            logged_return ~origination (Item (res, rest), gas, ctxt)
        | Map_iter body, Item (map, init_stack) ->
            let gas = Gas.consume gas (Interp_costs.map_to_list map) in
            Gas.check gas >>=? fun () ->
            let items =
              List.rev (map_fold (fun k v acc -> (k, v) :: acc) map []) in
            Gas.fold_left ~cycle_cost:Interp_costs.list_size gas
              (fun gas arg (stack, ctxt, origination) ->
                 step origination gas ctxt body (Item (arg, stack))
                 >>=? fun (stack, gas, ctxt, origination) ->
                 return ((stack, ctxt, origination), gas))
              (init_stack, ctxt, origination) items >>=? fun ((stack, ctxt, origination), gas) ->
            logged_return ~origination (stack, gas, ctxt)
        | Map_mem, Item (v, Item (map, rest)) ->
            gas_check_binop descr (map_mem, v, map) Interp_costs.map_mem rest ctxt
        | Map_get, Item (v, Item (map, rest)) ->
            gas_check_binop descr (map_get, v, map) Interp_costs.map_get rest ctxt
        | Map_update, Item (k, Item (v, Item (map, rest))) ->
            gas_check_terop descr (map_update, k, v, map) Interp_costs.map_update rest
        | Map_size, Item (map, rest) ->
            gas_check_unop descr (map_size, map) (fun _ -> Interp_costs.map_size) rest ctxt
        (* Big map operations *)
        | Big_map_mem, Item (key, Item (map, rest)) ->
            let gas = Gas.consume gas (Interp_costs.big_map_mem key map) in
            Gas.check gas >>=? fun () ->
            Script_ir_translator.big_map_mem ctxt gas source key map >>=? fun (res, gas) ->
            logged_return (Item (res, rest), gas, ctxt)
        | Big_map_get, Item (key, Item (map, rest)) ->
            let gas = Gas.consume gas (Interp_costs.big_map_get key map) in
            Gas.check gas >>=? fun () ->
            Script_ir_translator.big_map_get ctxt gas source key map >>=? fun (res, gas) ->
            logged_return (Item (res, rest), gas, ctxt)
        | Big_map_update, Item (key, Item (maybe_value, Item (map, rest))) ->
            gas_check_terop descr
              (Script_ir_translator.big_map_update, key, maybe_value, map)
              Interp_costs.big_map_update rest
        (* timestamp operations *)
        | Add_seconds_to_timestamp, Item (n, Item (t, rest)) ->
            gas_check_binop descr
              (Script_timestamp.add_delta, t, n)
              Interp_costs.add_timestamp rest ctxt
        | Add_timestamp_to_seconds, Item (t, Item (n, rest)) ->
            gas_check_binop descr (Script_timestamp.add_delta, t, n)
              Interp_costs.add_timestamp rest ctxt
        | Sub_timestamp_seconds, Item (t, Item (s, rest)) ->
            gas_check_binop descr (Script_timestamp.sub_delta, t, s)
              Interp_costs.sub_timestamp rest ctxt
        | Diff_timestamps, Item (t1, Item (t2, rest)) ->
            gas_check_binop descr (Script_timestamp.diff, t1, t2)
              Interp_costs.diff_timestamps rest ctxt
        (* string operations *)
        | Concat, Item (x, Item (y, rest)) ->
            gas_check_binop descr ((^), x, y) Interp_costs.concat rest ctxt
        (* currency operations *)
        | Add_tez, Item (x, Item (y, rest)) ->
            let gas = Gas.consume gas Interp_costs.int64_op in
            Gas.check gas >>=? fun () ->
            Lwt.return Tez.(x +? y) >>=? fun res ->
            logged_return (Item (res, rest), gas, ctxt)
        | Sub_tez, Item (x, Item (y, rest)) ->
            let gas = Gas.consume gas Interp_costs.int64_op in
            Gas.check gas >>=? fun () ->
            Lwt.return Tez.(x -? y) >>=? fun res ->
            logged_return (Item (res, rest), gas, ctxt)
        | Mul_teznat, Item (x, Item (y, rest)) ->
            let gas = Gas.consume gas Interp_costs.int64_op in
            let gas = Gas.consume gas Interp_costs.z_to_int64 in
            Gas.check gas >>=? fun () ->
            begin
              match Script_int.to_int64 y with
              | None -> fail (Overflow loc)
              | Some y ->
                  Lwt.return Tez.(x *? y) >>=? fun res ->
                  logged_return (Item (res, rest), gas, ctxt)
            end
        | Mul_nattez, Item (y, Item (x, rest)) ->
            let gas = Gas.consume gas Interp_costs.int64_op in
            let gas = Gas.consume gas Interp_costs.z_to_int64 in
            Gas.check gas >>=? fun () ->
            begin
              match Script_int.to_int64 y with
              | None -> fail (Overflow loc)
              | Some y ->
                  Lwt.return Tez.(x *? y) >>=? fun res ->
                  logged_return (Item (res, rest), gas, ctxt)
            end
        (* boolean operations *)
        | Or, Item (x, Item (y, rest)) ->
            gas_check_binop descr ((||), x, y) Interp_costs.bool_binop rest ctxt
        | And, Item (x, Item (y, rest)) ->
            gas_check_binop descr ((&&), x, y) Interp_costs.bool_binop rest ctxt
        | Xor, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Compare.Bool.(<>), x, y) Interp_costs.bool_binop rest ctxt
        | Not, Item (x, rest) ->
            gas_check_unop descr (not, x) Interp_costs.bool_unop rest ctxt
        (* integer operations *)
        | Abs_int, Item (x, rest) ->
            gas_check_unop descr (Script_int.abs, x) Interp_costs.abs rest ctxt
        | Int_nat, Item (x, rest) ->
            gas_check_unop descr (Script_int.int, x) Interp_costs.int rest ctxt
        | Neg_int, Item (x, rest) ->
            gas_check_unop descr (Script_int.neg, x) Interp_costs.neg rest ctxt
        | Neg_nat, Item (x, rest) ->
            gas_check_unop descr (Script_int.neg, x) Interp_costs.neg rest ctxt
        | Add_intint, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.add, x, y) Interp_costs.add rest ctxt
        | Add_intnat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.add, x, y) Interp_costs.add rest ctxt
        | Add_natint, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.add, x, y) Interp_costs.add rest ctxt
        | Add_natnat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.add_n, x, y) Interp_costs.add rest ctxt
        | Sub_int, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.sub, x, y) Interp_costs.sub rest ctxt
        | Mul_intint, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.mul, x, y) Interp_costs.mul rest ctxt
        | Mul_intnat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.mul, x, y) Interp_costs.mul rest ctxt
        | Mul_natint, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.mul, x, y) Interp_costs.mul rest ctxt
        | Mul_natnat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.mul_n, x, y) Interp_costs.mul rest ctxt
        | Ediv_teznat, Item (x, Item (y, rest)) ->
            let gas = Gas.consume gas Interp_costs.int64_to_z in
            Gas.check gas >>=? fun () ->
            let x = Script_int.of_int64 (Tez.to_mutez x) in
            gas_check_binop ~gas descr
              ((fun x y ->
                  match Script_int.ediv x y with
                  | None -> None
                  | Some (q, r) ->
                      match Script_int.to_int64 q,
                            Script_int.to_int64 r with
                      | Some q, Some r ->
                          begin
                            match Tez.of_mutez q, Tez.of_mutez r with
                            | Some q, Some r -> Some (q,r)
                            (* Cannot overflow *)
                            | _ -> assert false
                          end
                      (* Cannot overflow *)
                      | _ -> assert false),
               x, y)
              Interp_costs.div
              rest
              ctxt
        | Ediv_tez, Item (x, Item (y, rest)) ->
            let gas = Gas.consume gas Interp_costs.int64_to_z in
            let gas = Gas.consume gas Interp_costs.int64_to_z in
            let x = Script_int.abs (Script_int.of_int64 (Tez.to_mutez x)) in
            let y = Script_int.abs (Script_int.of_int64 (Tez.to_mutez y)) in
            gas_check_binop ~gas descr
              ((fun x y -> match Script_int.ediv_n x y with
                  | None -> None
                  | Some (q, r) ->
                      match Script_int.to_int64 r with
                      | None -> assert false (* Cannot overflow *)
                      | Some r ->
                          match Tez.of_mutez r with
                          | None -> assert false (* Cannot overflow *)
                          | Some r -> Some (q, r)),
               x, y)
              Interp_costs.div
              rest
              ctxt
        | Ediv_intint, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.ediv, x, y) Interp_costs.div rest ctxt
        | Ediv_intnat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.ediv, x, y) Interp_costs.div rest ctxt
        | Ediv_natint, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.ediv, x, y) Interp_costs.div rest ctxt
        | Ediv_natnat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.ediv_n, x, y) Interp_costs.div rest ctxt
        | Lsl_nat, Item (x, Item (y, rest)) ->
            let gas = Gas.consume gas (Interp_costs.shift_left x y) in
            Gas.check gas >>=? fun () -> begin
              match Script_int.shift_left_n x y with
              | None -> fail (Overflow loc)
              | Some x -> logged_return (Item (x, rest), gas, ctxt)
            end
        | Lsr_nat, Item (x, Item (y, rest)) ->
            let gas = Gas.consume gas (Interp_costs.shift_right x y) in
            Gas.check gas >>=? fun () -> begin
              match Script_int.shift_right_n x y with
              | None -> fail (Overflow loc)
              | Some r -> logged_return (Item (r, rest), gas, ctxt)
            end
        | Or_nat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.logor, x, y) Interp_costs.logor rest ctxt
        | And_nat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.logand, x, y) Interp_costs.logand rest ctxt
        | Xor_nat, Item (x, Item (y, rest)) ->
            gas_check_binop descr (Script_int.logxor, x, y) Interp_costs.logxor rest ctxt
        | Not_int, Item (x, rest) ->
            gas_check_unop descr (Script_int.lognot, x) Interp_costs.lognot rest ctxt
        | Not_nat, Item (x, rest) ->
            gas_check_unop descr (Script_int.lognot, x) Interp_costs.lognot rest ctxt
        (* control *)
        | Seq (hd, tl), stack ->
            step origination gas ctxt hd stack >>=? fun (trans, gas, ctxt, origination) ->
            step origination gas ctxt tl trans
        | If (bt, _), Item (true, rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bt rest
        | If (_, bf), Item (false, rest) ->
            step origination (Gas.consume gas Interp_costs.branch) ctxt bf rest
        | Loop body, Item (true, rest) ->
            step origination (Gas.consume gas Interp_costs.loop_cycle) ctxt body rest >>=? fun (trans, gas, ctxt, origination) ->
            step origination (Gas.consume gas Interp_costs.loop_cycle) ctxt descr trans
        | Loop _, Item (false, rest) ->
            logged_return (rest, gas, ctxt)
        | Loop_left body, Item (L v, rest) ->
            step origination (Gas.consume gas Interp_costs.loop_cycle) ctxt body (Item (v, rest)) >>=? fun (trans, gas, ctxt, origination) ->
            step origination (Gas.consume gas Interp_costs.loop_cycle) ctxt descr trans
        | Loop_left _, Item (R v, rest) ->
            let gas = Gas.consume gas Interp_costs.loop_cycle in
            Gas.check gas >>=? fun () ->
            logged_return (Item (v, rest), gas, ctxt)
        | Dip b, Item (ign, rest) ->
            step origination (Gas.consume gas Interp_costs.stack_op) ctxt b rest >>=? fun (res, gas, ctxt, origination) ->
            logged_return ~origination (Item (ign, res), gas, ctxt)
        | Exec, Item (arg, Item (lam, rest)) ->
            interp ?log origination (Gas.consume gas Interp_costs.exec) orig source amount ctxt lam arg >>=? fun (res, gas, ctxt, origination) ->
            logged_return ~origination (Item (res, rest), gas, ctxt)
        | Lambda lam, rest ->
            logged_return ~origination (Item (lam, rest), Gas.consume gas Interp_costs.push, ctxt)
        | Fail, _ ->
            fail (Reject loc)
        | Nop, stack ->
            logged_return (stack, gas, ctxt)
        (* comparison *)
        | Compare Bool_key, Item (a, Item (b, rest)) ->
            gas_compare descr Compare.Bool.compare Interp_costs.compare_bool a b rest
        | Compare String_key, Item (a, Item (b, rest)) ->
            gas_compare descr Compare.String.compare Interp_costs.compare_string a b rest
        | Compare Tez_key, Item (a, Item (b, rest)) ->
            gas_compare descr Tez.compare Interp_costs.compare_tez a b rest
        | Compare Int_key, Item (a, Item (b, rest)) ->
            gas_compare descr Script_int.compare Interp_costs.compare_int a b rest
        | Compare Nat_key, Item (a, Item (b, rest)) ->
            gas_compare descr Script_int.compare Interp_costs.compare_nat a b rest
        | Compare Key_hash_key, Item (a, Item (b, rest)) ->
            gas_compare descr Signature.Public_key_hash.compare
              Interp_costs.compare_key_hash a b rest
        | Compare Timestamp_key, Item (a, Item (b, rest)) ->
            gas_compare descr Script_timestamp.compare Interp_costs.compare_timestamp a b rest
        (* comparators *)
        | Eq, Item (cmpres, rest) ->
            let cmpres = Script_int.compare cmpres Script_int.zero in
            let cmpres = Compare.Int.(cmpres = 0) in
            logged_return (Item (cmpres, rest), Gas.consume gas Interp_costs.compare_res, ctxt)
        | Neq, Item (cmpres, rest) ->
            let cmpres = Script_int.compare cmpres Script_int.zero in
            let cmpres = Compare.Int.(cmpres <> 0) in
            logged_return (Item (cmpres, rest), Gas.consume gas Interp_costs.compare_res, ctxt)
        | Lt, Item (cmpres, rest) ->
            let cmpres = Script_int.compare cmpres Script_int.zero in
            let cmpres = Compare.Int.(cmpres < 0) in
            logged_return (Item (cmpres, rest), Gas.consume gas Interp_costs.compare_res, ctxt)
        | Le, Item (cmpres, rest) ->
            let cmpres = Script_int.compare cmpres Script_int.zero in
            let cmpres = Compare.Int.(cmpres <= 0) in
            logged_return (Item (cmpres, rest), Gas.consume gas Interp_costs.compare_res, ctxt)
        | Gt, Item (cmpres, rest) ->
            let cmpres = Script_int.compare cmpres Script_int.zero in
            let cmpres = Compare.Int.(cmpres > 0) in
            logged_return (Item (cmpres, rest), Gas.consume gas Interp_costs.compare_res, ctxt)
        | Ge, Item (cmpres, rest) ->
            let cmpres = Script_int.compare cmpres Script_int.zero in
            let cmpres = Compare.Int.(cmpres >= 0) in
            logged_return (Item (cmpres, rest), Gas.consume gas Interp_costs.compare_res, ctxt)
        (* protocol *)
        | Manager, Item ((_, _, contract), rest) ->
            let gas = Gas.consume gas Interp_costs.manager in
            Gas.check gas >>=? fun () ->
            Contract.get_manager ctxt contract >>=? fun manager ->
            logged_return (Item (manager, rest), gas, ctxt)
        | Transfer_tokens storage_type,
          Item (p, Item (amount, Item ((tp, Unit_t, destination), Item (storage, Empty)))) -> begin
            let gas = Gas.consume gas Interp_costs.transfer in
            Gas.check gas >>=? fun () ->
            Contract.spend_from_script ctxt source amount >>=? fun ctxt ->
            Contract.credit ctxt destination amount >>=? fun ctxt ->
            Contract.get_script ctxt destination >>=? fun destination_script ->
            Lwt.return (unparse_data gas storage_type storage) >>=? fun (sto, gas) ->
            let sto = Micheline.strip_locations sto in
            begin match Script_ir_translator.extract_big_map storage_type storage with
              | None ->
                  return (None, gas)
              | Some diff ->
                  Script_ir_translator.to_serializable_big_map gas diff >>=? fun (diff, gas) ->
                  return (Some diff, gas)
            end >>=? fun (diff, gas) ->
            Contract.update_script_storage ctxt source sto diff >>=? fun ctxt ->
            Fees.update_script_storage ctxt ~source:orig source dummy_storage_fee >>=? fun ctxt ->
            begin match destination_script with
              | None ->
                  (* we see non scripted contracts as (unit, unit) contract *)
                  Lwt.return (ty_eq tp Unit_t |>
                              record_trace (Invalid_contract (loc, destination))) >>=? fun Eq ->
                  return (ctxt, gas, origination)
              | Some script ->
                  Lwt.return @@ unparse_data gas tp p >>=? fun (p, gas) ->
                  execute origination source destination ctxt script amount p gas
                  >>=? fun (csto, ret, gas, ctxt, origination, maybe_diff) ->
                  begin match maybe_diff with
                    | None ->
                        return (None, gas)
                    | Some diff ->
                        Script_ir_translator.to_serializable_big_map gas diff >>=? fun (diff, gas) ->
                        return (Some diff, gas)
                  end >>=? fun (maybe_diff, gas) ->
                  Contract.update_script_storage ctxt destination csto maybe_diff >>=? fun ctxt ->
                  trace
                    (Invalid_contract (loc, destination))
                    (parse_data ctxt gas Unit_t ret) >>=? fun ((), gas) ->
                  Fees.update_script_storage ctxt ~source:orig
                    destination dummy_storage_fee >>=? fun ctxt ->
                  return (ctxt, gas, origination)
            end >>=? fun (ctxt, gas, origination) ->
            Contract.get_script ctxt source >>=? (function
                | None -> assert false
                | Some { storage; _ } ->
                    parse_data ctxt gas storage_type (Micheline.root storage) >>=? fun (sto, gas) ->
                    logged_return ~origination (Item ((), Item (sto, Empty)), gas, ctxt))
          end
        | Transfer_tokens storage_type,
          Item (p, Item (amount, Item ((tp, tr, destination), Item (sto, Empty)))) -> begin
            let gas = Gas.consume gas Interp_costs.transfer in
            Gas.check gas >>=? fun () ->
            Contract.spend_from_script ctxt source amount >>=? fun ctxt ->
            Contract.credit ctxt destination amount >>=? fun ctxt ->
            Contract.get_script ctxt destination >>=? function
            | None -> fail (Invalid_contract (loc, destination))
            | Some script ->
                begin match extract_big_map storage_type sto with
                  | None ->
                      return (None, gas)
                  | Some diff ->
                      to_serializable_big_map gas diff >>=? fun (diff, gas) ->
                      return (Some diff, gas)
                end >>=? fun (maybe_diff, gas) ->
                Lwt.return (unparse_data gas storage_type sto) >>=? fun (sto, gas) ->
                let sto = Micheline.strip_locations sto in
                Contract.update_script_storage ctxt source sto maybe_diff >>=? fun ctxt ->
                Fees.update_script_storage ctxt ~source:orig
                  source dummy_storage_fee >>=? fun ctxt ->
                Lwt.return (unparse_data gas tp p) >>=? fun (p, gas) ->
                execute origination source destination ctxt script amount p gas
                >>=? fun (sto, ret, gas, ctxt, origination, maybe_diff) ->
                begin match maybe_diff with
                  | None ->
                      return (None, gas)
                  | Some diff ->
                      Script_ir_translator.to_serializable_big_map gas diff >>=? fun (diff, gas) ->
                      return (Some diff, gas)
                end >>=? fun (diff, gas) ->
                Contract.update_script_storage ctxt destination sto diff >>=? fun ctxt ->
                Fees.update_script_storage ctxt ~source:orig
                  destination dummy_storage_fee >>=? fun ctxt ->
                trace
                  (Invalid_contract (loc, destination))
                  (parse_data ctxt gas tr ret) >>=? fun (v, gas) ->
                Contract.get_script ctxt source >>=? (function
                    | None -> assert false
                    | Some { storage ; _ } ->
                        parse_data ctxt gas storage_type (Micheline.root storage) >>=? fun (sto, gas) ->
                        logged_return ~origination (Item (v, Item (sto, Empty)), gas, ctxt))
          end
        | Create_account,
          Item (manager, Item (delegate, Item (delegatable, Item (credit, rest)))) ->
            let gas = Gas.consume gas Interp_costs.create_account in
            Gas.check gas >>=? fun () ->
            Contract.spend_from_script ctxt source credit >>=? fun ctxt ->
            Lwt.return Tez.(credit -? Constants.origination_burn ctxt) >>=? fun balance ->
            Contract.originate ctxt
              origination
              ~manager ~delegate ~balance
              ?script:None ~spendable:true ~delegatable >>=? fun (ctxt, contract, origination) ->
            Fees.origination_burn ctxt ~source contract >>=? fun ctxt ->
            logged_return ~origination (Item ((Unit_t, Unit_t, contract), rest), gas, ctxt)
        | Default_account, Item (key, rest) ->
            let gas = Gas.consume gas Interp_costs.implicit_account in
            Gas.check gas >>=? fun () ->
            let contract = Contract.implicit_contract key in
            logged_return (Item ((Unit_t, Unit_t, contract), rest), gas, ctxt)
        | Create_contract (storage_type, param_type, return_type),
          Item (manager, Item
                  (delegate, Item
                     (spendable, Item
                        (delegatable, Item
                           (credit, Item
                              (Lam (_, code), Item
                                 (init, rest))))))) ->
            create_contract descr ~manager ~delegate ~spendable ~delegatable ~credit ~code ~init
              ~param_type ~return_type ~storage_type ~rest
        | Create_contract_literal (storage_type, param_type, return_type, Lam (_, code)),
          Item (manager, Item
                  (delegate, Item
                     (spendable, Item
                        (delegatable, Item
                           (credit, Item
                              (init, rest)))))) ->
            create_contract descr ~manager ~delegate ~spendable ~delegatable ~credit ~code ~init
              ~param_type ~return_type ~storage_type ~rest
        | Balance, rest ->
            let gas = Gas.consume gas Interp_costs.balance in
            Gas.check gas >>=? fun () ->
            Contract.get_balance ctxt source >>=? fun balance ->
            logged_return (Item (balance, rest), gas, ctxt)
        | Now, rest ->
            let gas = Gas.consume gas Interp_costs.now in
            Gas.check gas >>=? fun () ->
            let now = Script_timestamp.now ctxt in
            logged_return (Item (now, rest), gas, ctxt)
        | Check_signature, Item (key, Item ((signature, message), rest)) ->
            let gas = Gas.consume gas Interp_costs.check_signature in
            Gas.check gas >>=? fun () ->
            let message = MBytes.of_string message in
            let res = Signature.check key signature message in
            logged_return (Item (res, rest), gas, ctxt)
        | Hash_key, Item (key, rest) ->
            logged_return (Item (Signature.Public_key.hash key, rest), Gas.consume gas Interp_costs.hash_key, ctxt)
        | H ty, Item (v, rest) ->
            Gas.consume_check gas (Interp_costs.hash v) >>=? fun gas ->
            Lwt.return @@ hash_data gas ty v >>=? fun (hash, gas) ->
            logged_return (Item (hash, rest), gas, ctxt)
        | Steps_to_quota, rest ->
            let gas = Gas.consume gas Interp_costs.steps_to_quota in
            logged_return (Item (Interp_costs.get_steps_to_quota gas, rest), gas, ctxt)
        | Source (ta, tb), rest ->
            let gas = Gas.consume gas Interp_costs.source in
            Gas.check gas >>=? fun () ->
            logged_return (Item ((ta, tb, orig), rest), gas, ctxt)
        | Self (ta, tb), rest ->
            let gas = Gas.consume gas Interp_costs.self in
            Gas.check gas >>=? fun () ->
            logged_return (Item ((ta, tb, source), rest), gas, ctxt)
        | Amount, rest ->
            let gas = Gas.consume gas Interp_costs.amount in
            Gas.check gas >>=? fun () ->
            logged_return (Item (amount, rest), gas, ctxt) in
    let stack = (Item (arg, Empty)) in
    begin match log with
      | None -> ()
      | Some log ->
          log := (code.loc, gas, unparse_stack (stack, code.bef)) :: !log
    end ;
    step origination gas ctxt code stack >>=? fun (Item (ret, Empty), gas, ctxt, origination) ->
    return (ret, gas, ctxt, origination)

(* ---- contract handling ---------------------------------------------------*)

and execute ?log origination orig source ctxt script amount arg gas :
  (Script.expr * Script.node * Gas.t * context * Contract.origination_nonce *
   Script_typed_ir.ex_big_map option) tzresult Lwt.t =
  parse_script ctxt gas script
  >>=? fun ((Ex_script { code; arg_type; ret_type; storage; storage_type }), gas) ->
  parse_data ctxt gas arg_type arg >>=? fun (arg, gas) ->
  trace
    (Runtime_contract_error (source, script.code))
    (interp ?log origination gas orig source amount ctxt code (arg, storage))
  >>=? fun ((ret, sto), gas, ctxt, origination) ->
  Lwt.return @@ unparse_data gas storage_type sto >>=? fun (storage, gas) ->
  Lwt.return @@ unparse_data gas ret_type ret >>=? fun (ret, gas) ->
  return (Micheline.strip_locations storage, ret, gas, ctxt, origination,
          Script_ir_translator.extract_big_map storage_type sto)

let trace origination orig source ctxt script amount arg gas =
  let log = ref [] in
  execute ~log origination orig source ctxt script amount (Micheline.root arg) gas
  >>=? fun (sto, res, gas, ctxt, origination, maybe_big_map) ->
  return ((sto, Micheline.strip_locations res, gas, ctxt, origination, maybe_big_map), List.rev !log)

let execute origination orig source ctxt script amount arg gas =
  execute origination orig source ctxt script amount (Micheline.root arg) gas
  >>=? fun (sto, res, gas, ctxt, origination, maybe_big_map) ->
  return (sto, Micheline.strip_locations res, gas, ctxt, origination, maybe_big_map)
