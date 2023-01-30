open Protocol
open Block_header_repr
open Bake_state
open Protocol_client_context

(*Checks if there's already another block found*)
(*This should start in a different thread as the cooking part since it will cancel the baking*)
let rec is_late (cctxt : Protocol_client_context.full) state current_level
    canceler =
  Alpha_block_services.Header.shell_header cctxt () >>=? fun {level; _} ->
  if Lwt_canceler.canceled state.canceler || current_level > level then
    (*TODO: check if actually stops mining*)
    cctxt#message "Someone else found a block first! Stopping this mining....."
    >>= fun () ->
    Lwt_canceler.cancel canceler >>= fun _ -> Lwt.return_ok ()
  else is_late cctxt state current_level canceler

let cook_block ({shell; protocol_data} : Block_header_repr.t) nonce target_bytes
    : int64 option Lwt.t =
  let protocol_data = {protocol_data with nonce} in
  let new_block : Block_header_repr.t = {shell; protocol_data} in
  (*
  TODO: check where the shell_header "predecessor hash" value comes from, if its generated by the protocol or not
   *)
  if Proof_of_work.is_valid_header new_block target_bytes then
    Lwt.return (Some nonce)
  else Lwt.return None

let mine_block_loop block target_bytes (start, finish) canceler =
  let open Block_header_repr in
  let {shell; protocol_data} = block in
  let rec loop b nonce =
    (*Check if the mining was canceled*)
    if nonce >= finish then Lwt.fail (Failure "")
    else if Lwt_canceler.canceled canceler then Lwt.return_none
    else
      cook_block b nonce target_bytes >>= fun res ->
      match res with
      | Some nonce ->
          let protocol_data = {protocol_data with nonce} in
          Lwt.return (Some {shell; protocol_data})
      | None -> loop b (Int64.succ nonce)
  in
  loop block start

(*Puts the cake in the oven*)
let mine_header header target_bytes canceler =
  let partition_load workers =
    let open Int64 in
    let chuck_size = Int64.div max_int workers in
    let rec aux i =
      if i < workers then
        let start = Int64.mul i chuck_size in
        let finish = Int64.sub (Int64.add chuck_size start) 1L in
        (start, finish) :: aux (Int64.succ i)
      else []
    in
    aux 0L
  in

  let workers = 20L in
  let tasks =
    List.mapi
      (fun _ rng -> mine_block_loop header target_bytes rng canceler)
      (partition_load workers)
  in
  Lwt_canceler.on_cancel canceler (fun () ->
      List.iter Lwt.cancel tasks ;
      Lwt.return_unit) ;
  Lwt.pick tasks >>= fun a -> Lwt.return a

let mine_worker (cctxt : Protocol_client_context.full) state account () =
  let rec worker_loop () =
    cctxt#message "Starting Mining worker loop" >>= fun () ->
    Client_proto_commands.get_current_target cctxt >>=? fun current_target ->
    let target_as_bytes =
      match Target_repr.to_bytes current_target with
      | Some a -> a
      | _ -> assert false
    in
    cctxt#message "Got target as bytes %s" (Bytes.to_string target_as_bytes)
    >>= fun () ->
    let mine_canceler = Lwt_canceler.create () in
    Header_creation.get_new_possible_block cctxt state account
    >>=? fun (header, operations) ->
    cctxt#message "Current Header %s" (Block_header_repr.to_string_json header)
    >>= fun () ->
    mine_header header target_as_bytes mine_canceler >>= fun mining_resut ->
    cctxt#message
      "Miner: %s"
      (match mining_resut with
      | None -> "NOT FOUND"
      | Some a ->
          "Nonce: "
          ^ (a.protocol_data.nonce |> Int64.to_string)
          ^ " Hash: "
          ^ (Block_header_repr.hash a |> Block_hash.to_hex |> function
             | `Hex a -> a))
    >>= fun () ->
    match mining_resut with
    | None -> worker_loop ()
    | Some a ->
        let protocol_bytes =
          Data_encoding.Binary.to_bytes_exn
            Block_header_repr.contents_encoding
            a.protocol_data
        in
        let header : Block_header.t =
          {shell = a.shell; protocol_data = protocol_bytes}
        in
        let header_encoded =
          Data_encoding.Binary.to_bytes_exn Block_header.encoding header
        in

        Shell_services.Injection.block cctxt header_encoded operations
        >>=? fun block_hash ->
        cctxt#message
          "Found and Injected new block %s"
          (block_hash |> Block_hash.to_hex |> function `Hex e -> e)
        >>= fun () -> worker_loop ()
  in
  cctxt#message "Starting Mining worker loop" >>= fun () -> worker_loop ()
