(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2019 Nomadic Labs, <contact@nomadic-labs.com>               *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

module Directory = Resto_directory.Make (RPC_encoding)
module Service = Resto.MakeService (RPC_encoding)
open Tezos_shell_services

type error += Injection_not_possible

type error += Cannot_parse_op

let () =
  register_error_kind
    `Temporary
    ~id:"local_services.Injection_not_possible"
    ~title:"Injection_not_possible"
    ~description:"Injection not possible"
    ~pp:(fun ppf () ->
      Format.pp_print_string
        ppf
        "Injection not possible in mockup mode without on-disk mockup context.")
    Data_encoding.unit
    (function Injection_not_possible -> Some () | _ -> None)
    (fun () -> Canceled)

let () =
  register_error_kind
    `Temporary
    ~id:"local_services.Cannot_parse_op"
    ~title:"Cannot_parse_op"
    ~description:"Cannot parse operation"
    ~pp:(fun ppf () -> Format.pp_print_string ppf "Cannot parse operation.")
    Data_encoding.unit
    (function Cannot_parse_op -> Some () | _ -> None)
    (fun () -> Canceled)

(* Since we bypass the node but still use the RPC mechanism for procedure
   calls, we have to register some RPCs ourselves. *)

let rec print_path : type pr p. (pr, p) Resto.Internal.path -> string list =
 fun path ->
  match path with
  | Root ->
      []
  | Static (path, s) ->
      s :: print_path path
  | Dynamic (path, arg) ->
      Printf.sprintf "<%s>" arg.descr.name :: print_path path
  | DynamicTail (path, arg) ->
      Printf.sprintf "<%s>" arg.descr.name :: print_path path

let print_service : type p q i o. (_, _, p, q, i, o, _) Service.t -> string =
 fun serv ->
  let iserv = Service.Internal.to_service serv in
  String.concat "/" (List.rev (print_path iserv.path))

(* We need to construct a dummy p2p to build the associated
   rpc directory. *)
let init_fake_p2p =
  let open Tezos_p2p in
  let peer_meta_config =
    {
      P2p_params.peer_meta_encoding = Tezos_p2p_services.Peer_metadata.encoding;
      peer_meta_initial = Tezos_p2p_services.Peer_metadata.empty;
      score = (fun _ -> 0.0);
    }
  in
  let message_config : unit P2p_params.message_config =
    {
      encoding = [];
      chain_name = Distributed_db_version.Name.of_string "TEZOS_CLIENT_MOCKUP";
      (* The following cannot be empty. *)
      distributed_db_versions = Distributed_db_version.[zero; one];
    }
  in
  fun () ->
    P2p.faked_network
      message_config
      peer_meta_config
      Tezos_p2p_services.Connection_metadata.
        {disable_mempool = true; private_node = true}

(* Create dummy RPC directory for the p2p *)
let p2p () =
  let fake_p2p = init_fake_p2p () in
  Tezos_p2p.P2p_directory.build_rpc_directory fake_p2p

let chain chain_id =
  Directory.prefix
    Tezos_shell_services.Chain_services.path
    (Directory.register
       Directory.empty
       Tezos_shell_services.Chain_services.S.chain_id
       (fun _ () () -> RPC_answer.return chain_id))

let protocols protocol_hash =
  let path =
    let open Tezos_rpc.RPC_path in
    prefix Block_services.chain_path Block_services.path
  in
  let service =
    Tezos_rpc.RPC_service.prefix path Block_services.Empty.S.protocols
  in
  Directory.register Directory.empty service (fun _prefix () () ->
      Lwt.return
        (`Ok
          {
            Block_services.current_protocol = protocol_hash;
            next_protocol = protocol_hash;
          }))

let monitor (rpc_context : Tezos_protocol_environment.rpc_context) =
  let open Tezos_protocol_environment in
  let {block_hash; block_header; _} = rpc_context in
  Tezos_rpc.RPC_directory.gen_register
    Directory.empty
    Monitor_services.S.bootstrapped
    (fun () () () -> RPC_answer.return (block_hash, block_header.timestamp))

let mempool (mockup_env : Registration.mockup_environment) (dirname : string) =
  Format.printf "Registering for mempool %@ %s@." dirname ;
  (* /chains/<chain_id> *)
  let chain_path = Block_services.chain_path in
  (* /chains/<chain_id>/mempool *)
  let mempool_path = Block_services.mempool_path chain_path in
  (* /chains/<chain_id>/mempool *)
  let pending_operations_path =
    RPC_path.(mempool_path / "pending_operations")
  in
  let module M = (val mockup_env : Registration.Mockup_sig) in
  RPC_directory.register
    Directory.empty
    (* M.Block_services.Mempool.pending_operations ? *)
    (Block_services.Empty.S.Mempool.pending_operations pending_operations_path)
    (fun _ () () ->
      (* TODO: wrap an a read file action *)
      return Operation_hash.Map.empty
      >>=? fun unprocessed ->
      return
        {
          Block_services.Empty.Mempool.applied = [];
          refused = Operation_hash.Map.empty;
          branch_refused = Operation_hash.Map.empty;
          branch_delayed = Operation_hash.Map.empty;
          unprocessed;
        })

let block_hash (rpc_context : Tezos_protocol_environment.rpc_context) =
  let path =
    let open Tezos_rpc.RPC_path in
    prefix Block_services.chain_path Block_services.path
  in
  let service =
    Tezos_rpc.RPC_service.prefix path Block_services.Empty.S.hash
  in
  (* Always return the head. *)
  Directory.register Directory.empty service (fun _prefix () () ->
      RPC_answer.return rpc_context.block_hash)

let preapply (mockup_env : Registration.mockup_environment)
    (chain_id : Chain_id.t)
    (rpc_context : Tezos_protocol_environment.rpc_context) =
  let (module Mockup_environment) = mockup_env in
  Directory.prefix
    (Tezos_rpc.RPC_path.prefix
       Tezos_shell_services.Chain_services.path
       Block_services.path)
    (Directory.register
       Directory.empty
       (* /chains/<chain_id>/blocks/<block_id>/helpers/preapply/operations *)
       Mockup_environment.Block_services.S.Helpers.Preapply.operations
       (fun _prefix () op_list ->
         (let predecessor = rpc_context.block_hash in
          let header = rpc_context.block_header in
          let predecessor_context = rpc_context.context in
          Mockup_environment.Protocol.begin_construction
            ~chain_id
            ~predecessor_context
            ~predecessor_timestamp:header.timestamp
            ~predecessor_level:header.level
            ~predecessor_fitness:header.fitness
            ~predecessor
            ~timestamp:
              (Time.System.to_protocol (Tezos_stdlib_unix.Systime_os.now ()))
            ()
          >>=? fun state ->
          fold_left_s
            (fun (state, acc) op ->
              Mockup_environment.Protocol.apply_operation state op
              >>=? fun (state, result) ->
              return (state, (op.protocol_data, result) :: acc))
            (state, [])
            op_list
          >>=? fun (state, acc) ->
          Mockup_environment.Protocol.finalize_block state
          >>=? fun _ -> return (List.rev acc))
         >>= fun outcome ->
         match outcome with
         | Ok result ->
             RPC_answer.return result
         | Error errs ->
             RPC_answer.fail errs))

let inject_block =
  let register0 dir s f = RPC_directory.register dir s (fun () p q -> f p q) in
  register0
    Directory.empty
    (* /injection/block *)
    Tezos_shell_services.Injection_services.S.block
    (* See injection_directory.ml for vanilla implementation *)
    (fun _q (_raw, _operations) ->
      (* FIXME here we should do what inject_operation is doing now *)
      assert false)

let inject_operation (mockup_env : Registration.mockup_environment)
    (dirname : string) (_chain_id : Chain_id.t)
    (_rpc_context : Tezos_protocol_environment.rpc_context) (mem_only : bool)
    (_write_context_callback :
      Tezos_protocol_environment.rpc_context -> unit tzresult Lwt.t) =
  let (module Mockup_environment) = mockup_env in
  let write_op op =
    let op_data_encoding =
      Mockup_environment.Protocol.operation_data_encoding
    in
    let op_encoding =
      Data_encoding.(
        dynamic_size
        @@ obj2
             (req "shell_header" Operation.shell_header_encoding)
             (req "protocol_data" op_data_encoding))
    in
    let ops_encoding = Data_encoding.Variable.list op_encoding in
    (* Read current mempool *)
    let mempool_file = (Files.mempool ~dirname :> string) in
    Tezos_stdlib_unix.Lwt_utils_unix.Json.read_file mempool_file
    >>=? fun pooled_operations_json ->
    let pooled_operations =
      Data_encoding.Json.destruct ops_encoding pooled_operations_json
    in
    op :: pooled_operations
    |> Data_encoding.Json.construct ops_encoding
    |> Tezos_stdlib_unix.Lwt_utils_unix.Json.write_file mempool_file
  in
  Directory.register
    Directory.empty
    (* /injection/operation, vanilla client implementation is in
      injection_directory.ml *)
    Tezos_shell_services.Injection_services.S.operation
    (fun _q _contents operation_bytes ->
      (* FIXME instead of doing that, we should fill the mempool file *)
      if mem_only then RPC_answer.fail [Injection_not_possible]
      else
        match
          Data_encoding.Binary.of_bytes Operation.encoding operation_bytes
        with
        | Error _ ->
            RPC_answer.fail [Cannot_parse_op]
        | Ok ({Operation.shell = shell_header; proto} as op) -> (
            let operation_hash = Operation.hash op in
            let proto_op_opt =
              Data_encoding.Binary.of_bytes
                Mockup_environment.Protocol.operation_data_encoding
                proto
            in
            match proto_op_opt with
            | Error _ ->
                RPC_answer.fail [Cannot_parse_op]
            | Ok operation_data -> (
                let op = (shell_header, operation_data) in
                write_op op
                >>= function
                | Ok _ ->
                    RPC_answer.return operation_hash
                | Error errs ->
                    RPC_answer.fail errs ) ))

(* let predecessor = rpc_context.block_hash in
 * let header = rpc_context.block_header in
 * let predecessor_context = rpc_context.context in
 * Mockup_environment.Protocol.begin_construction
 *   ~chain_id
 *   ~predecessor_context
 *   ~predecessor_timestamp:header.timestamp
 *   ~predecessor_level:header.level
 *   ~predecessor_fitness:header.fitness
 *   ~predecessor
 *   ~timestamp:
 *     (Time.System.to_protocol
 *        (Tezos_stdlib_unix.Systime_os.now ()))
 *   ()
 * >>=? (fun state ->
 *        Mockup_environment.Protocol.apply_operation state op
 *        >>=? fun (state, receipt) ->
 *        Mockup_environment.Protocol.finalize_block state
 *        >>=? fun (validation_result, _block_header_metadata) ->
 *        return (validation_result, receipt))
 * >>= fun result ->
 * match result with
 * | Ok ({context; _}, _receipt) ->
 *     let rpc_context = {rpc_context with context} in
 *     Lwt.bind
 *       (write_context_callback rpc_context)
 *       (fun result ->
 *         match result with
 *         | Ok () ->
 *             RPC_answer.return operation_hash
 *         | Error errs ->
 *             RPC_answer.fail errs)
 * | Error errs ->
 *     RPC_answer.fail errs ) )) *)

let build_shell_directory (base_dir : string)
    (mockup_env : Registration.mockup_environment) chain_id
    (rpc_context : Tezos_protocol_environment.rpc_context) (mem_only : bool)
    (write_context_callback :
      Tezos_protocol_environment.rpc_context -> unit tzresult Lwt.t) =
  let (module Mockup_environment) = mockup_env in
  let directory = ref Directory.empty in
  let merge dir = directory := Directory.merge dir !directory in
  merge (p2p ()) ;
  merge (chain chain_id) ;
  merge (monitor rpc_context) ;
  merge (protocols Mockup_environment.Protocol.hash) ;
  merge (block_hash rpc_context) ;
  merge (preapply mockup_env chain_id rpc_context) ;
  merge (mempool mockup_env base_dir) ;
  merge
    (inject_operation
       mockup_env
       base_dir
       chain_id
       rpc_context
       mem_only
       write_context_callback) ;
  merge inject_block ;
  !directory
